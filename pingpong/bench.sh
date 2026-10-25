#!/usr/bin/env bash
# usage:
#   ./bench.sh               cpu0 against every other cpu, labeled by what
#                            the two share, all three wait modes
#   ./bench.sh matrix [mode] every physical core against every other (one
#                            cpu per core), default mode spin
#
# the "same core" rows need SMT on and visible (bare metal - VMs usually
# show each vcpu as its own core); everything else works anywhere.
set -euo pipefail

cd "$(dirname "$0")"
make pingpong -s

SYS=/sys/devices/system/cpu

# "0-3,8,10-11" -> "0 1 2 3 8 10 11"
expand() {
    local part lo hi out=""
    IFS=, read -ra parts <<< "$1"
    for part in "${parts[@]}"; do
        if [[ $part == *-* ]]; then
            lo=${part%-*}; hi=${part#*-}
            out="$out $(seq -s ' ' "$lo" "$hi")"
        else
            out="$out $part"
        fi
    done
    echo "$out"
}

contains() {
    local x
    for x in $1; do [ "$x" = "$2" ] && return 0; done
    return 1
}

siblings=$(expand "$(cat $SYS/cpu0/topology/thread_siblings_list)")
l3=""
[ -r $SYS/cpu0/cache/index3/shared_cpu_list ] && l3=$(expand "$(cat $SYS/cpu0/cache/index3/shared_cpu_list)")
cpus=$(expand "$(cat $SYS/online)")

# best of 3 - one-off scheduler or interrupt noise only ever makes it slower
best() {
    for _ in 1 2 3; do
        ./pingpong "$1" "$2" "$3" | grep -oP 'oneway_ns=\K[0-9.]+'
    done | sort -n | head -1
}

# warm-up, clocks take a moment to ramp
./pingpong 0 "$(echo $cpus | awk '{ print $2 }')" spin >/dev/null

if [ "${1:-}" = matrix ]; then
    mode=${2:-spin}
    # first cpu of each physical core, in core order
    cores=""
    seen=""
    for c in $cpus; do
        first=$(expand "$(cat $SYS/cpu$c/topology/thread_siblings_list)" | awk '{ print $1 }')
        contains "$seen" "$first" && continue
        seen="$seen $first"
        cores="$cores $c"
    done

    echo "one-way hand-off latency between physical cores, ns, mode=$mode"
    echo "(row = ping cpu, column = pong cpu; diagonal is the same core, skipped)"
    echo
    header="|     "
    sep="|-----"
    for b in $cores; do
        header="$header| $(printf '%5s' "cpu$b") "
        sep="$sep|-------"
    done
    echo "$header|"
    echo "$sep|"
    for a in $cores; do
        line="| $(printf '%3s' "$a") "
        for b in $cores; do
            if [ "$a" = "$b" ]; then
                line="$line|     - "
            else
                line="$line| $(printf '%5s' "$(best "$a" "$b" "$mode")") "
            fi
        done
        echo "$line|"
    done
    exit 0
fi

echo "one-way hand-off latency from cpu0, ns (lower is better):"
echo
echo "| cpu | shares with cpu0 | spin   | pause  | chained |"
echo "|-----|------------------|--------|--------|---------|"
# same core first, then same L3, then the rest
for class in "same core" "same L3" "different L3"; do
    for c in $cpus; do
        [ "$c" = 0 ] && continue
        if contains "$siblings" "$c"; then
            k="same core"
        elif contains "$l3" "$c"; then
            k="same L3"
        else
            k="different L3"
        fi
        [ "$k" = "$class" ] || continue
        printf '| %3d | %-16s | %6s | %6s | %7s |\n' "$c" "$k" \
            "$(best 0 "$c" spin)" "$(best 0 "$c" pause)" "$(best 0 "$c" chained)"
    done
done
