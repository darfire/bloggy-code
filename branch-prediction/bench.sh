#!/usr/bin/env bash
# counters come from perf_event_open inside the binary, no perf tool needed.
# if the kernel won't give us counters (perf_event_paranoid, VM without a
# PMU), misses show up as n/a and you just get timing.
set -euo pipefail

cd "$(dirname "$0")"
make dispatch -s

print_row() {
    local n=$1 label=$2 time_s=$3 misses=$4 rate=$5 baseline=$6
    local speedup
    speedup=$(awk -v b="$baseline" -v t="$time_s" 'BEGIN { if (t+0 > 0) printf "%.2fx", b/t; else print "n/a" }')
    printf '| %8d | %-6s | %8ss | %13s | %9s | %7s |\n' "$n" "$label" "$time_s" "$misses" "$rate" "$speedup"
}

measure() {
    local n=$1 mode=$2 out time_s branches misses rate
    out=$(./dispatch "$n" "$mode")
    time_s=$(grep -oP 'time=\K[0-9.]+' <<< "$out")
    branches=$(grep -oP 'branches=\K-?[0-9]+' <<< "$out")
    misses=$(grep -oP 'misses=\K-?[0-9]+' <<< "$out")
    if [ "$misses" -lt 0 ] || [ "$branches" -le 0 ]; then
        misses="n/a"; rate="n/a"
    else
        rate=$(awk -v m="$misses" -v b="$branches" 'BEGIN { printf "%.1f%%", 100*m/b }')
    fi
    echo "$time_s $misses $rate"
}

echo "| nitems   | mode   | time      | branch misses | miss rate | speedup |"
echo "|----------|--------|-----------|---------------|-----------|---------|"
for n in 10000 100000 1000000; do
    read -r rnd_time rnd_misses rnd_rate <<< "$(measure "$n" random)"
    read -r srt_time srt_misses srt_rate <<< "$(measure "$n" sorted)"

    # speedup relative to random - that's the slow one
    print_row "$n" "random" "$rnd_time" "$rnd_misses" "$rnd_rate" "$rnd_time"
    print_row "$n" "sorted" "$srt_time" "$srt_misses" "$srt_rate" "$rnd_time"
done
