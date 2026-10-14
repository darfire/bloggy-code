#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "ops.h"

double wall_clock() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

#ifdef STAGED

// one op at a time, across the whole array. only one function's code
// needs to be hot at once.
void run(float *buf, int n) {
#define STAGE(i) for (int k = 0; k < n; k++) buf[k] = op##i(buf[k]);
    OP_LIST(STAGE)
#undef STAGE
}

#else

// every op, one item at a time. walks through all NOPS functions before
// moving to the next item, over and over.
void run(float *buf, int n) {
    for (int i = 0; i < n; i++) {
        float v = buf[i];
#define APPLY(j) v = op##j(v);
        OP_LIST(APPLY)
#undef APPLY
        buf[i] = v;
    }
}

#endif

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s nitems\n", argv[0]);
        return 1;
    }

    int n = atoi(argv[1]);
    float *buf = malloc(n * sizeof(float));
    for (int i = 0; i < n; i++)
        buf[i] = i * 0.001f;

    double t0 = wall_clock();
    run(buf, n);
    double t1 = wall_clock();

    double sum = 0;
    for (int i = 0; i < n; i++)
        sum += buf[i];

    printf("nitems=%d nops=%d time=%.4fs sum=%.4f\n", n, NOPS, t1 - t0, sum);
    free(buf);
    return 0;
}
