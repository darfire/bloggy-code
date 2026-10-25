# work queue

Two threads on one core beating two threads on two cores.

The job: 4M items, each needing a bit of work, results into one array.
Split between two threads the usual way - a shared counter hands out the
next item:

```c
for (;;) {
    long i = atomic_fetch_add(&next, 1);
    if (i >= NITEMS) break;
    out[i] = compute(i);
}
```

(dynamic scheduling with chunk size 1 - what `schedule(dynamic)` in
OpenMP, or a naive thread pool, does)

Both threads write the counter on every item, and their `out[i]` writes
land on the same cache lines (8 items per line, handed out alternately).

- **two cores**: each core has its own L1. The counter's line and the
  output lines have to move to whichever core writes next - the ~20ns
  hand-off from [`../pingpong`](../pingpong), on nearly every item.
- **same core** (hyperthread siblings): one shared L1. The lines never
  move. And since `compute` is a latency-bound chain (like the chain in
  [`../accumulators`](../accumulators)), the two threads fill each
  other's idle cycles - close to 2x the single thread.

Second core's extra execution units don't make up for paying a cache-line
hand-off on every item.

## the usual fix

Take 64 items per grab instead of 1 (`chunk` 64). The counter is touched
64x less, and each thread writes whole cache lines of `out` on its own.
Then two cores are fine - they win, since they don't share anything. The
point isn't "use hyperthreads for this", it's that fine-grained sharing
costs a cross-core hand-off, and a hyperthread pair doesn't pay it.

## running it

Needs SMT on and visible to the OS (bare metal). Pin the clock first:

```sh
sudo ../cpufreq.sh max
make
./bench.sh
sudo ../cpufreq.sh restore
```

single runs:

```sh
./queue alone 25 1
./queue same-core 25 1
./queue two-cores 25 1
```

All three give the same `sum` - the result doesn't depend on who did which
item.

## results

Clock pinned to max (`../cpufreq.sh max`), Zen 4, 8 cores / 16 threads:

```
| work | chunk | alone  | same core | two cores | same core vs two cores |
|------|-------|--------|-----------|-----------|------------------------|
|    0 |     1 |   1.89 |      6.79 |     21.73 |                  3.20x |
|   10 |     1 |   4.16 |     10.52 |     23.81 |                  2.26x |
|   25 |     1 |  12.00 |     11.27 |     26.44 |                  2.35x |
|   50 |     1 |  27.18 |     21.49 |     28.42 |                  1.32x |
|  100 |     1 |  68.37 |     42.60 |     44.14 |                  1.04x |
|    0 |    64 |   0.30 |      0.90 |      0.96 |                  1.07x |
|   10 |    64 |   3.74 |      3.41 |      2.12 |                  0.62x |
|   25 |    64 |  10.88 |      8.73 |      5.79 |                  0.66x |
|   50 |    64 |  25.66 |     18.80 |     13.10 |                  0.70x |
|  100 |    64 |  66.56 |     39.97 |     33.09 |                  0.83x |
```

- **chunk 1: same core beats two cores at every size** - 3.2x with no
  work, 2.3x at work 10-25, 1.3x at 50. Only by work=100 does the work
  dwarf the hand-offs and the two even out.
- **work=50 is the row for the post**: alone 27.2, same core 21.5, two
  cores 28.4. Same core is the only way to split this job that beats one
  thread; two cores make it slower.
- **with tiny items, don't split at all**: up to work=10 one thread is
  fastest (1.9 / 4.2ns). Same core is still 2-3x less bad than two cores.
  Why two siblings are slower than one thread there isn't verified -
  likely the atomic: contended `lock xadd` on one line still serializes
  the two threads, even inside one L1.
- **chunk 64 flips it**: barely any sharing left, so two whole cores win
  (~2x alone), same core gets 1.2-1.7x - the hyperthreading story from
  [`../hyperthreading`](../hyperthreading), no sharing involved.

For reference, from a 4-vcpu KVM guest on Zen 4 (no SMT visible, clock
not pinned):

```
| work | chunk | alone  | same core | two cores | same core vs two cores |
|------|-------|--------|-----------|-----------|------------------------|
|    0 |     1 |   1.87 |       n/a |     21.96 |                    n/a |
|   10 |     1 |   4.03 |       n/a |     23.19 |                    n/a |
|   25 |     1 |  12.08 |       n/a |     27.04 |                    n/a |
|   50 |     1 |  26.90 |       n/a |     29.81 |                    n/a |
|  100 |     1 |  68.48 |       n/a |     45.55 |                    n/a |
|    0 |    64 |   0.38 |       n/a |      1.04 |                    n/a |
|   10 |    64 |   3.57 |       n/a |      2.17 |                    n/a |
|   25 |    64 |  10.70 |       n/a |      5.76 |                    n/a |
|   50 |    64 |  25.24 |       n/a |     12.98 |                    n/a |
|  100 |    64 |  66.24 |       n/a |     33.75 |                    n/a |
```

With chunk 1, two cores are *slower than one thread* up to work=50 -
the hand-offs cost more than the second core gains.
