#define _GNU_SOURCE
#include <immintrin.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// one node per cache line. 4M of them = 256MB, way past any L3, and the
// list is linked in random order so the hardware prefetcher can't guess
// the next one - every step is a trip to DRAM.
typedef struct node {
    struct node *next;
    unsigned long payload[7];
} node;

#define NNODES (4 << 20)
#define STEPS (1 << 20)     // how far main walks - 64MB worth of nodes
#define AHEAD 32            // how far the helper may run ahead of main
#define NCACHED 512         // "cached" mode: 32KB list, stays in L1/L2

node *head;
int work;

// positions on their own cache lines, so main publishing its progress
// doesn't drag anything else along
struct { _Alignas(64) atomic_long v; char pad[56]; } main_pos;
atomic_int done;

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

// the "real work" per node: a chain of dependent multiplies, `work` long.
// it only needs the node's payload, so it can't start until the node is in.
static inline unsigned long compute(const node *n) {
    unsigned long h = n->payload[0];
    for (int i = 0; i < work; i++)
        h = h * 0x9E3779B97F4A7C15ul + (h >> 29);
    return h;
}

// helper: walk the same list, touch each node, nothing else. it's waiting
// on DRAM nearly all the time, so it barely uses its core. it stays at most
// AHEAD nodes in front of main - any further and the nodes it brought in
// could get evicted before main gets to them.
void *helper(void *arg) {
    pin(*(int *)arg);
    long i = 0;
    for (node *n = head; n && !atomic_load_explicit(&done, memory_order_relaxed); n = n->next, i++) {
        while (i - atomic_load_explicit(&main_pos.v, memory_order_relaxed) > AHEAD &&
               !atomic_load_explicit(&done, memory_order_relaxed))
            _mm_pause();
    }
    return NULL;
}

// busy neighbor for comparison: the "wide" sum from ../accumulators, keeps
// both fp adders busy. shows what main pays when its twin is doing real
// work instead of helping.
void *busy(void *arg) {
    pin(*(int *)arg);
    static float a[2048];
    for (int i = 0; i < 2048; i++)
        a[i] = i * 0.001f;
    float s = 0;
    while (!atomic_load_explicit(&done, memory_order_relaxed)) {
        float s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;
        for (int i = 0; i < 2048; i += 8) {
            s0 += a[i]; s1 += a[i+1]; s2 += a[i+2]; s3 += a[i+3];
            s4 += a[i+4]; s5 += a[i+5]; s6 += a[i+6]; s7 += a[i+7];
        }
        s += ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7));
        __asm__ volatile("" : : "x"(s));
    }
    return NULL;
}

// cpus sharing a physical core with `cpu`, from sysfs ("0,8", "0-1", "3")
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

// cpu0's hyperthread twin, or -1
int sibling_cpu() {
    int sib[64], n = siblings_of(0, sib, 64);
    for (int i = 0; i < n; i++)
        if (sib[i] != 0)
            return sib[i];
    return -1;
}

// a cpu on a different physical core than cpu0, or -1
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

// random permutation -> linked list over the first `count` nodes. xorshift
// instead of rand(): 4M swaps with rand() is slow and RAND_MAX can be small.
// circular for the cached list, so main can walk it as long as it likes.
void build_list(node *nodes, int count, int circular) {
    int *perm = malloc(count * sizeof(int));
    for (int i = 0; i < count; i++)
        perm[i] = i;
    unsigned long x = 88172645463325252ul;
    for (int i = count - 1; i > 0; i--) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        int j = x % (i + 1);
        int t = perm[i]; perm[i] = perm[j]; perm[j] = t;
    }
    for (int i = 0; i < count; i++) {
        node *n = &nodes[perm[i]];
        n->next = i + 1 < count ? &nodes[perm[i + 1]] : circular ? &nodes[perm[0]] : NULL;
        n->payload[0] = i;
        if (i == 0)
            head = n;
    }
    free(perm);
}

int main(int argc, char **argv) {
    // cached is the floor: same walk, same work, but the list fits in
    // cache - what main would cost if every node were already there
    const char *modes[] = { "alone", "helper-sibling", "helper-core", "busy-sibling", "cached" };
    int mode = -1;
    if (argc == 3)
        for (int i = 0; i < 5; i++)
            if (!strcmp(argv[1], modes[i]))
                mode = i;
    if (mode < 0) {
        fprintf(stderr, "usage: %s alone|helper-sibling|helper-core|busy-sibling|cached work\n", argv[0]);
        return 1;
    }
    work = atoi(argv[2]);

    int other = -1;
    if (mode == 1 || mode == 3) {
        other = sibling_cpu();
        if (other < 0) {
            fprintf(stderr, "no hyperthread sibling for cpu0 - SMT off, or not exposed (VMs often don't)\n");
            return 2;
        }
    } else if (mode == 2) {
        other = other_core_cpu();
        if (other < 0) {
            fprintf(stderr, "no second physical core\n");
            return 2;
        }
    }

    node *nodes = aligned_alloc(64, (size_t)NNODES * sizeof(node));
    if (mode == 4)
        build_list(nodes, NCACHED, 1);
    else
        build_list(nodes, NNODES, 0);

    pin(0);
    pthread_t th;
    if (mode == 1 || mode == 2)
        pthread_create(&th, NULL, helper, &other);
    else if (mode == 3)
        pthread_create(&th, NULL, busy, &other);

    unsigned long acc = 0;
    long i = 0;
    double t0 = wall_clock();
    for (node *n = head; i < STEPS; n = n->next, i++) {
        acc += compute(n);
        // every 8 nodes is plenty for the helper to pace itself, and keeps
        // main from hammering a shared cache line every step
        if ((i & 7) == 0)
            atomic_store_explicit(&main_pos.v, i, memory_order_relaxed);
    }
    double t1 = wall_clock();

    atomic_store(&done, 1);
    if (mode >= 1 && mode <= 3)
        pthread_join(th, NULL);

    printf("mode=%s work=%d other_cpu=%d ns_per_node=%.1f acc=%lu\n",
           modes[mode], work, other, (t1 - t0) * 1e9 / STEPS, acc);
    free(nodes);
    return 0;
}
