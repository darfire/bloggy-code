# helper thread

The collaboration example for [`../hyperthreading`](../hyperthreading):
two hyperthreads working on the *same* task, one doing the work and the
other fetching its data.

Main thread walks a linked list and does some work on every node:

```c
for (node *n = head; ...; n = n->next)
    acc += compute(n);
```

The list is 256MB, linked in random order, so every node is a trip to DRAM
(~130ns) and the hardware prefetcher can't help - the next address is
only known once the current node has arrived. Alone, each step costs
*memory wait + work*, one after the other.

The helper walks the same list a few dozen nodes ahead and does nothing
but touch each node. By the time main gets there, the node is already in
cache, and each step costs just *the work*.

## why this is a hyperthread job

The helper is waiting on DRAM nearly all the time - it barely uses the
core. That's the ideal thing to put on a hyperthread: it costs you an
otherwise-idle hardware thread, not a core. And since siblings share L1
and L2, the nodes it brings in are right where main looks.

The same helper on another core works too, but main then has to pull each
node across from the other core's cache (the ~20ns hand-off measured in
[`../pingpong`](../pingpong)), and it's spending a whole core on what's
essentially waiting.

## limits

- the helper can't outrun memory. It walks the same chain of pointers, one
  DRAM trip per node, so each step costs at least that:
  `max(DRAM latency, work + fetching the node from the helper)`. With
  little work, main just catches up with the helper and waits.
- it stays at most 32 nodes ahead of main (main publishes its position
  every 8 nodes). Any further and what it fetched could be evicted before
  main gets there.

## columns

- **cached**: same walk, same work, but a 32KB list that stays in cache.
  The floor - what a perfect helper would get you.
- **alone**: main by itself.
- **helper, same core**: helper on cpu0's hyperthread twin.
- **helper, other core**: helper on a different physical core.
- **busy twin**: no helper; the twin runs the "wide" float sum from
  [`../accumulators`](../accumulators) instead. What main costs when its
  twin is doing something else - i.e. the twin wasn't free capacity to
  begin with, the helper just put it to use.

`work` is the length of a dependent multiply chain per node, ~0.8ns per
step.

## running it

Needs SMT on and visible to the OS for the same-core and busy-twin
columns (bare metal, in practice). Pin the clock first:

```sh
sudo ../cpufreq.sh max
make
./bench.sh
sudo ../cpufreq.sh restore
```

single runs:

```sh
./helper alone 200
./helper helper-sibling 200
./helper helper-core 200
```

## results

Clock pinned to max (`../cpufreq.sh max`), 8 cores / 16 threads, Zen 4:

```
| work | cached | alone  | helper, same core | helper, other core | busy twin |
|------|--------|--------|-------------------|--------------------|-----------|
|    0 |    1.3 |  114.5 |             113.2 |              113.4 |     113.5 |
|   25 |   11.9 |  119.6 |             114.3 |              113.3 |     140.7 |
|   50 |   27.7 |  142.1 |             116.9 |              114.2 |     153.3 |
|  100 |   69.6 |  186.2 |             115.8 |              114.5 |     201.9 |
|  200 |  154.5 |  294.9 |             176.4 |              198.1 |     342.5 |
|  400 |  327.9 |  516.4 |             364.0 |              383.5 |     529.8 |
```

- **the helper works**: at work=100, 186 -> 116ns (1.6x), at 200,
  295 -> 176ns (1.7x). From an otherwise idle hardware thread, no extra
  core.
- **up to ~100 it's pinned at the DRAM floor (~113ns)** in both helper
  columns - main just catches up with the helper, which can't go faster
  than one DRAM trip per node. Same core and other core are identical
  there.
- **past that, same core wins**: above "cached" by 22ns (work=200) and
  36ns (work=400), vs 44 and 56ns from another core. Shared L2 halves the
  cost of getting the node to main. Why same core still isn't *at* the
  floor isn't verified - likely the helper's own loads and pause loop
  taking a slice of the core.
- **busy twin**: when the twin runs the float sum instead, main gets
  *slower* than alone - +21ns at work=25, +16 at 100, +48 at 200. So the
  twin was never free capacity; the helper turns the same slot from a
  cost into a 1.6-1.7x win.

For reference, from a 4-vcpu KVM guest on Zen 4 (no SMT visible, clock
not pinned):

```
| work | cached | alone  | helper, same core | helper, other core | busy twin |
|------|--------|--------|-------------------|--------------------|-----------|
|    0 |    1.0 |  135.1 |               n/a |              132.1 |       n/a |
|   25 |   11.4 |  140.8 |               n/a |              136.5 |       n/a |
|   50 |   26.3 |  159.5 |               n/a |              133.0 |       n/a |
|  100 |   67.5 |  228.6 |               n/a |              135.7 |       n/a |
|  200 |  149.4 |  322.0 |               n/a |              206.8 |       n/a |
|  400 |  314.8 |  521.2 |               n/a |              378.1 |       n/a |
```

Even from another core, the helper takes work=100 from 229 to 136ns -
down to the DRAM floor. At 200 and 400 it settles ~60ns above "cached":
that gap is the cost of pulling each node across from the other core,
which is what the same-core column should close.
