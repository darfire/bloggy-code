#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// same source, three builds. the hint never changes what the CPU predicts
// (x86 ignores it at runtime) - it only changes which path gcc lays out as
// the straight-line fall-through and which one it moves out of the way.
#if defined(HINT_RIGHT)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#elif defined(HINT_WRONG)
#define UNLIKELY(x) __builtin_expect(!!(x), 1)
#else
#define UNLIKELY(x) (x)
#endif

#define PASSES 500

double wall_clock() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// chunky enough cold path that its placement matters
#define COLD(k) do { acc ^= (acc * 31 + (k)) * 17; acc += (k) * 7; acc ^= acc >> 3; acc *= 13; } while (0)

// --- checks: validation where gcc's default guess is already right --------

typedef struct { int a, b, c, d, e, f, g, h; } rec;

long errors;

// every check compares different fields, on purpose. with `x == 1`,
// `x == 2`, ... gcc merges them into one range check when unhinted, and
// the hint blocks that - you end up measuring a different optimization.
#define CHECK(cond, k) if (UNLIKELY(cond)) { errors++; COLD(k); continue; }

unsigned long run_checks(int n) {
    rec *rs = malloc(n * sizeof *rs);
    for (int i = 0; i < n; i++) {
        // all valid: a<=b, c<=d, e<=f, g<=h, everything in [0, 1000)
        int base = i % 500;
        rs[i] = (rec){ base, base + 1, base, base + 2, base, base + 3, base, base + 4 };
    }

    unsigned long acc = 0;
    double t0 = wall_clock();
    for (int r = 0; r < PASSES; r++)
        for (int i = 0; i < n; i++) {
            rec x = rs[i];
            CHECK(x.a > x.b, 1) CHECK(x.c > x.d, 2) CHECK(x.e > x.f, 3) CHECK(x.g > x.h, 4)
            CHECK(x.a < 0, 5) CHECK(x.b >= 1000, 6) CHECK(x.e < 0, 7) CHECK(x.h >= 1000, 8)
            acc += x.a * 3 + x.h;
        }
    double t1 = wall_clock();

    printf("time=%.4fs ", t1 - t0);
    free(rs);
    return acc + errors;
}

// --- optional: NULL checks where gcc's default guess is wrong --------------

// a record with 8 optional extensions that are almost never set. gcc assumes
// pointers are usually non-NULL, so unhinted it lays out the "present" path
// as the fall-through - exactly backwards for this data.
typedef struct { int v; int *ext[8]; } orec;

#define EXT(k) if (UNLIKELY(x->ext[k] != NULL)) { int e = *x->ext[k]; COLD(e); }

unsigned long run_optional(int n) {
    orec *rs = calloc(n, sizeof *rs);
    for (int i = 0; i < n; i++)
        rs[i].v = i;

    unsigned long acc = 0;
    double t0 = wall_clock();
    for (int r = 0; r < PASSES; r++)
        for (int i = 0; i < n; i++) {
            orec *x = &rs[i];
            EXT(0) EXT(1) EXT(2) EXT(3) EXT(4) EXT(5) EXT(6) EXT(7)
            acc += x->v * 3;
        }
    double t1 = wall_clock();

    printf("time=%.4fs ", t1 - t0);
    free(rs);
    return acc;
}

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[2], "checks") && strcmp(argv[2], "optional"))) {
        fprintf(stderr, "usage: %s nitems checks|optional\n", argv[0]);
        return 1;
    }

    int n = atoi(argv[1]);
    unsigned long sum = !strcmp(argv[2], "checks") ? run_checks(n) : run_optional(n);
    printf("nitems=%d scenario=%s sum=%lu\n", n, argv[2], sum);
    return 0;
}
