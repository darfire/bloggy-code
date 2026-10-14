#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

double wall_clock() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s N LD reps row|col\n", argv[0]);
        return 1;
    }

    int n = atoi(argv[1]);
    int ld = atoi(argv[2]);
    int reps = atoi(argv[3]);
    char *mode = argv[4];

    double *a = malloc((size_t)n * ld * sizeof(double));
    if (!a) {
        fprintf(stderr, "malloc failed, n=%d ld=%d too big?\n", n, ld);
        return 1;
    }

    // fill with something that isn't all zeroes so -O2 can't just skip the sum
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            a[i * ld + j] = i * 31 + j;

    double sum = 0;
    double t0 = wall_clock();

    if (!strcmp(mode, "row")) {
        for (int r = 0; r < reps; r++)
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++)
                    sum += a[i * ld + j];
    } else {
        // column-major walk - this is the one that aliases when ld is a power of 2
        for (int r = 0; r < reps; r++)
            for (int j = 0; j < n; j++)
                for (int i = 0; i < n; i++)
                    sum += a[i * ld + j];
    }

    double t1 = wall_clock();
    printf("n=%d ld=%d reps=%d mode=%s time=%.4fs sum=%.1f\n", n, ld, reps, mode, t1 - t0, sum);

    free(a);
    return 0;
}
