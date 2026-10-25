# multiple accumulators

Summing a float array. The obvious loop:

```c
float s = 0;
for (int i = 0; i < n; i++)
    s += a[i];
```

runs at about 3 cycles per element on Zen 4, on a core that can do two
float adds every cycle. Every `s += a[i]` needs the previous add's result,
so the loop is one long dependency chain and goes at the speed of add
*latency* (3 cycles), with the second adder sitting idle and the first one
busy only a third of the time.

Fix: k independent sums, combined at the end.

```c
float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
for (int i = 0; i < n; i += 4) {
    s0 += a[i]; s1 += a[i+1]; s2 += a[i+2]; s3 += a[i+3];
}
return (s0 + s1) + (s2 + s3);
```

k chains in flight at once, so the adds overlap. The gain stops at
latency x adders = 3 x 2 = 6 chains - past that, every adder is already
busy every cycle.

## why the compiler won't do this for you

Float addition isn't associative: `(a + b) + c` and `a + (b + c)` can
round differently. Splitting the sum changes the order, so it changes the
answer, and without `-ffast-math` (or `-fassociative-math`) gcc isn't
allowed to do that.

The twist: the single chain isn't the "correct" answer either, it's just
one particular rounding order - and here it's the *least* accurate one
(see the sum columns below). A long running sum keeps adding small values
to a big total, which is where float loses the most precision.

## the builds

- **scalar**: `-O2 -fno-tree-vectorize`. One add per element, nothing
  clever. This is the clean latency story.
- **-O2**: default. gcc can't split the single chain, but it *can*
  vectorize the hand-written ones (they're already separate sums, nothing
  reordered) - 4 accumulators become one SSE register with 4 lanes.
- **-O3 fast-math**: now gcc may reorder. It vectorizes the single chain,
  but into *one* vector accumulator - still one dependency chain, just 4
  lanes wide.
- **+ unroll/var-expand**: `-funroll-loops -fvariable-expansion-in-unroller`.
  That last flag tells gcc to split the accumulator while unrolling, i.e.
  do the multiple-accumulator trick itself.

## running it

```sh
make all
./bench.sh
```

Cycles are read with `perf_event_open` around just the summing loop. If
counters aren't available it falls back to ns per element, which moves
with clock speed and is noisier.

The array is 6144 floats (24KB) so it sits in L1 - this is about the
adds, not memory. Once the data comes from DRAM, memory bandwidth is the
limit and none of this matters much.

## results

```
cycles per element (lower is better):

| accumulators | scalar | -O2   | -O3 fast-math | + unroll/var-expand | sum (float) | exact (double) |
|--------------|--------|-------|---------------|---------------------|-------------|----------------|
|            1 |  2.973 | 2.973 |         0.728 |               0.363 |  3081.42676 |     3081.42909 |
|            2 |  1.488 | 1.488 |         0.729 |               0.364 |  3081.43018 |     3081.42909 |
|            4 |  0.747 | 0.738 |         0.738 |               0.364 |  3081.42896 |     3081.42909 |
|            6 |  0.503 | 0.665 |         0.246 |               0.130 |  3081.42969 |     3081.42909 |
|            8 |  0.504 | 0.366 |         0.364 |               0.188 |   3081.4292 |     3081.42909 |
```

(AMD Zen 4, KVM guest, gcc 14.2.)

- **scalar** is the textbook: 3 -> 1.5 -> 0.75 -> 0.5, and flat from 6 on.
  Exactly latency / k until the adders saturate. 6x from rewriting a
  four-line loop.
- **-O2** row 4 vs scalar row 4: same speed. Vectorizing 4 accumulators
  into one register gives 4 elements per add - but it's back to one
  dependency chain, so 4 elements per 3 cycles. Wider isn't faster unless
  there's more than one chain. Row 8 is two vector chains, so 2x.
- **fast-math** alone gets the plain loop to 0.73 - same trap, one vector
  chain. Adding var-expand splits it and gets 0.36, matching the
  hand-written 8.
- the 6 and 8 rows under fast-math are what the vectorizer made of the
  hand-split code once it's free to reorder - they don't map cleanly to
  "k accumulators" any more. 0.13 is ~8 elements per cycle, i.e. both
  adders doing a full SSE add every cycle, which is the ceiling here
  without AVX.
- sums: 1 accumulator is the furthest from the double-precision result.
  Splitting didn't make it less correct, just differently rounded - here,
  closer.
