#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "ops.h"

#define PROG_LEN (1 << 16)
#define NPHRASES 32
#define PHRASE_LEN 16
#define PHRASE_SKEW 1.2
#ifndef OP_SKEW
#define OP_SKEW 0.6
#endif
#ifndef P_FLAG
#define P_FLAG 0.02
#endif

struct insn {
    uint16_t op;
    uint8_t flags; // one bit per stage: run that stage's rare fragment
    int8_t imm;
};

double wall_clock() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint64_t rng_state;

static uint64_t rng() {
    // xorshift64*, deterministic so every binary runs the exact same program
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    return rng_state * 0x2545F4914F6CDD1Dull;
}

static double rng_unit() {
    return (rng() >> 11) * (1.0 / (1ull << 53));
}

// a workload is two things the compiler can't know about:
//   - which ops are used at all: A only uses the first half of the
//     instruction set and B only the second half, the way numeric code
//     and string code would hit different parts of a real interpreter
//   - how often each one is used: a zipf distribution over a shuffled
//     order of those ops, so some are hot, most are warm, a few are rare
// in both, each rare-case flag is only set P_FLAG of the time.
struct workload {
    const char *name;
    uint64_t seed;
    int first_op;
};

static const struct workload workloads[] = {
    {"A", 0x1234, 0},
    {"B", 0xbeef, NOPS / 2},
};

// index of the first cdf entry >= a uniform draw in [0, total)
static int pick(const double *cdf, int n, double total) {
    double u = rng_unit() * total;
    int i = 0;
    while (i < n - 1 && cdf[i] < u)
        i++;
    return i;
}

static double zipf_cdf(double *cdf, int n, double skew) {
    double total = 0;
    for (int i = 0; i < n; i++) {
        total += 1.0 / pow(i + 1, skew);
        cdf[i] = total;
    }
    return total;
}

// real bytecode isn't a random stream of ops: it's the same handful of
// loop bodies and call sequences, run over and over. so the program is
// made of short phrases, each one a fixed run of ops, and the phrases
// get repeated. a random op stream turns every dispatch into a branch
// mispredict, which drowns out everything else.
static void build_program(const struct workload *w, struct insn *prog) {
    enum { N = NOPS / 2 };
    int perm[N];
    double cdf[N], pcdf[NPHRASES];
    struct insn phrases[NPHRASES * PHRASE_LEN];

    rng_state = w->seed;
    for (int i = 0; i < N; i++)
        perm[i] = w->first_op + i;
    for (int i = N - 1; i > 0; i--) {
        int j = rng() % (i + 1);
        int t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }

    double total = zipf_cdf(cdf, N, OP_SKEW);
    for (int i = 0; i < NPHRASES * PHRASE_LEN; i++) {
        uint8_t flags = 0;
        for (int k = 0; k < NSTAGES; k++)
            if (rng_unit() < P_FLAG)
                flags |= 1 << k;
        phrases[i].op = perm[pick(cdf, N, total)];
        phrases[i].flags = flags;
        phrases[i].imm = rng() % 256 - 128;
    }

    // which phrase comes next is random too, but skewed
    double ptotal = zipf_cdf(pcdf, NPHRASES, PHRASE_SKEW);
    for (int pc = 0; pc < PROG_LEN; pc += PHRASE_LEN) {
        int p = pick(pcdf, NPHRASES, ptotal);
        memcpy(&prog[pc], &phrases[p * PHRASE_LEN], PHRASE_LEN * sizeof(struct insn));
    }
}

__attribute__((noinline)) uint64_t run(const struct insn *prog, long iters) {
    uint64_t r[NREGS];
    for (int i = 0; i < NREGS; i++)
        r[i] = i * 0x100000001b3ull + 1;

    for (long it = 0; it < iters; it++) {
        for (int pc = 0; pc < PROG_LEN; pc++) {
            struct insn ins = prog[pc];
            switch (ins.op) {
#include "ops.inc"
            }
        }
    }

    uint64_t sum = 0;
    for (int i = 0; i < NREGS; i++)
        sum ^= r[i];
    return sum;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s workload(A|B) iters\n", argv[0]);
        return 1;
    }

    const struct workload *w = NULL;
    for (size_t i = 0; i < sizeof(workloads) / sizeof(workloads[0]); i++)
        if (strcmp(argv[1], workloads[i].name) == 0)
            w = &workloads[i];
    if (!w) {
        fprintf(stderr, "unknown workload %s\n", argv[1]);
        return 1;
    }
    long iters = atol(argv[2]);

    struct insn *prog = malloc(PROG_LEN * sizeof(struct insn));
    build_program(w, prog);

    double t0 = wall_clock();
    uint64_t sum = run(prog, iters);
    double t1 = wall_clock();

    printf("workload=%s iters=%ld nops=%d time=%.4fs checksum=%016llx\n",
           w->name, iters, NOPS, t1 - t0, (unsigned long long)sum);
    free(prog);
    return 0;
}
