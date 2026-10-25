#!/usr/bin/env bash
# runs every workload on every build from ./build.sh. needs perf for the
# counters, works without it too, just timing.
#   ./bench.sh
#   TRAIN=text ./bench.sh   compare the builds trained on text instead
set -euo pipefail

cd "$(dirname "$0")"

TRAIN=${TRAIN:-numeric}
RUNS=${RUNS:-5}
WORKLOADS=${WORKLOADS:-"numeric:20 text:15 objects:40"}

HAVE_PERF=1
command -v perf >/dev/null 2>&1 || HAVE_PERF=0

# vendor-specific names first, see ../pgo-dispatch/bench.sh
probe() {
    [ "$HAVE_PERF" -eq 1 ] || return 0
    for ev in "$@"; do
        if perf stat -e "$ev" true >/dev/null 2>&1; then
            echo "$ev"
            return 0
        fi
    done
}
TAKEN_EV=$(probe ex_ret_brn_tkn br_inst_retired.near_taken)
ICACHE_EV=$(probe ic_tag_hit_miss.instruction_cache_miss L1-icache-load-misses)
ITLB_EV=$(probe iTLB-load-misses)

BINS="base:build/base/python
base+bolt:build/base/python.bolt-$TRAIN
pgo:build/pgo/python
pgo+bolt:build/pgo/python.bolt-$TRAIN
pgo-$TRAIN:build/pgo-$TRAIN/python
switch:build/base-switch/python
switch+bolt:build/base-switch/python.bolt-$TRAIN
pgo-sw:build/pgo-switch/python
pgo-sw+bolt:build/pgo-switch/python.bolt-$TRAIN"

for entry in $BINS; do
    bin=${entry#*:}
    if [ ! -x "$bin" ]; then
        echo "missing $bin - run ./build.sh (with the same TRAIN) first" >&2
        exit 1
    fi
done

# best of RUNS for the time, counters from one extra run
measure() {
    local bin=$1 wl=$2 n=$3
    local best="" t out
    for _ in $(seq "$RUNS"); do
        out=$("$bin" "workloads/$wl.py" "$n")
        t=$(grep -oP 'time=\K[0-9.]+' <<<"$out")
        best=$(awk -v a="${best:-$t}" -v b="$t" 'BEGIN { print (b < a) ? b : a }')
    done
    local sum=$(grep -oP 'checksum=\K\S+' <<<"$out")

    local taken="n/a" icache="n/a" itlb="n/a"
    local evs=$(echo "$TAKEN_EV,$ICACHE_EV,$ITLB_EV" | tr -s , | sed 's/^,//; s/,$//')
    if [ -n "$evs" ]; then
        local tmp=$(mktemp)
        perf stat -x, -e "$evs" "$bin" "workloads/$wl.py" "$n" >/dev/null 2>"$tmp"
        [ -n "$TAKEN_EV" ] && taken=$(grep -F ",$TAKEN_EV" "$tmp" | cut -d, -f1)
        [ -n "$ICACHE_EV" ] && icache=$(grep -F ",$ICACHE_EV" "$tmp" | cut -d, -f1)
        [ -n "$ITLB_EV" ] && itlb=$(grep -F ",$ITLB_EV" "$tmp" | cut -d, -f1)
        rm -f "$tmp"
    fi
    echo "$best $taken $icache $itlb $sum"
}

millions() {
    awk -v n="$1" 'BEGIN { if (n ~ /^[0-9]+$/) printf "%.1fM", n / 1e6; else print n }'
}

echo "trained on: $TRAIN (pgo: cpython's test suite)"
echo
echo "| workload | binary       | time    | taken branches | icache misses | itlb misses | speedup |"
echo "|----------|--------------|---------|----------------|---------------|-------------|---------|"
for w in $WORKLOADS; do
    wl=${w%:*}
    n=${w#*:}
    base_time=""
    base_sum=""
    for entry in $BINS; do
        label=${entry%%:*}
        bin=${entry#*:}
        read -r t taken icache itlb sum <<<"$(measure "$bin" "$wl" "$n")"
        [ -z "$base_time" ] && base_time=$t
        [ -z "$base_sum" ] && base_sum=$sum
        if [ "$sum" != "$base_sum" ]; then
            echo "error: $bin gives checksum $sum on $wl, base gives $base_sum" >&2
            exit 1
        fi
        speedup=$(awk -v b="$base_time" -v t="$t" 'BEGIN { printf "%.2fx", b / t }')
        printf '| %-8s | %-12s | %6ss | %14s | %13s | %11s | %7s |\n' \
            "$wl" "$label" "$t" "$(millions "$taken")" "$(millions "$icache")" "$(millions "$itlb")" "$speedup"
    done
done
