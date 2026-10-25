#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// a job split between two threads the most common way: a shared counter
// hands out the next chunk of items, results go into one shared array.
// the counter and the output's cache lines get written by both threads
// all the time - on two cores they bounce back and forth, on two
// hyperthreads of one core they never leave its L1.
#define NITEMS (1 << 22)

int work;
int chunk;
unsigned long *out;

struct { _Alignas(64) atomic_long v; char pad[56]; } next;

double wall_clock() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

void pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0) {
        fprintf(stderr, "can't pin to cpu %d\n", cpu);
        exit(1);
    }
}

// per-item work: a chain of dependent multiplies, `work` long. latency-
// bound, like ../accumulators' chain - one thread leaves most of the core
// idle, so its hyperthread twin can use the gaps.
static inline unsigned long compute(unsigned long x) {
    for (int i = 0; i < work; i++)
        x = x * 0x9E3779B97F4A7C15ul + (x >> 29);
    return x;
}

void *worker(void *arg) {
    int cpu = *(int *)arg;
    pin(cpu);
    for (;;) {
        long start = atomic_fetch_add_explicit(&next.v, chunk, memory_order_relaxed);
        if (start >= NITEMS)
            break;
        long end = start + chunk < NITEMS ? start + chunk : NITEMS;
        for (long i = start; i < end; i++)
            out[i] = compute(i);
    }
    return NULL;
}

// cpus sharing a physical core with `cpu`, from sysfs ("0,8", "0-1", "3")
int siblings_of(int cpu, int *res, int max) {
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
                res[n++] = c;
        } else {
            res[n++] = atoi(tok);
        }
    }
    return n;
}

int sibling_cpu() {
    int sib[64], n = siblings_of(0, sib, 64);
    for (int i = 0; i < n; i++)
        if (sib[i] != 0)
            return sib[i];
    return -1;
}

int other_core_cpu() {
    int sib[64], n = siblings_of(0, sib, 64);
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    for (int c = 1; c < ncpu; c++) {
        int shared = 0;
        for (int i = 0; i < n; i++)
            if (sib[i] == c)
                shared = 1;
        if (!shared)
            return c;
    }
    return -1;
}

int main(int argc, char **argv) {
    if (argc != 4 || (strcmp(argv[1], "alone") && strcmp(argv[1], "same-core") && strcmp(argv[1], "two-cores"))) {
        fprintf(stderr, "usage: %s alone|same-core|two-cores work chunk\n", argv[0]);
        return 1;
    }
    work = atoi(argv[2]);
    chunk = atoi(argv[3]);

    int cpus[2] = { 0, -1 };
    int nthreads = 1;
    if (!strcmp(argv[1], "same-core")) {
        cpus[1] = sibling_cpu();
        if (cpus[1] < 0) {
            fprintf(stderr, "no hyperthread sibling for cpu0 - SMT off, or not exposed (VMs often don't)\n");
            return 2;
        }
        nthreads = 2;
    } else if (!strcmp(argv[1], "two-cores")) {
        cpus[1] = other_core_cpu();
        if (cpus[1] < 0) {
            fprintf(stderr, "no second physical core\n");
            return 2;
        }
        nthreads = 2;
    }

    out = aligned_alloc(64, NITEMS * sizeof(unsigned long));
    memset(out, 0, NITEMS * sizeof(unsigned long));

    pthread_t th;
    double t0 = wall_clock();
    if (nthreads == 2)
        pthread_create(&th, NULL, worker, &cpus[1]);
    worker(&cpus[0]);
    if (nthreads == 2)
        pthread_join(th, NULL);
    double t1 = wall_clock();

    // same answer no matter who did which item
    unsigned long sum = 0;
    for (long i = 0; i < NITEMS; i++)
        sum += out[i];

    printf("placement=%s work=%d chunk=%d ns_per_item=%.2f sum=%lu\n",
           argv[1], work, chunk, (t1 - t0) * 1e9 / NITEMS, sum);
    free(out);
    return 0;
}
