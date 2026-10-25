# bolt sqlite

SQLite's own benchmark (`speedtest1`) on SQLite, compiled plain `-O2`, with
PGO, and post-link optimized with BOLT. Each profile-guided build is trained
on one of speedtest1's test sets, then every build runs all of them. Same
source, same queries, same result hash.

Same idea as the toy in [`../pgo-dispatch`](../pgo-dispatch), on a real
program: most of SQLite's time goes into `sqlite3VdbeExec`, its bytecode
interpreter, a single `switch` over ~190 opcodes, surrounded by a B-tree, a
pager and a query planner.

## test sets

Four of speedtest1's test sets, all against an in-memory database
(`--memdb`):

- `main`: the default mix - inserts, indexed and unindexed selects,
  updates, deletes, joins, sorting
- `orm`: wide tables with ORM-style generated queries
- `cte`: recursive common table expressions (a sudoku solver, a Mandelbrot
  set in SQL)
- `fp`: floating-point values, conversions and aggregates

Training uses `main` and `cte` (`TRAIN` in the Makefile), at a quarter of
the benchmark size. `orm` and `fp` are never trained on.

## variants

- `st_base`: `-O2`, no profile
- `st_pgo_main`, `st_pgo_cte`: PGO trained on one test set
- `st_pgo_main+cte`: PGO trained on both, profiles merged
- `st_bolt_main`, `st_bolt_cte`: `st_base` rewritten by BOLT with a
  profile of one test set

## running it

```sh
./bench.sh
# debian/ubuntu, where llvm tools are only on PATH with a -18 suffix:
./bench.sh LLVM_SUFFIX=-18
```

The first run downloads the SQLite 3.54.1 amalgamation and `speedtest1.c`
(needs wget and unzip) and checks them against pinned sha256 hashes.

Tools and BOLT profile modes are the same as in `../pgo-dispatch`, see its
README: clang and llvm-profdata from the same llvm, any llvm-bolt, perf for
the counters. `BOLT_PROFILE` is `lbr` if the cpu has branch records,
`instr` otherwise. Builds are non-PIE for the same reason as there: with
PIE, BOLT can't follow `sqlite3VdbeExec`'s jump table and leaves it alone.

Time is speedtest1's own TOTAL, best of `RUNS` (default 5). The result
hash comes from a separate `--verify` run, and the counters from another,
since both add work. `bench.sh` fails if any build's hash differs from
`st_base`.

## results

AMD Ryzen 7 7840HS (zen 4), clang 18, BOLT 18, bare metal,
`BOLT_PROFILE=lbr`, `RUNS=7`, pinned to one core with `taskset`:

```
| testset | binary       | time    | taken branches | icache misses | speedup |
|---------|--------------|---------|----------------|---------------|---------|
| main    | base         |  1.750s |        2107.7M |         50.2M |   1.00x |
| main    | pgo-main     |  1.549s |         999.6M |         25.8M |   1.13x |
| main    | pgo-cte      |  1.659s |        1540.8M |         32.9M |   1.05x |
| main    | pgo-main+cte |  1.559s |        1087.4M |         29.5M |   1.12x |
| main    | bolt-main    |  1.692s |        1214.5M |         21.4M |   1.03x |
| main    | bolt-cte     |  1.728s |        1710.5M |         35.8M |   1.01x |
| orm     | base         |  0.775s |        1061.3M |         53.1M |   1.00x |
| orm     | pgo-main     |  0.716s |         696.9M |         34.2M |   1.08x |
| orm     | pgo-cte      |  0.752s |         827.0M |         38.6M |   1.03x |
| orm     | pgo-main+cte |  0.702s |         709.0M |         33.9M |   1.10x |
| orm     | bolt-main    |  0.741s |         706.0M |         33.3M |   1.05x |
| orm     | bolt-cte     |  0.765s |         950.5M |         43.0M |   1.01x |
| cte     | base         |  2.741s |        4569.0M |         43.6M |   1.00x |
| cte     | pgo-main     |  2.481s |        3229.6M |         33.9M |   1.10x |
| cte     | pgo-cte      |  2.284s |        2063.7M |         29.4M |   1.20x |
| cte     | pgo-main+cte |  2.290s |        2171.7M |         35.7M |   1.20x |
| cte     | bolt-main    |  2.671s |        3457.8M |         47.1M |   1.03x |
| cte     | bolt-cte     |  2.646s |        2470.6M |         26.4M |   1.04x |
| fp      | base         |  1.673s |        1879.9M |         15.5M |   1.00x |
| fp      | pgo-main     |  1.599s |        1450.8M |         13.3M |   1.05x |
| fp      | pgo-cte      |  1.628s |        1512.6M |          8.2M |   1.03x |
| fp      | pgo-main+cte |  1.584s |        1417.9M |         13.3M |   1.06x |
| fp      | bolt-main    |  1.659s |        1421.5M |         10.6M |   1.01x |
| fp      | bolt-cte     |  1.662s |        1591.5M |         11.4M |   1.01x |
```

A second full run from a clean build agreed to within 0.03x on every row.
Inside a VM (no frequency control, noisy neighbours) the times moved by up
to 20 points between runs, while the branch counts stayed within 0.1% - use
bare metal for the times.

- A matching profile gives the most: 1.13x on `main`, 1.20x on `cte`.
  Trained on the other set, about half of that.
- The merged profile is as good as the best single one on every test set,
  and the best on the two nobody trained on.
- BOLT gets 1–5%. It only changes layout, and here a lot of PGO's gain
  comes from elsewhere: with the `main` profile, 37 functions that
  `sqlite3VdbeExec` used to call get inlined into it (49KB -> 80KB),
  while the whole `.text` shrinks, because code that never ran is
  compiled for size.
