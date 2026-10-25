#!/usr/bin/env bash
# needs perf (apt install linux-perf). works without it too, just no icache%.
set -euo pipefail

cd "$(dirname "$0")"
make all -s

HAVE_PERF=1
command -v perf >/dev/null 2>&1 || HAVE_PERF=0

# not every machine/kernel exposes these specific raw events (seen this break
# before) - probe once instead of assuming, and fall back to plain timing.
HAVE_ICACHE=0
if [ "$HAVE_PERF" -eq 1 ] && perf stat -e task-clock,L1-icache-load-misses,L1-icache-loads true >/dev/null 2>&1; then
    HAVE_ICACHE=1
fi
if [ "$HAVE_PERF" -eq 1 ] && [ "$HAVE_ICACHE" -eq 0 ]; then
    echo "note: perf found but L1-icache-load-misses/-loads aren't usable here, falling back to timing only" >&2
fi

measure() {
    local bin=$1 n=$2
    local tmp=$(mktemp)
    local time_s misses

    if [ "$HAVE_ICACHE" -eq 1 ]; then
        perf stat -e task-clock,L1-icache-load-misses,L1-icache-loads \
            "./$bin" "$n" >"$tmp.out" 2>"$tmp.perf"
        time_s=$(grep -oP 'time=\K[0-9.]+' "$tmp.out" || true)
        misses=$(grep -oP '^\s*[0-9,]+(?=\s+L1-icache-load-misses)' "$tmp.perf" | tr -d ' ,' || true)
    else
        "./$bin" "$n" >"$tmp.out"
        time_s=$(grep -oP 'time=\K[0-9.]+' "$tmp.out" || true)
        misses="n/a"
    fi
    rm -f "$tmp" "$tmp.out" "$tmp.perf"
    [ -z "$time_s" ] && time_s="0"
    [ -z "$misses" ] && misses="n/a"
    echo "$time_s $misses"
}

print_row() {
    local n=$1 label=$2 time_s=$3 misses=$4 baseline=$5
    local speedup
    speedup=$(awk -v b="$baseline" -v t="$time_s" 'BEGIN { if (t+0 > 0) printf "%.2fx", b/t; else print "n/a" }')
    printf '| %7d | %-12s | %8ss | %13s | %7s |\n' "$n" "$label" "$time_s" "$misses" "$speedup"
}

# note: icache miss *rate* is actually misleading here - fused shows a lower
# rate than staged because its L1-icache-loads denominator is huge (way more
# fetch traffic overall), even though its absolute miss count is way higher.
# raw counts tell the real story.
echo "| nitems  | mode         | time     | icache misses | speedup |"
echo "|---------|--------------|----------|---------------|---------|"
for n in 2000 20000 200000; do
    read -r fused_time fused_misses <<< "$(measure pipeline_fused "$n")"
    read -r staged_time staged_misses <<< "$(measure pipeline_staged "$n")"

    # speedup relative to fused - that's the slow one
    print_row "$n" "fused" "$fused_time" "$fused_misses" "$fused_time"
    print_row "$n" "staged" "$staged_time" "$staged_misses" "$fused_time"
done
