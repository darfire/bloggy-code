#!/usr/bin/env bash
# needs perf (apt install linux-perf). works without it too, just timing.
# extra args go to make, e.g. ./bench.sh LLVM_BIN=/usr/lib/llvm-18/bin/
set -euo pipefail

cd "$(dirname "$0")"
make -s all "$@"

ITERS=${ITERS:-1000}
RUNS=${RUNS:-5}

HAVE_PERF=1
command -v perf >/dev/null 2>&1 || HAVE_PERF=0

# the interesting counters have vendor-specific names. probe for them
# instead of assuming, the generic L1-icache-load-misses counts something
# much narrower on zen 4.
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
if [ "$HAVE_PERF" -eq 1 ] && { [ -z "$TAKEN_EV" ] || [ -z "$ICACHE_EV" ]; }; then
    echo "note: perf found but some counters aren't usable here, those columns will be n/a" >&2
fi

# best of RUNS for the time, counters from one extra run
measure() {
    local bin=$1 wl=$2
    local best="" t out
    for _ in $(seq "$RUNS"); do
        out=$("./$bin" "$wl" "$ITERS")
        t=$(grep -oP 'time=\K[0-9.]+' <<<"$out")
        best=$(awk -v a="${best:-$t}" -v b="$t" 'BEGIN { print (b < a) ? b : a }')
    done
    local sum=$(grep -oP 'checksum=\K\w+' <<<"$out")

    local taken="n/a" misses="n/a"
    if [ -n "$TAKEN_EV$ICACHE_EV" ]; then
        local evs=$(echo "$TAKEN_EV,$ICACHE_EV" | sed 's/^,//; s/,$//')
        local tmp=$(mktemp)
        perf stat -x, -e "$evs" "./$bin" "$wl" "$ITERS" >/dev/null 2>"$tmp"
        [ -n "$TAKEN_EV" ] && taken=$(grep -F ",$TAKEN_EV" "$tmp" | cut -d, -f1)
        [ -n "$ICACHE_EV" ] && misses=$(grep -F ",$ICACHE_EV" "$tmp" | cut -d, -f1)
        rm -f "$tmp"
    fi
    echo "$best $taken $misses $sum"
}

# counts in millions, they're per run of ITERS * 65536 ops
millions() {
    awk -v n="$1" 'BEGIN { if (n ~ /^[0-9]+$/) printf "%.1fM", n / 1e6; else print n }'
}

BINS="base:vm_base:- pgo:vm_pgo_A:A pgo:vm_pgo_B:B pgo:vm_pgo_AB:A+B bolt:vm_bolt_A:A bolt:vm_bolt_B:B"

echo "bolt profile: $(make -s print-bolt-profile "$@")"
echo
echo "| run on | binary | trained on | time    | taken branches | icache misses | speedup |"
echo "|--------|--------|------------|---------|----------------|---------------|---------|"
for wl in A B; do
    base_sum=""
    base_time=""
    for entry in $BINS; do
        IFS=: read -r label bin trained <<<"$entry"
        read -r t taken misses sum <<<"$(measure "$bin" "$wl")"
        [ -z "$base_time" ] && base_time=$t
        [ -z "$base_sum" ] && base_sum=$sum
        # same program, same result - only the layout should differ
        if [ "$sum" != "$base_sum" ]; then
            echo "error: $bin gives checksum $sum on $wl, vm_base gives $base_sum" >&2
            exit 1
        fi
        speedup=$(awk -v b="$base_time" -v t="$t" 'BEGIN { printf "%.2fx", b / t }')
        printf '| %-6s | %-6s | %-10s | %6ss | %14s | %13s | %7s |\n' \
            "$wl" "$label" "$trained" "$t" "$(millions "$taken")" "$(millions "$misses")" "$speedup"
    done
done
