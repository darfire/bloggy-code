#!/usr/bin/env bash
# needs perf (apt install linux-perf). works without it too, just no miss%.
set -euo pipefail

cd "$(dirname "$0")"
make -s

HAVE_PERF=1
command -v perf >/dev/null 2>&1 || HAVE_PERF=0

measure() {
    local n=$1 ld=$2 reps=$3 mode=$4
    local tmp=$(mktemp)
    local time_s pct

    if [ "$HAVE_PERF" -eq 1 ]; then
        perf stat -e task-clock,cache-references,cache-misses \
            ./aliasing "$n" "$ld" "$reps" "$mode" >"$tmp.out" 2>"$tmp.perf"
        time_s=$(grep -oP 'time=\K[0-9.]+' "$tmp.out")

        # perf's formatting isn't consistent across versions/paranoid levels -
        # sometimes there's no "% of all cache refs" line, sometimes numbers
        # have thousands separators. just grab the raw counts and do the math.
        local refs=$(grep -oP '^\s*[0-9,]+(?=\s+cache-references)' "$tmp.perf" | tr -d ' ,')
        local misses=$(grep -oP '^\s*[0-9,]+(?=\s+cache-misses)' "$tmp.perf" | tr -d ' ,')
        pct=$(awk -v m="$misses" -v r="$refs" 'BEGIN { if (r>0) printf "%.2f", m/r*100; else print "n/a" }')
    else
        ./aliasing "$n" "$ld" "$reps" "$mode" >"$tmp.out"
        time_s=$(grep -oP 'time=\K[0-9.]+' "$tmp.out")
        pct="n/a"
    fi
    rm -f "$tmp" "$tmp.out" "$tmp.perf"
    echo "$time_s $pct"
}

print_row() {
    local n=$1 label=$2 ld=$3 time_s=$4 pct=$5 baseline=$6
    local speedup=$(awk -v b="$baseline" -v t="$time_s" 'BEGIN { printf "%.2fx", b/t }')
    printf '| %4d | %-22s | %5d | %7ss | %6s%% | %6s |\n' "$n" "$label" "$ld" "$time_s" "$pct" "$speedup"
}

echo "| N    | access pattern         | LD    | time    | miss % | speedup |"
echo "|------|------------------------|-------|---------|--------|---------|"
for n in 512 1024 2048 4096; do
    # keep roughly the same total element-ops across sizes so runs don't
    # get out of hand at the big end
    reps=$(( 5000000 / (n * n) ))
    [ "$reps" -lt 1 ] && reps=1

    read -r row_time row_pct <<< "$(measure "$n" "$n" "$reps" row)"
    read -r pow2_time pow2_pct <<< "$(measure "$n" "$n" "$reps" col)"
    read -r pad_time pad_pct <<< "$(measure "$n" "$((n + 1))" "$reps" col)"

    # speedup is always relative to the pow2 case - that's the slow one
    print_row "$n" "row-major (baseline)" "$n" "$row_time" "$row_pct" "$pow2_time"
    print_row "$n" "column, pow2 LD" "$n" "$pow2_time" "$pow2_pct" "$pow2_time"
    print_row "$n" "column, padded LD" "$((n + 1))" "$pad_time" "$pad_pct" "$pow2_time"
done
