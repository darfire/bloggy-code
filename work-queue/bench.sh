#!/usr/bin/env bash
# needs SMT on and visible - bare metal, not a VM. pin the clock first:
#   sudo ../cpufreq.sh max
set -euo pipefail

cd "$(dirname "$0")"
make queue -s

HAVE_SMT=1
if ! ./queue same-core 0 1 >/dev/null 2>&1; then
    HAVE_SMT=0
    echo "note: no hyperthread sibling for cpu0 here, same-core column shows n/a" >&2
fi

# best of 3 - noise only ever makes it slower
best() {
    if [ "$HAVE_SMT" -eq 0 ] && [ "$1" = same-core ]; then
        echo "n/a"
        return
    fi
    for _ in 1 2 3; do
        ./queue "$1" "$2" "$3" | grep -oP 'ns_per_item=\K[0-9.]+'
    done | sort -n | head -1
}

ratio() {
    awk -v a="$1" -v b="$2" 'BEGIN { if (a+0 > 0 && b+0 > 0) printf "%.2fx", a/b; else print "n/a" }'
}

echo "ns per item for the whole job (lower is better)."
echo "work = per-item multiply chain length; chunk = items taken per grab from the shared counter."
echo
echo "| work | chunk | alone  | same core | two cores | same core vs two cores |"
echo "|------|-------|--------|-----------|-----------|------------------------|"
for chunk in 1 64; do
    for w in 0 10 25 50 100; do
        a=$(best alone "$w" "$chunk")
        s=$(best same-core "$w" "$chunk")
        t=$(best two-cores "$w" "$chunk")
        # >1 means same core finished first
        printf '| %4d | %5d | %6s | %9s | %9s | %22s |\n' "$w" "$chunk" "$a" "$s" "$t" "$(ratio "$t" "$s")"
    done
done
