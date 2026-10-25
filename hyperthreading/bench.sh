#!/usr/bin/env bash
# needs SMT on and visible - bare metal, not a VM (most VMs show each vcpu
# as its own core). check: lscpu | grep 'Thread(s) per core' should say 2.
set -euo pipefail

cd "$(dirname "$0")"
make smt -s

if ! ./smt siblings chain chain >/dev/null 2>&1; then
    echo "no hyperthread sibling for cpu0 here - run this on a machine with SMT enabled" >&2
    exit 1
fi

# throwaway run first - clocks take a moment to ramp up
./smt alone wide >/dev/null

# rate in elements/ns for one field of smt's output, e.g. t0 or total
field() {
    grep -oP "$1=(\w+@cpu\d+:)?\K[0-9.]+" <<< "$2"
}

alone_chain=$(field total "$(./smt alone chain)")
alone_wide=$(field total "$(./smt alone wide)")

echo "elements/ns, higher is better. 'vs alone' = total work done compared to one thread on its own."
echo
echo "| threads       | placement | thread 0 | thread 1 | total  | vs alone |"
echo "|---------------|-----------|----------|----------|--------|----------|"
printf '| %-13s | %-9s | %8s | %8s | %6s | %8s |\n' "chain" "alone" "$alone_chain" "-" "$alone_chain" "1.00x"
printf '| %-13s | %-9s | %8s | %8s | %6s | %8s |\n' "wide" "alone" "$alone_wide" "-" "$alone_wide" "1.00x"

row() {
    local a=$1 b=$2 place=$3 base=$4 out t0 t1 total ratio
    out=$(./smt "$place" "$a" "$b")
    t0=$(field t0 "$out")
    t1=$(field t1 "$out")
    total=$(field total "$out")
    if [ "$base" = "-" ]; then
        ratio="-"
    else
        ratio=$(awk -v t="$total" -v b="$base" 'BEGIN { printf "%.2fx", t/b }')
    fi
    printf '| %-13s | %-9s | %8s | %8s | %6s | %8s |\n' "$a + $b" "$place" "$t0" "$t1" "$total" "$ratio"
}

# same core: the interesting rows
row chain chain siblings "$alone_chain"
row wide wide siblings "$alone_wide"
# mixed: does the latency-bound thread even notice the busy one? no single
# baseline for the total here - compare each thread column to its alone row
row chain wide siblings "-"

# separate cores: the ceiling - what two threads get with nothing shared
row chain chain cores "$alone_chain"
row wide wide cores "$alone_wide"
