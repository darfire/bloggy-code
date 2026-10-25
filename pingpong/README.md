# pingpong

Follow-up to [`../hyperthreading`](../hyperthreading). That one was about
two threads on one core competing for execution units. This one is about
them *sharing data* - and there, being on the same core is a big win.

Two threads pass one counter back and forth: ping writes an odd value,
waits for pong to write the next even one, and so on. Every write has to
reach the other thread before it can answer, so the round-trip time is
just "how long does it take to move one cache line from one thread to the
other."

Where that line has to travel depends on where the two threads run:

- **same core** (hyperthread siblings): they share one L1. The line never
  leaves it.
- **same L3**: different cores, each with its own L1/L2. The line gets
  handed between the two cores' private caches through the shared L3.
- **different L3**: different core complexes (multi-chiplet Ryzen /
  EPYC). The hand-off goes across the chip's interconnect.

This is why low-latency systems pin a producer and consumer onto the two
hyperthreads of one core, and why it matters which cores the scheduler
happens to put two chatty threads on.

## spin vs pause vs chained

The waiting thread spins on the counter. Three ways to do that:

- **spin**: plain load in a tight loop
- **pause**: same, with `_mm_pause()` in the loop
- **chained**: each load's address depends on the previous load's value
  (through an `and $0` the compiler can't see through), so only one load
  is in flight at a time. Nothing to throw away when the value changes,
  and no pause delay either - it re-checks as soon as the last check
  finished.

`pause` tells the CPU "I'm spinning". On a hyperthread pair the waiting
thread then gives up its issue slots to the sibling - which here is the
thread it's waiting *for*. It also makes leaving the loop cheaper when the
value finally changes: on Intel, a spinning load that sees a sibling's
write can throw away its speculative work to keep memory ordering correct
(a "machine clear"), and `pause` keeps the spinner from running far ahead
in the first place. How long `pause` itself takes varies a lot between
CPUs (~140 cycles on Intel since Skylake, much shorter on Zen), so its
effect does too. It also means pause only *looks* once per pause, so its
column partly measures pause itself - chained is there to tell the two
apart.

## running it

```sh
make
./bench.sh
```

`bench.sh` measures cpu0 against every other online CPU and labels each
one by what it shares with cpu0 (from
`/sys/devices/system/cpu/cpu*/topology/thread_siblings_list` and
`.../cache/index3/shared_cpu_list`). Best of 3 per cell.

The "same core" rows need SMT on and visible to the OS - bare metal, in
practice. In a VM you'll only see "same L3" (and maybe "different L3"),
and the numbers depend on which host cores the vcpus land on.

every physical core against every other (one cpu per core), to see whether
a slow result belongs to a core or to a pair:

```sh
./bench.sh matrix            # spin
./bench.sh matrix chained
```

single run:

```sh
./pingpong 0 1 spin
./pingpong 0 1 pause
./pingpong 0 1 chained
```

The counter sits alone on its own 64-byte line so nothing else shares it.
Both threads on the *same logical* CPU is refused: they'd just take turns
via the scheduler, which measures context switches, not caches.

## results

Frequency pinned to max first (`sudo ../cpufreq.sh max`) - without that
the numbers are dominated by which cores the governor happens to clock
down (see the unpinned run further down).

```
one-way hand-off latency from cpu0, ns (lower is better):

| cpu | shares with cpu0 | spin   | pause  | chained |
|-----|------------------|--------|--------|---------|
|   8 | same core        |   24.5 |   13.7 |    23.9 |
|   1 | same L3          |   20.7 |   20.3 |    28.1 |
|   2 | same L3          |   19.3 |   20.5 |    25.1 |
|   3 | same L3          |   21.1 |   20.6 |    26.9 |
|   4 | same L3          |   19.4 |   20.5 |    26.6 |
|   5 | same L3          |   20.3 |   20.3 |    26.4 |
|   6 | same L3          |   19.4 |   20.4 |    25.0 |
|   7 | same L3          |   20.3 |   20.2 |    31.6 |
|   9 | same L3          |   20.2 |   20.4 |    27.8 |
|  10 | same L3          |   19.4 |   20.3 |    24.8 |
|  11 | same L3          |   21.8 |   20.3 |    24.9 |
|  12 | same L3          |   20.0 |   20.7 |    26.6 |
|  13 | same L3          |   20.3 |   20.4 |    26.1 |
|  14 | same L3          |   19.0 |   20.3 |    25.4 |
|  15 | same L3          |   20.4 |   20.2 |    34.1 |
```

(8 cores / 16 threads, one L3, siblings numbered n and n+8.)

- **same core, pause: 13.7ns** vs ~20ns between cores. Sharing an L1
  does win, ~1.5x - real, but nowhere near the "free" you might expect.
  The write still has to drain from the writer's store buffer into L1
  before the sibling can see it.
- **same core, spin: 24.5ns** - *slower* than going to another core. Spin
  badly on a hyperthread and the advantage is gone.
- **chained doesn't fix it** (23.9ns). Chained keeps only one load in
  flight, so the spinner isn't throwing away a pile of early loads - and
  it's still as slow as spin. So that wasn't the problem. Whatever pause
  does for the sibling, it's something about pause itself (on Zen 4 a
  pausing thread seems to hand the core over to its sibling in a way a
  merely light loop doesn't) - not verified.
- **across cores pause costs nothing** (20.3 vs ~20 spin) - the worry
  that pause's own delay would show up in its column didn't pan out.
- chained is the slowest across cores (25-34ns): checking strictly one
  load at a time means noticing the change a bit later.

### unpinned (default governor) - for comparison

```
| cpu | shares with cpu0 | spin   | pause  |
|-----|------------------|--------|--------|
|   8 | same core        |   44.5 |   21.7 |
|   1 | same L3          |   47.1 |   27.2 |
|   2 | same L3          |   28.5 |   27.8 |
|   3 | same L3          |   45.8 |   27.2 |
|   4 | same L3          |   28.9 |   28.3 |
|   5 | same L3          |   46.7 |   27.3 |
|   6 | same L3          |   29.6 |   27.7 |
|   7 | same L3          |   47.6 |   27.5 |
|   9 | same L3          |   46.1 |   27.4 |
|  10 | same L3          |   28.6 |   27.5 |
|  11 | same L3          |   50.3 |   29.3 |
|  12 | same L3          |   28.9 |   27.6 |
|  13 | same L3          |   46.8 |   27.1 |
|  14 | same L3          |   29.6 |   27.5 |
|  15 | same L3          |   49.1 |   27.5 |
```

Everything 30-50% slower, and plain spin splits by core: 1, 3, 5, 7 at
~47ns, 2, 4, 6 at ~29ns. Pinning the frequency makes the split vanish, so
it was the governor clocking those cores differently - not chip layout.
(Not the preferred-core ranking either: `acpi_cppc/highest_perf` is 202
on every cpu.)

For reference, from a 4-vcpu KVM guest on Zen 4 (no SMT visible, all
vcpus on one L3):

```
| cpu | shares with cpu0 | spin   | pause  |
|-----|------------------|--------|--------|
|   1 | same L3          |   41.0 |   33.5 |
|   2 | same L3          |   27.4 |   25.9 |
|   3 | same L3          |   27.3 |   27.7 |
```
