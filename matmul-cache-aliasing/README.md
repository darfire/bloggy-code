# matmul cache aliasing

Same root cause as [`../matrix-cache-aliasing`](../matrix-cache-aliasing), but
inside something you'd actually write: a naive triple-loop matrix multiply.
See also [`../icache-pipeline`](../icache-pipeline) for the instruction-cache
version of this.

```c
for (i) for (j) for (k)
    c[i][j] += a[i][k] * b[k][j];
```

`a[i][k]` walks along a row, fine. `b[k][j]` walks down a column with stride
equal to the row length. If that length is a power of two, same story as
before: every access lands in the same cache set, the prefetcher gives up,
and it's way slower than it has to be. The difference from the reduction
example is that this is the exact loop a lot of people write the first time
they implement matmul by hand - nobody sets out to write a pathological
microbenchmark, they just pick a convenient size like 256, 512, 1024, 2048,
which happens to be exactly the size that triggers this.

Padding the row by one element again fixes it, same as before.

## running it

```sh
make
./bench.sh
```

## results

```
| N    | layout         | LD    | time     | miss % | speedup |
|------|----------------|-------|----------|--------|---------|
|  256 | pow2 LD        |   256 |   0.0297s |   1.24% |  1.00x |
|  256 | padded LD      |   257 |   0.0098s |   4.15% |  3.03x |
|  512 | pow2 LD        |   512 |   0.7449s |  40.21% |  1.00x |
|  512 | padded LD      |   513 |   0.0928s |   3.40% |  8.03x |
| 1024 | pow2 LD        |  1024 |   6.2506s |  32.48% |  1.00x |
| 1024 | padded LD      |  1025 |   0.7450s |   0.21% |  8.39x |
```

speedup is relative to the pow2 case for that N. at N=1024 padding is ~8.4x
faster. the gap is bigger here than in the
reduction example because the bad access happens inside the innermost loop
of an O(N^3) operation instead of O(N^2), so the cost compounds.
