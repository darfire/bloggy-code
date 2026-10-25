#!/usr/bin/env bash
# cycles come from perf_event_open inside the binary, no perf tool needed.
# if the kernel won't give us counters, falls back to ns/elem - noisier,
# since it moves with clock speed.
set -euo pipefail

cd "$(dirname "$0")"
make all -s

BUILDS="sum_scalar sum_o2 sum_fastmath sum_fastmath_unroll"

# throwaway run first - on the box these were measured on (KVM guest) the
# first fraction of a second ran noticeably slower
./sum_scalar 1 >/dev/null

UNIT=cycles
./sum_scalar 8 | grep -q 'cycles_per_elem=-' && UNIT=ns

# best of 3, in whichever unit we have
measure() {
    local bin=$1 k=$2 key
    [ "$UNIT" = cycles ] && key=cycles_per_elem || key=ns_per_elem
    for _ in 1 2 3; do
        "./$bin" "$k" | grep -oP "$key=\K[0-9.]+"
    done | sort -n | head -1
}

echo "$UNIT per element (lower is better):"
echo
echo "| accumulators | scalar | -O2   | -O3 fast-math | + unroll/var-expand | sum (float) | exact (double) |"
echo "|--------------|--------|-------|---------------|---------------------|-------------|----------------|"
for k in 1 2 4 6 8; do
    row=""
    for b in $BUILDS; do
        row="$row $(measure "$b" "$k")"
    done
    read -r sc o2 fm fu <<< "$row"
    # sums from the scalar build - that's the summation order as written
    out=$(./sum_scalar "$k")
    s=$(grep -oP ' sum=\K[0-9.]+' <<< "$out")
    exact=$(grep -oP 'exact=\K[0-9.]+' <<< "$out")
    printf '| %12d | %6s | %5s | %13s | %19s | %11s | %14s |\n' "$k" "$sc" "$o2" "$fm" "$fu" "$s" "$exact"
done
