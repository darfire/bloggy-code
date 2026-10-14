# matrix cache aliasing

Small demo of a classic gotcha: summing an N x N matrix of doubles column by
column gets way slower when the row length is a power of two, vs the exact
same loop with the row padded by one element.

See also [`../matmul-cache-aliasing`](../matmul-cache-aliasing) for the same
thing showing up inside a real naive matrix multiply, and
[`../icache-pipeline`](../icache-pipeline) for the instruction-cache version
of this kind of gotcha.

## why

Caches are set-associative. Which set an address lands in comes from a slice
of the middle address bits. If your row stride works out to a multiple of
the cache's full set-indexing range (64 sets * 64B lines = 4096B for a typical
8-way 32KB L1), every element you touch going down a column hashes to the
*same* set. The cache only has as many ways as it's associative (8 here), so
it starts evicting almost immediately.

There's a second effect stacked on top: CPUs intentionally don't prefetch on
strides that look like they're going to alias like this, so you lose the
prefetcher too.

Pad the row by one double and the stride stops being a round power of two.
Same data, same loop order, columns spread across sets instead of piling into
one, and it's fast again.

## running it

```sh
make
./bench.sh
```

bench.sh uses `perf stat` if it's installed (`apt install linux-perf` on
Debian/Ubuntu) to show cache-miss rates. If perf isn't there it just times it,
which still shows the effect, just without the miss% column.

single run:

```sh
./aliasing 1024 1024 5 col   # bad: pow2 leading dim
./aliasing 1024 1025 5 col   # fixed: padded leading dim
```

## results

from running it here:

| N    | access pattern         | LD    | time    | miss % | speedup |
|------|------------------------|-------|---------|--------|---------|
|  512 | row-major (baseline)   |   512 |  0.0033s |   2.87% |  8.12x |
|  512 | column, pow2 LD        |   512 |  0.0268s |  49.88% |  1.00x |
|  512 | column, padded LD      |   513 |  0.0037s |  40.00% |  7.24x |
| 1024 | row-major (baseline)   |  1024 |  0.0026s |   4.92% | 10.19x |
| 1024 | column, pow2 LD        |  1024 |  0.0265s |  36.92% |  1.00x |
| 1024 | column, padded LD      |  1025 |  0.0029s |   1.07% |  9.14x |
| 2048 | row-major (baseline)   |  2048 |  0.0027s |   6.11% |  9.56x |
| 2048 | column, pow2 LD        |  2048 |  0.0258s |  26.02% |  1.00x |
| 2048 | column, padded LD      |  2049 |  0.0121s |   7.41% |  2.13x |
| 4096 | row-major (baseline)   |  4096 |  0.0105s |   5.05% | 14.20x |
| 4096 | column, pow2 LD        |  4096 |  0.1491s |  21.11% |  1.00x |
| 4096 | column, padded LD      |  4097 |  0.0824s |  16.19% |  1.81x |

speedup column is relative to the pow2 case for that N - that's the slow one.
padding wins at every size here, 2-9x faster depending on N. went with 512-4096 -
below that the stride isn't big enough to hit the full aliasing case, above
that (tried 8192) the matrix is way bigger than L3 and other effects (DRAM
page conflicts, TLB) start muddying the miss% numbers even though timing still
favors padding.

## same thing in numpy

```sh
python3 numpy_alias.py
```

two things that *don't* show the effect, worth knowing before you go looking
for it: `a.sum(axis=0)` doesn't, because numpy's reduction vectorizes over
contiguous rows regardless of which axis you're nominally reducing, so it
never walks memory column by column in the first place. `a @ b` doesn't
show much either (even with plain reference BLAS, no OpenBLAS/MKL here) -
matmul is specifically built to avoid this.

what does show it: `a.T.copy()`. forcing a transposed view to be contiguous
means numpy has to fill the output row-major, which means reading the input
column-major - genuine column-by-column walk, same as the C version.

```
| N    | layout | time    | speedup |
|------|--------|---------|---------|
| 1024 | pow2   | 0.0147s |   1.00x |
| 1024 | padded | 0.0021s |  7.09x |
| 2048 | pow2   | 0.0397s |   1.00x |
| 2048 | padded | 0.0232s |  1.71x |
| 4096 | pow2   | 0.1956s |   1.00x |
| 4096 | padded | 0.1279s |  1.53x |
```

smaller/noisier margins than the C version (numpy's own overhead eats into
the ratio, plus the BLAS backend you have installed matters - worth
remembering that's yet another thing that varies machine to machine), but
same effect, same direction.
