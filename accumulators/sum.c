#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>

// 24KB of floats - fits in L1d, so we're measuring the adds, not memory.
// multiple of 24 so every variant's unrolled loop divides it evenly.
#define N 6144
#define PASSES 50000

// one running sum. every add needs the previous one's result, so the loop
// goes at the speed of fp add *latency*, no matter how many adders the
// core has.
__attribute__((noinline)) float sum1(const float *a, int n) {
    float s = 0;
    for (int i = 0; i < n; i++)
        s += a[i];
    return s;
}

// k independent sums, combined at the end. k chains in flight at once, so
// the adds can overlap. note this changes the result: float addition isn't
// associative, which is exactly why the compiler won't do this for you.
__attribute__((noinline)) float sum2(const float *a, int n) {
    float s0 = 0, s1 = 0;
    for (int i = 0; i < n; i += 2) {
        s0 += a[i]; s1 += a[i+1];
    }
    return s0 + s1;
}

__attribute__((noinline)) float sum4(const float *a, int n) {
    float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    for (int i = 0; i < n; i += 4) {
        s0 += a[i]; s1 += a[i+1]; s2 += a[i+2]; s3 += a[i+3];
    }
    return (s0 + s1) + (s2 + s3);
}

// latency x throughput: on Zen 4 an fp add is 3 cycles and there are 2 add
// units, so 6 chains is the point where the adders never sit idle
__attribute__((noinline)) float sum6(const float *a, int n) {
    float s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0;
    for (int i = 0; i < n; i += 6) {
        s0 += a[i]; s1 += a[i+1]; s2 += a[i+2];
        s3 += a[i+3]; s4 += a[i+4]; s5 += a[i+5];
    }
    return (s0 + s1) + (s2 + s3) + (s4 + s5);
}

__attribute__((noinline)) float sum8(const float *a, int n) {
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

// cycles around just the summing loop. returns -1 if perf events aren't
// available (no permission, VM without PMU passthrough, ...).
int open_cycles() {
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(pe));
    pe.type = PERF_TYPE_HARDWARE;
    pe.size = sizeof(pe);
    pe.config = PERF_COUNT_HW_CPU_CYCLES;
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    return syscall(SYS_perf_event_open, &pe, 0, -1, -1, 0);
}

int main(int argc, char **argv) {
    float (*fn)(const float *, int) = NULL;
    if (argc == 2) {
        int k = atoi(argv[1]);
        fn = k == 1 ? sum1 : k == 2 ? sum2 : k == 4 ? sum4 : k == 6 ? sum6 : k == 8 ? sum8 : NULL;
    }
    if (!fn) {
        fprintf(stderr, "usage: %s 1|2|4|6|8\n", argv[0]);
        return 1;
    }

    float *a = malloc(N * sizeof(float));
    srand(42);
    for (int i = 0; i < N; i++)
        a[i] = rand() / (float)RAND_MAX;

    int fd = open_cycles();
    if (fd >= 0) {
        ioctl(fd, PERF_EVENT_IOC_RESET, 0);
        ioctl(fd, PERF_EVENT_IOC_ENABLE, 0);
    }

    float s = 0;
    double t0 = wall_clock();
    for (int r = 0; r < PASSES; r++) {
        // tell the compiler the array might have changed, so it can't
        // compute the sum once and reuse it for every pass
        __asm__ volatile("" : : "r"(a) : "memory");
        s = fn(a, N);
    }
    double t1 = wall_clock();

    long long cycles = -1;
    if (fd >= 0) {
        ioctl(fd, PERF_EVENT_IOC_DISABLE, 0);
        if (read(fd, &cycles, sizeof(cycles)) != sizeof(cycles))
            cycles = -1;
    }

    // reference in double, to see which float order lands closer to it
    double exact = 0;
    for (int i = 0; i < N; i++)
        exact += a[i];

    double elems = (double)N * PASSES;
    printf("accumulators=%s time=%.4fs ns_per_elem=%.3f cycles_per_elem=%.3f sum=%.9g exact=%.9g\n",
           argv[1], t1 - t0, (t1 - t0) * 1e9 / elems,
           cycles >= 0 ? cycles / elems : -1.0, s, exact);
    free(a);
    return 0;
}
