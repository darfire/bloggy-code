#!/usr/bin/env bash
# needs SMT on and visible - bare metal, not a VM. the helper-core column
# works anywhere. pin the clock first for stable numbers:
#   sudo ../cpufreq.sh max
set -euo pipefail

cd "$(dirname "$0")"
make helper -s

HAVE_SMT=1
if ! ./helper helper-sibling 0 >/dev/null 2>&1; then
    HAVE_SMT=0
    echo "note: no hyperthread sibling for cpu0 here, sibling columns show n/a" >&2
fi

# best of 3 - noise only ever makes it slower
best() {
    local mode=$1 w=$2
    if [ "$HAVE_SMT" -eq 0 ] && [[ $mode == *sibling ]]; then
        echo "n/a"
        return
    fi
    for _ in 1 2 3; do
        ./helper "$mode" "$w" | grep -oP 'ns_per_node=\K[0-9.]+'
    done | sort -n | head -1
}

echo "ns per list node, main thread (lower is better)."
echo "work = length of the multiply chain per node. 'cached' = same walk with the list in cache:"
echo "the floor, what a perfect helper would get you."
echo
echo "| work | cached | alone  | helper, same core | helper, other core | busy twin |"
echo "|------|--------|--------|-------------------|--------------------|-----------|"
for w in 0 25 50 100 200 400; do
    printf '| %4d | %6s | %6s | %17s | %18s | %9s |\n' "$w" \
        "$(best cached "$w")" "$(best alone "$w")" "$(best helper-sibling "$w")" \
        "$(best helper-core "$w")" "$(best busy-sibling "$w")"
done
