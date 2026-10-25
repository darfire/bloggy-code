#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// 8KB per thread. small on purpose: two of these fit in L1d together, so
// sharing a core doesn't turn into a cache-thrashing test by accident.
#define N 2048
#define SECONDS 1.0

// same two loops as ../accumulators (built with -fno-tree-vectorize, so
// they stay scalar):
//
// chain: one running sum. bound by fp add latency - one add every 3 cycles,
// the core's 2 adders are mostly idle. a second thread can use the gaps.
__attribute__((noinline)) float sum_chain(const float *a, int n) {
    float s = 0;
    for (int i = 0; i < n; i++)
        s += a[i];
    return s;
}

// wide: 8 independent sums. already keeps both adders busy every cycle, so
// a second thread on the same core has nothing left to use.
__attribute__((noinline)) float sum_wide(const float *a, int n) {
    float s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;
    for (int i = 0; i < n; i += 8) {
        s0 += a[i]; s1 += a[i+1]; s2 += a[i+2]; s3 += a[i+3];
        s4 += a[i+4]; s5 += a[i+5]; s6 += a[i+6]; s7 += a[i+7];
    }
    return ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7));
}

double wall_clock() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

typedef struct {
    int cpu;
    float (*fn)(const float *, int);
    long passes;
    double elapsed;
    float sink;
} worker;

atomic_int ready;
atomic_int go;
atomic_int stop;

// each thread runs for a fixed time and counts how much it got done, so
// both are running for the whole measurement - no one finishing early and
// leaving the core to the other.
void *run(void *arg) {
    worker *w = arg;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(w->cpu, &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0) {
        fprintf(stderr, "can't pin to cpu %d\n", w->cpu);
        exit(1);
    }

    float *a = malloc(N * sizeof(float));
    for (int i = 0; i < N; i++)
        a[i] = (i % 1000) * 0.001f;

    atomic_fetch_add(&ready, 1);
    while (!atomic_load(&go))
        ;

    long passes = 0;
    float s = 0;
    double t0 = wall_clock();
    while (!atomic_load_explicit(&stop, memory_order_relaxed)) {
        __asm__ volatile("" : : "r"(a) : "memory");
        s += w->fn(a, N);
        passes++;
    }
    w->elapsed = wall_clock() - t0;
    w->passes = passes;
    w->sink = s;
    free(a);
    return NULL;
}

// cpus sharing a physical core with `cpu`, from sysfs. formats seen in the
// wild: "0,4", "0-1", "3".
int siblings_of(int cpu, int *out, int max) {
    char path[128], buf[128];
    snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list", cpu);
    FILE *f = fopen(path, "r");
    if (!f || !fgets(buf, sizeof(buf), f)) {
        if (f) fclose(f);
        return 0;
    }
    fclose(f);

    int n = 0;
    for (char *tok = strtok(buf, ",\n"); tok && n < max; tok = strtok(NULL, ",\n")) {
        int lo, hi;
        if (sscanf(tok, "%d-%d", &lo, &hi) == 2) {
            for (int c = lo; c <= hi && n < max; c++)
                out[n++] = c;
        } else {
            out[n++] = atoi(tok);
        }
    }
    return n;
}

float (*parse_fn(const char *s))(const float *, int) {
    if (!strcmp(s, "chain")) return sum_chain;
    if (!strcmp(s, "wide")) return sum_wide;
    return NULL;
}

int main(int argc, char **argv) {
    // alone A | siblings A B | cores A B
    if (argc < 3 || (strcmp(argv[1], "alone") && argc != 4)) {
        fprintf(stderr, "usage: %s alone chain|wide\n"
                        "       %s siblings|cores chain|wide chain|wide\n", argv[0], argv[0]);
        return 1;
    }

    int nthreads = strcmp(argv[1], "alone") ? 2 : 1;
    worker w[2] = {0};
    for (int i = 0; i < nthreads; i++) {
        w[i].fn = parse_fn(argv[2 + i]);
        if (!w[i].fn) {
            fprintf(stderr, "unknown workload %s\n", argv[2 + i]);
            return 1;
        }
    }

    // pick cpus: cpu0, plus either its hyperthread sibling or a cpu on a
    // different physical core
    int sib[64];
    int nsib = siblings_of(0, sib, 64);
    w[0].cpu = 0;
    if (!strcmp(argv[1], "siblings")) {
        int found = -1;
        for (int i = 0; i < nsib; i++)
            if (sib[i] != 0) { found = sib[i]; break; }
        if (found < 0) {
            fprintf(stderr, "no hyperthread sibling for cpu0 - SMT off, or not exposed (VMs often don't)\n");
            return 2;
        }
        w[1].cpu = found;
    } else if (!strcmp(argv[1], "cores")) {
        int found = -1;
        long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
        for (int c = 1; c < ncpu && found < 0; c++) {
            int shared = 0;
            for (int i = 0; i < nsib; i++)
                if (sib[i] == c) shared = 1;
            if (!shared) found = c;
        }
        if (found < 0) {
            fprintf(stderr, "no second physical core\n");
            return 2;
        }
        w[1].cpu = found;
    } else if (strcmp(argv[1], "alone")) {
        fprintf(stderr, "unknown placement %s\n", argv[1]);
        return 1;
    }

    pthread_t th[2];
    for (int i = 0; i < nthreads; i++)
        pthread_create(&th[i], NULL, run, &w[i]);
    while (atomic_load(&ready) < nthreads)
        ;

    double t0 = wall_clock();
    atomic_store(&go, 1);
    while (wall_clock() - t0 < SECONDS)
        ;
    atomic_store(&stop, 1);
    for (int i = 0; i < nthreads; i++)
        pthread_join(th[i], NULL);

    // elements per nanosecond, per thread and summed
    double total = 0;
    printf("placement=%s", argv[1]);
    for (int i = 0; i < nthreads; i++) {
        double rate = w[i].passes * (double)N / (w[i].elapsed * 1e9);
        total += rate;
        printf(" t%d=%s@cpu%d:%.3f", i, argv[2 + i], w[i].cpu, rate);
    }
    printf(" total=%.3f\n", total);
    return 0;
}
