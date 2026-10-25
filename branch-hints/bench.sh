#!/usr/bin/env bash
# needs perf (apt install linux-perf). works without it too, just no counters.
set -euo pipefail

cd "$(dirname "$0")"
make all -s

N=${N:-100000}

HAVE_PERF=1
command -v perf >/dev/null 2>&1 || HAVE_PERF=0

# taken branches is the counter that matters here, and it has no generic
# perf name - AMD and Intel call it different things. probe for whichever
# one this machine has.
TAKEN_EV=""
if [ "$HAVE_PERF" -eq 1 ]; then
    for ev in ex_ret_brn_tkn br_inst_retired.near_taken; do
        if perf stat -e "$ev" true >/dev/null 2>&1; then
            TAKEN_EV=$ev
            break
        fi
    done
    if [ -z "$TAKEN_EV" ]; then
        echo "note: no taken-branch event found, showing n/a for that column" >&2
    fi
fi
HAVE_MISS=0
if [ "$HAVE_PERF" -eq 1 ] && perf stat -e branch-misses true >/dev/null 2>&1; then
    HAVE_MISS=1
fi

# counters cover the whole process (setup included); time is just the loop
measure() {
    local bin=$1 scenario=$2
    local tmp=$(mktemp)
    local time_s taken="n/a" misses="n/a" events=""

    [ -n "$TAKEN_EV" ] && events="$TAKEN_EV"
    [ "$HAVE_MISS" -eq 1 ] && events="${events:+$events,}branch-misses"

    if [ -n "$events" ]; then
        perf stat -x, -e "$events" "./$bin" "$N" "$scenario" >"$tmp.out" 2>"$tmp.perf"
        if [ -n "$TAKEN_EV" ]; then
            taken=$(awk -F, -v e="$TAKEN_EV" '$3 == e { print $1 }' "$tmp.perf")
        fi
        if [ "$HAVE_MISS" -eq 1 ]; then
            misses=$(awk -F, '$3 == "branch-misses" { print $1 }' "$tmp.perf")
        fi
    else
        "./$bin" "$N" "$scenario" >"$tmp.out"
    fi
    time_s=$(grep -oP 'time=\K[0-9.]+' "$tmp.out" || true)
    rm -f "$tmp" "$tmp.out" "$tmp.perf"
    [ -z "$time_s" ] && time_s="0"
    [ -z "$taken" ] && taken="n/a"
    [ -z "$misses" ] && misses="n/a"
    echo "$time_s $taken $misses"
}

# best of a few runs - these loops are short enough that one-off noise shows
best_of() {
    local bin=$1 scenario=$2 best="" line
    for _ in 1 2 3 4 5; do
        line=$(measure "$bin" "$scenario")
        if [ -z "$best" ] || awk -v a="${line%% *}" -v b="${best%% *}" 'BEGIN { exit !(a < b) }'; then
            best=$line
        fi
    done
    echo "$best"
}

# throwaway run first - on the box these were measured on (KVM guest) the
# first ~second ran noticeably slower, which skewed whichever row went first
./hints_none "$N" checks >/dev/null
./hints_none "$N" optional >/dev/null

echo "| scenario | build | time     | taken branches | branch misses | speedup |"
echo "|----------|-------|----------|----------------|---------------|---------|"
for scenario in checks optional; do
    none_t=""
    for build in none right wrong; do
        read -r t tk m <<< "$(best_of "hints_$build" "$scenario")"
        [ -z "$none_t" ] && none_t=$t
        # speedup relative to no hint - that's what you get by default
        speedup=$(awk -v b="$none_t" -v t="$t" 'BEGIN { if (t+0 > 0) printf "%.2fx", b/t; else print "n/a" }')
        printf '| %-8s | %-5s | %7ss | %14s | %13s | %7s |\n' "$scenario" "$build" "$t" "$tk" "$m" "$speedup"
    done
done
