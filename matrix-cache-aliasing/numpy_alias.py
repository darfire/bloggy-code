#!/usr/bin/env python3
# same effect as aliasing.c, but in numpy. a couple of things that don't
# work are worth noting:
#
# - a.sum(axis=0) doesn't show it - numpy's reduction iterates the outer
#   axis and vectorizes over contiguous rows regardless of which axis
#   you're "reducing", so it never actually walks memory column by column
# - a @ b doesn't show much either, since matmul goes through BLAS, which
#   is specifically built to avoid exactly this
#
# what does work: a.T.copy(). transposing a view and forcing it
# contiguous means numpy has to fill the destination in row-major order,
# which means reading the source in column-major order - a genuine
# column-by-column walk, same as the C version.

import sys
import time

import numpy as np


def make(n, ld):
    base = np.arange(n * ld, dtype=np.float64).reshape(n, ld)
    return base[:, :n]


def best_of(fn, reps=5):
    best = float("inf")
    for _ in range(reps):
        t0 = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t0)
    return best


def main():
    sizes = [int(a) for a in sys.argv[1:]] or [1024, 2048, 4096]

    print("| N    | layout | time    | speedup |")
    print("|------|--------|---------|---------|")
    for n in sizes:
        pow2 = make(n, n)
        pow2_time = best_of(lambda: pow2.T.copy())
        print(f"| {n:4d} | pow2   | {pow2_time:.4f}s |   1.00x |")

        padded = make(n, n + 1)
        padded_time = best_of(lambda: padded.T.copy())
        print(f"| {n:4d} | padded | {padded_time:.4f}s | {pow2_time / padded_time:5.2f}x |")


if __name__ == "__main__":
    main()
