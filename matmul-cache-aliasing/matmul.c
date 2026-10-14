#include <stdio.h>
#include <stdlib.h>
#include <time.h>

double wall_clock() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s N LD\n", argv[0]);
        return 1;
    }

    int n = atoi(argv[1]);
    int ld = atoi(argv[2]);

    double *a = malloc((size_t)n * ld * sizeof(double));
    double *b = malloc((size_t)n * ld * sizeof(double));
    double *c = calloc((size_t)n * ld, sizeof(double));
    if (!a || !b || !c) {
        fprintf(stderr, "malloc failed, n=%d ld=%d too big?\n", n, ld);
        return 1;
    }

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            a[i * ld + j] = i + j * 0.5;
            b[i * ld + j] = i * 0.5 - j;
        }

    // the naive triple loop everybody writes at some point. inner loop
    // walks a[i][k] along a row (fine) but b[k][j] down a column with
    // stride ld - same aliasing problem as the reduction example, just
    // buried inside a real operation instead of isolated.
    double t0 = wall_clock();
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            double sum = 0;
            for (int k = 0; k < n; k++)
                sum += a[i * ld + k] * b[k * ld + j];
            c[i * ld + j] = sum;
        }
    }
    double t1 = wall_clock();

    double checksum = 0;
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            checksum += c[i * ld + j];

    printf("n=%d ld=%d time=%.4fs checksum=%.1f\n", n, ld, t1 - t0, checksum);

    free(a);
    free(b);
    free(c);
    return 0;
}
