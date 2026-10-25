#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>

#define NTYPES 4
#define PASSES 20

typedef struct { int type; float v; } item;

// noinline + called through a pointer, so the compiler can't turn the
// dispatch into a branchless select. the only thing that changes between
// modes is how predictable the call target is.
__attribute__((noinline)) static float op0(float x) { return x * 1.0001f + 0.5f; }
__attribute__((noinline)) static float op1(float x) { return x * 0.9999f - 0.25f; }
__attribute__((noinline)) static float op2(float x) { return x * 0.5f + 1.0f; }
__attribute__((noinline)) static float op3(float x) { return x * 1.5f - 0.75f; }

static float (*ops[NTYPES])(float) = { op0, op1, op2, op3 };

double wall_clock() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// counts branch misses around just the dispatch loop, so qsort and setup
// don't leak into the numbers. returns -1 if perf events aren't available
// (no permission, VM without PMU passthrough, ...).
int open_counter(unsigned long long config) {
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(pe));
    pe.type = PERF_TYPE_HARDWARE;
    pe.size = sizeof(pe);
    pe.config = config;
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    return syscall(SYS_perf_event_open, &pe, 0, -1, -1, 0);
}

int by_type(const void *a, const void *b) {
    return ((const item *)a)->type - ((const item *)b)->type;
}

void run(item *items, int n) {
    for (int r = 0; r < PASSES; r++)
        for (int i = 0; i < n; i++)
            items[i].v = ops[items[i].type](items[i].v);
}

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[2], "random") && strcmp(argv[2], "sorted"))) {
        fprintf(stderr, "usage: %s nitems random|sorted\n", argv[0]);
        return 1;
    }

    int n = atoi(argv[1]);
    item *items = malloc(n * sizeof(item));
    srand(42);
    for (int i = 0; i < n; i++) {
        items[i].type = rand() % NTYPES;
        items[i].v = i * 0.001f;
    }
    // same items, same work - just grouped by type
    if (!strcmp(argv[2], "sorted"))
        qsort(items, n, sizeof(item), by_type);

    int fd_br = open_counter(PERF_COUNT_HW_BRANCH_INSTRUCTIONS);
    int fd_miss = open_counter(PERF_COUNT_HW_BRANCH_MISSES);
    if (fd_br >= 0 && fd_miss >= 0) {
        ioctl(fd_br, PERF_EVENT_IOC_RESET, 0);
        ioctl(fd_miss, PERF_EVENT_IOC_RESET, 0);
        ioctl(fd_br, PERF_EVENT_IOC_ENABLE, 0);
        ioctl(fd_miss, PERF_EVENT_IOC_ENABLE, 0);
    }

    double t0 = wall_clock();
    run(items, n);
    double t1 = wall_clock();

    long long branches = -1, misses = -1;
    if (fd_br >= 0 && fd_miss >= 0) {
        ioctl(fd_br, PERF_EVENT_IOC_DISABLE, 0);
        ioctl(fd_miss, PERF_EVENT_IOC_DISABLE, 0);
        if (read(fd_br, &branches, sizeof(branches)) != sizeof(branches)) branches = -1;
        if (read(fd_miss, &misses, sizeof(misses)) != sizeof(misses)) misses = -1;
    }

    // order of the float ops differs per item only by position, so the sum
    // is the same in both modes (up to float rounding in the summation)
    double sum = 0;
    for (int i = 0; i < n; i++)
        sum += items[i].v;

    printf("nitems=%d mode=%s time=%.4fs branches=%lld misses=%lld sum=%.6g\n",
           n, argv[2], t1 - t0, branches, misses, sum);
    free(items);
    return 0;
}
