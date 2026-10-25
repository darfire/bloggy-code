#define _GNU_SOURCE
#include <immintrin.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define ROUNDS 1000000
#define WARMUP 10000

// one counter, alone on its own cache line, so nothing else rides along.
// ping writes odd values, pong writes even ones - each waits for the
// other's write before making its own. every write has to travel to the
// other thread's cache and back, so one round trip = two hand-offs of
// this cache line.
struct {
    _Alignas(64) atomic_long v;
    char pad[64 - sizeof(atomic_long)];
} flag;

enum { SPIN, PAUSE, CHAINED } mode;

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

// wait for the other side's value, then hand over ours. three ways to wait:
//
// spin: plain load in a tight loop. the cpu runs far ahead, with lots of
// loads of the flag in flight at once - when the value changes, all of
// those were too early and get thrown away.
//
// pause: same, with `pause` in the loop. the spinner backs off, gives its
// issue slots to a hyperthread sibling, and has little in flight. but it
// only looks once per pause (tens of cycles), which adds its own delay.
//
// chained: each load's address depends on the previous load's result, so
// only one load is ever in flight - nothing to throw away, and it checks
// again as soon as the last check finished (a few cycles), no pause delay.
static inline void wait_then_set(long want, long next) {
    if (mode == PAUSE) {
        while (atomic_load_explicit(&flag.v, memory_order_acquire) != want)
            _mm_pause();
    } else if (mode == CHAINED) {
        long v = atomic_load_explicit(&flag.v, memory_order_acquire);
        while (v != want) {
            // z is always 0, but the compiler and cpu don't know that -
            // the next load has to wait for this one's value
            long z = v;
            __asm__ volatile("and $0, %0" : "+r"(z));
            v = atomic_load_explicit(&flag.v + z, memory_order_acquire);
        }
    } else {
        while (atomic_load_explicit(&flag.v, memory_order_acquire) != want)
            ;
    }
    atomic_store_explicit(&flag.v, next, memory_order_release);
}

typedef struct { int cpu; long rounds; } pong_arg;

void *pong(void *arg) {
    pong_arg *p = arg;
    pin(p->cpu);
    for (long i = 0; i < p->rounds; i++)
        wait_then_set(2 * i + 1, 2 * i + 2);
    return NULL;
}

// ping side, runs on the main thread. returns seconds for `rounds` trips.
double ping(long start, long rounds) {
    double t0 = wall_clock();
    for (long i = start; i < start + rounds; i++)
        wait_then_set(2 * i, 2 * i + 1);
    // wait for the last reply so the final trip is counted in full
    while (atomic_load_explicit(&flag.v, memory_order_acquire) != 2 * (start + rounds))
        ;
    return wall_clock() - t0;
}

int main(int argc, char **argv) {
    if (argc != 4 || (strcmp(argv[3], "spin") && strcmp(argv[3], "pause") && strcmp(argv[3], "chained"))) {
        fprintf(stderr, "usage: %s cpuA cpuB spin|pause|chained\n", argv[0]);
        return 1;
    }
    int a = atoi(argv[1]), b = atoi(argv[2]);
    mode = !strcmp(argv[3], "pause") ? PAUSE : !strcmp(argv[3], "chained") ? CHAINED : SPIN;
    if (a == b) {
        // both threads on one logical cpu would just take turns via the
        // scheduler - that measures context switches, not caches
        fprintf(stderr, "cpuA and cpuB must differ\n");
        return 1;
    }

    pin(a);
    atomic_store(&flag.v, 0);
    pong_arg p = { b, WARMUP + ROUNDS };
    pthread_t th;
    pthread_create(&th, NULL, pong, &p);

    ping(0, WARMUP);
    double t = ping(WARMUP, ROUNDS);
    pthread_join(th, NULL);

    printf("cpus=%d,%d mode=%s roundtrip_ns=%.1f oneway_ns=%.1f\n",
           a, b, argv[3], t * 1e9 / ROUNDS, t * 1e9 / ROUNDS / 2);
    return 0;
}
