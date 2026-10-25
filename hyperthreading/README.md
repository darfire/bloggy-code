# hyperthreading

Two hardware threads on one physical core (SMT / hyperthreading) share
almost everything: the execution units, the caches, the out-of-order
machinery. The only thing each gets to itself is its own register state
and instruction stream. So a second thread only gets work done if the
first one is leaving parts of the core idle.

Builds directly on [`../accumulators`](../accumulators) - same two loops:

- **chain**: one running float sum. Latency-bound: one add every 3 cycles,
  while the core could start 2 per cycle. The adders sit idle ~5/6 of the
  time.
- **wide**: 8 independent sums. Already keeps both adders busy every cycle.

Put two of them on the same core:

- **chain + chain** should *collaborate*: each thread fills the other's
  idle cycles, both run at close to full speed, ~2x total work.
- **wide + wide** should *stumble*: there's nothing idle to fill. They
  split the adders, each runs at about half speed, ~1x total - same work
  as one thread, now with two threads' worth of overhead.

Same instructions, same data size, opposite outcome. Whether SMT helps
depends on how much of the core one thread leaves on the table.

## what's measured

Each thread is pinned to a CPU and runs its loop for 1 second, counting
how much it got through (elements/ns). Fixed time, not fixed work, so both
threads are running for the whole measurement - neither finishes early
and leaves the core to the other.

Placements:

- **alone**: one thread, the baseline
- **siblings**: cpu0 and its hyperthread twin - same physical core. The
  test.
- **cores**: cpu0 and a CPU on a different physical core. The ceiling:
  two threads with nothing shared (except L3 and the power budget).

Siblings are read from
`/sys/devices/system/cpu/cpu0/topology/thread_siblings_list`, so it works
whatever the numbering is (Intel tends to pair 0/1, AMD 0/N/2).

The array is 8KB per thread on purpose, so two of them fit in L1 together.
Make it bigger and the wide+wide row also becomes a cache-thrashing test,
which is a different post.

## running it

Needs SMT on and visible to the OS, which means bare metal in practice -
most VMs present each vcpu as its own core.
`lscpu | grep 'Thread(s) per core'` should say 2.

```sh
make
./bench.sh
```

single runs:

```sh
./smt alone chain
./smt siblings chain chain
./smt siblings wide wide
./smt cores wide wide
```

Noise to watch for: turbo. One busy core can clock higher than two, so
"cores" rows can come out a little under 2x for reasons that have nothing
to do with SMT. On Intel hybrid chips make sure cpu0 is a P-core (E-cores
have no hyperthreads).

## results

```
elements/ns, higher is better. 'vs alone' = total work done compared to one thread on its own.

| threads       | placement | thread 0 | thread 1 | total  | vs alone |
|---------------|-----------|----------|----------|--------|----------|
| chain         | alone     |    1.277 |        - |  1.277 |    1.00x |
| wide          | alone     |    6.901 |        - |  6.901 |    1.00x |
| chain + chain | siblings  |    1.261 |    1.255 |  2.517 |    1.97x |
| wide + wide   | siblings  |    3.663 |    3.673 |  7.336 |    1.06x |
| chain + wide  | siblings  |    1.268 |    3.532 |  4.801 |        - |
| chain + chain | cores     |    1.278 |    1.277 |  2.555 |    2.00x |
| wide + wide   | cores     |    6.921 |    7.399 | 14.320 |    2.08x |
```

- **chain + chain** on one core: 1.97x - basically as good as two separate
  cores (2.00x). Two latency-bound threads fill each other's gaps almost
  perfectly.
- **wide + wide** on one core: 1.06x. Each thread runs at half speed,
  the second thread bought nothing.
- **chain + wide** is the surprise. chain doesn't notice wide at all
  (1.268 vs 1.277 alone), but wide drops to *half* speed (3.53 vs 6.90) -
  as much as when sharing with another wide thread, even though chain only
  uses ~1/6 of the adders. Not explained yet.
