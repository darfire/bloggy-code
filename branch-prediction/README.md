# branch prediction

Follow-up to [`../icache-pipeline`](../icache-pipeline). The first version
of that one used function pointers and the slowdown turned out to be mostly
branch misprediction on the indirect call. This one makes that the point.

A batch of items, each with a type, each dispatched through a per-type
function pointer (think ECS systems, interpreters, virtual calls):

```c
items[i].v = ops[items[i].type](items[i].v);
```

Same items, same work, two orders:

- **random**: types shuffled. The predictor can't guess the call target, so
  with 4 types it's wrong ~3 times out of 4.
- **sorted**: items grouped by type first. Target stays the same for long
  runs, the predictor is basically always right.

Real-world version of this: "sort/bucket your entities by type before
processing them."

## why an indirect call and not the classic sorted-array `if`

The usual demo (sum elements > 128, sorted vs unsorted) is fragile: at
`-O2`/`-O3` gcc tends to turn the `if` into a `cmov` or vectorize it, and
the difference disappears. An indirect call can't be made branchless, so
the effect stays put regardless of compiler flags.

## running it

```sh
make
./bench.sh
```

Branch counters are read with `perf_event_open` around just the dispatch
loop, so `qsort` and setup don't pollute the miss counts. If the kernel
won't hand out counters (`perf_event_paranoid`, VM without a PMU) you get
`n/a` and timing only.

single run, to check both give the same checksum:

```sh
./dispatch 100000 random
./dispatch 100000 sorted
```

## results

```
| nitems   | mode   | time      | branch misses | miss rate | speedup |
|----------|--------|-----------|---------------|-----------|---------|
|    10000 | random |   0.0037s |        148769 |     24.8% |   1.00x |
|    10000 | sorted |   0.0007s |           738 |      0.1% |   5.29x |
|   100000 | random |   0.0215s |       1500016 |     25.0% |   1.00x |
|   100000 | sorted |   0.0066s |           835 |      0.0% |   3.26x |
|  1000000 | random |   0.2182s |      14993166 |     25.0% |   1.00x |
|  1000000 | sorted |   0.0670s |          4048 |      0.0% |   3.26x |
```

(AMD Zen 4, KVM guest, gcc -O2, 20 passes over the batch.)

The 25% is exact for a reason: each item costs 3 branches (loop, call,
ret), only the call is unpredictable, and a random target out of 4 is
wrong 3/4 of the time - 0.75 misses per 3 branches. Total branch count
is identical between the two modes; only the misses differ.
