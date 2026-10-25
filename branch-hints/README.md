# branch hints

Follow-up to [`../branch-prediction`](../branch-prediction). That one was
about the predictor guessing wrong. This one is about `__builtin_expect`
(and C++20 `[[likely]]`/`[[unlikely]]`), and the twist is that hints have
nothing to do with the predictor.

On x86 the hint doesn't reach the CPU in any way that matters - the
dynamic predictor learns from history either way. What the hint changes is
**code layout**: gcc puts the likely path as the straight-line
fall-through and moves the unlikely one out of the way. A bad layout makes
the hot path a chain of *taken* jumps, and taken branches cost front-end
throughput even when every single one is predicted correctly.

So the counter to watch is taken branches, not misses.

## the setup

One source, three builds:

- **none**: plain `if`, gcc uses its own heuristics
- **right**: `__builtin_expect(cond, 0)` - matches the data
- **wrong**: `__builtin_expect(cond, 1)` - backwards

Two scenarios, each with 8 rarely-true checks per item and a chunky cold
path behind each:

- **checks**: validation (`if (x.a > x.b) { error; continue; }`), never
  fails. gcc already guesses this one right on its own.
- **optional**: 8 optional extension pointers, almost always NULL
  (`if (x->ext[k] != NULL) { ... }`). gcc assumes pointers are usually
  non-NULL, so its default guess is backwards for this data.

## gotcha: don't use `x == 1`, `x == 2`, ...

First version checked one value against 8 constants. Unhinted, gcc merged
them into a single range check; hinted, it didn't. So "no hint" came out
fastest - for a reason that had nothing to do with layout. The checks now
compare different fields so nothing can be merged.

## running it

```sh
make all
./bench.sh
```

Needs `perf` for the counters (timing works without it). The taken-branch
event has no generic name: AMD calls it `ex_ret_brn_tkn`, Intel
`br_inst_retired.near_taken`. `bench.sh` probes for either and shows
`n/a` if neither exists. Counters cover the whole process, time is just the
loop. `N=... ./bench.sh` to change the item count.

single run, to check all builds give the same checksum:

```sh
./hints_none 1000 optional
./hints_right 1000 optional
./hints_wrong 1000 optional
```

## results

```
| scenario | build | time     | taken branches | branch misses | speedup |
|----------|-------|----------|----------------|---------------|---------|
| checks   | none  |  0.0683s |       50560199 |         77626 |   1.00x |
| checks   | right |  0.0681s |       50562177 |         77586 |   1.00x |
| checks   | wrong |  0.1510s |      500570617 |         80526 |   0.45x |
| optional | none  |  0.1398s |      451027024 |        150760 |   1.00x |
| optional | right |  0.0843s |       51019121 |        147933 |   1.66x |
| optional | wrong |  0.1405s |      451028248 |        150815 |   1.00x |
```

(AMD Zen 4, KVM guest, gcc -O2, 100k items x 500 passes = 50M items.)

Branch misses are flat across every row - nothing here is a prediction
problem. Taken branches tell the whole story: 50M is one per item (the
loop back-edge), 450-500M is nine or ten per item (every check jumps over
its cold path).

- **checks**: right hint = no hint, gcc already had it. Wrong hint is
  2.2x slower with zero extra misses.
- **optional**: no hint = wrong hint, because gcc's NULL heuristic is
  wrong for this data. The right hint is 1.66x faster.

Takeaway: hints are worth it where your data contradicts what the compiler
assumes, and they're a liability once they go stale.

Run-to-run noise: on the VM these were measured on, the first second or
so of a run is slower, so `bench.sh` does a throwaway run first and takes
the best of 5. Even so, the first row occasionally comes out ~20% slow.
