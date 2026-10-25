#!/usr/bin/env bash
# needs perf (apt install linux-perf). works without it too, just timing.
# extra args go to make, e.g. ./bench.sh LLVM_SUFFIX=-18
set -euo pipefail

cd "$(dirname "$0")"
make -s all "$@" 2>&1 | grep -v 'could not be optimized' || true

RUNS=${RUNS:-5}
WORKLOADS=${WORKLOADS:-"main orm cte fp"}
TRAIN=$(make -s -p -n "$@" 2>/dev/null | grep -oP '^TRAIN = \K.*')
MERGED=$(make -s -p -n "$@" 2>/dev/null | grep -oP '^MERGED = \K.*')

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

BINS="base:st_base"
for t in $TRAIN $MERGED; do BINS="$BINS pgo-$t:st_pgo_$t"; done
for t in $TRAIN; do BINS="$BINS bolt-$t:st_bolt_$t"; done

# speedtest1 times itself, TOTAL is the sum over its test cases. best of
# RUNS; --verify adds work, so the result hash comes from one extra run,
# and the counters from another.
measure() {
    local bin=$1 wl=$2
    local args=$(make -s "print-run-$wl" "${@:3}")
    local best="" t
    for _ in $(seq "$RUNS"); do
        t=$("./$bin" $args | grep -oP 'TOTAL\.+\s+\K[0-9.]+')
        best=$(awk -v a="${best:-$t}" -v b="$t" 'BEGIN { print (b < a) ? b : a }')
    done
    local sum=$("./$bin" $args --verify | grep -oP 'Verification Hash: \K.*' | tr ' ' _)

    local taken="n/a" misses="n/a"
    local evs=$(echo "$TAKEN_EV,$ICACHE_EV" | sed 's/^,//; s/,$//')
    if [ -n "$evs" ]; then
        local tmp=$(mktemp)
        perf stat -x, -e "$evs" "./$bin" $args >/dev/null 2>"$tmp"
        [ -n "$TAKEN_EV" ] && taken=$(grep -F ",$TAKEN_EV" "$tmp" | cut -d, -f1)
        [ -n "$ICACHE_EV" ] && misses=$(grep -F ",$ICACHE_EV" "$tmp" | cut -d, -f1)
        rm -f "$tmp"
    fi
    echo "$best $taken $misses $sum"
}

millions() {
    awk -v n="$1" 'BEGIN { if (n ~ /^[0-9]+$/) printf "%.1fM", n / 1e6; else print n }'
}

echo "bolt profile: $(make -s print-bolt-profile "$@"), trained on: $TRAIN"
echo
echo "| testset | binary       | time    | taken branches | icache misses | speedup |"
echo "|---------|--------------|---------|----------------|---------------|---------|"
for wl in $WORKLOADS; do
    base_time=""
    base_sum=""
    for entry in $BINS; do
        label=${entry%%:*}
        bin=${entry#*:}
        read -r t taken misses sum <<<"$(measure "$bin" "$wl" "$@")"
        [ -z "$base_time" ] && base_time=$t
        [ -z "$base_sum" ] && base_sum=$sum
        if [ "$sum" != "$base_sum" ]; then
            echo "error: $bin gives hash $sum on $wl, st_base gives $base_sum" >&2
            exit 1
        fi
        speedup=$(awk -v b="$base_time" -v t="$t" 'BEGIN { printf "%.2fx", b / t }')
        printf '| %-7s | %-12s | %6ss | %14s | %13s | %7s |\n' \
            "$wl" "$label" "$t" "$(millions "$taken")" "$(millions "$misses")" "$speedup"
    done
done
