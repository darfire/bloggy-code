#!/usr/bin/env bash
# pin cpu frequency for benchmarking, and put it back afterwards.
#
#   sudo ./cpufreq.sh status    what it's set to now, and actual clocks
#   sudo ./cpufreq.sh max       performance governor, boost on, min = max
#                               = highest (boost) frequency
#   sudo ./cpufreq.sh base      boost off, min = max = base frequency.
#                               slower, but the most repeatable: boost
#                               depends on temperature and how many cores
#                               are busy, base doesn't
#   sudo ./cpufreq.sh restore   back to how it was before the first change
#
# "max" asks for the highest clock all the time, it can't force it - the
# chip still backs off when it hits power or thermal limits. check with
# `status` (or turbostat) while a benchmark is running.
#
# handles amd-pstate (active/passive/guided), acpi-cpufreq and
# intel_pstate. needs root.
set -euo pipefail

CPU_SYS=${CPU_SYS:-/sys/devices/system/cpu}
SAVE=${SAVE:-/tmp/cpufreq-saved}

policies() {
    ls -d "$CPU_SYS"/cpu[0-9]*/cpufreq 2>/dev/null | sort -V
}

# write, but don't die if the driver refuses (e.g. amd-pstate active mode
# rejects EPP writes while the governor is "performance" - it's already
# forced to performance then)
try_write() {
    local value=$1 file=$2
    [ -e "$file" ] || return 0
    if ! echo "$value" > "$file" 2>/dev/null; then
        echo "  (couldn't write $value to $file)" >&2
    fi
}

# boost has a different knob depending on driver and kernel version
boost_set() {
    local on=$1 p
    if [ -e "$CPU_SYS/intel_pstate/no_turbo" ]; then
        try_write $((1 - on)) "$CPU_SYS/intel_pstate/no_turbo"
    elif [ -e "$CPU_SYS/cpufreq/boost" ]; then
        try_write "$on" "$CPU_SYS/cpufreq/boost"
    fi
    # amd-pstate since 6.11 has it per policy too
    for p in "$CPU_SYS"/cpufreq/policy*/boost; do
        [ -e "$p" ] && try_write "$on" "$p"
    done
    return 0
}

boost_get() {
    if [ -e "$CPU_SYS/intel_pstate/no_turbo" ]; then
        echo $((1 - $(cat "$CPU_SYS/intel_pstate/no_turbo")))
    elif [ -e "$CPU_SYS/cpufreq/boost" ]; then
        cat "$CPU_SYS/cpufreq/boost"
    elif [ -e "$CPU_SYS/cpufreq/policy0/boost" ]; then
        cat "$CPU_SYS/cpufreq/policy0/boost"
    else
        echo "n/a"
    fi
}

# base (non-boost) frequency in kHz, from whichever file this driver has
base_khz() {
    local cpu=$1
    if [ -r "$cpu/acpi_cppc/nominal_freq" ]; then
        echo $(( $(cat "$cpu/acpi_cppc/nominal_freq") * 1000 ))   # MHz there
    elif [ -r "$cpu/cpufreq/base_frequency" ]; then
        cat "$cpu/cpufreq/base_frequency"
    else
        # last resort: with boost off, most drivers cap max at base
        cat "$cpu/cpufreq/scaling_max_freq"
    fi
}

save() {
    if [ -e "$SAVE" ]; then
        echo "keeping earlier saved settings in $SAVE (restore uses those)"
        return
    fi
    local p
    {
        echo "boost $(boost_get)"
        for p in $(policies); do
            echo "policy $p $(cat "$p/scaling_governor") $(cat "$p/scaling_min_freq") $(cat "$p/scaling_max_freq") $(cat "$p/energy_performance_preference" 2>/dev/null || echo -)"
        done
    } > "$SAVE"
    echo "saved current settings to $SAVE"
}

# set min = max = khz on one policy. order matters: the kernel rejects
# min > max, so raise max first when going up, lower min first going down
pin_policy() {
    local p=$1 khz=$2
    if [ "$khz" -ge "$(cat "$p/scaling_max_freq")" ]; then
        try_write "$khz" "$p/scaling_max_freq"
        try_write "$khz" "$p/scaling_min_freq"
    else
        try_write "$khz" "$p/scaling_min_freq"
        try_write "$khz" "$p/scaling_max_freq"
    fi
}

status() {
    local driver p cpu
    driver=$(cat "$CPU_SYS/cpu0/cpufreq/scaling_driver" 2>/dev/null || echo "none")
    echo "driver:  $driver"
    [ -r "$CPU_SYS/amd_pstate/status" ] && echo "amd-pstate mode: $(cat "$CPU_SYS/amd_pstate/status")"
    echo "boost:   $(boost_get)"
    echo
    printf '%-6s %-12s %-20s %10s %10s %10s %10s\n' cpu governor epp min_mhz max_mhz hw_max_mhz cur_mhz
    for p in $(policies); do
        cpu=$(basename "$(dirname "$p")")
        printf '%-6s %-12s %-20s %10s %10s %10s %10s\n' "$cpu" \
            "$(cat "$p/scaling_governor")" \
            "$(cat "$p/energy_performance_preference" 2>/dev/null || echo -)" \
            $(( $(cat "$p/scaling_min_freq") / 1000 )) \
            $(( $(cat "$p/scaling_max_freq") / 1000 )) \
            $(( $(cat "$p/cpuinfo_max_freq") / 1000 )) \
            $(( $(cat "$p/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 ))
    done
}

set_max() {
    local p
    save
    boost_set 1
    for p in $(policies); do
        try_write performance "$p/scaling_governor"
        try_write performance "$p/energy_performance_preference"
        pin_policy "$p" "$(cat "$p/cpuinfo_max_freq")"
    done
}

set_base() {
    local p
    save
    boost_set 0
    for p in $(policies); do
        try_write performance "$p/scaling_governor"
        try_write performance "$p/energy_performance_preference"
        pin_policy "$p" "$(base_khz "$(dirname "$p")")"
    done
}

restore() {
    if [ ! -e "$SAVE" ]; then
        echo "nothing saved in $SAVE - nothing to restore" >&2
        exit 1
    fi
    local kind a b c d e p
    while read -r kind a b c d e; do
        if [ "$kind" = boost ]; then
            [ "$a" != n/a ] && boost_set "$a"
        elif [ "$kind" = policy ]; then
            # policy path, governor, min, max, epp
            p=$a
            # widen first so neither write gets rejected, then narrow
            try_write "$(cat "$p/cpuinfo_min_freq")" "$p/scaling_min_freq"
            try_write "$(cat "$p/cpuinfo_max_freq")" "$p/scaling_max_freq"
            try_write "$b" "$p/scaling_governor"
            [ "$e" != - ] && try_write "$e" "$p/energy_performance_preference"
            try_write "$d" "$p/scaling_max_freq"
            try_write "$c" "$p/scaling_min_freq"
        fi
    done < "$SAVE"
    rm -f "$SAVE"
    echo "restored"
}

if [ -z "$(policies)" ]; then
    echo "no cpufreq in $CPU_SYS - frequency scaling isn't exposed here (VMs usually don't)" >&2
    exit 1
fi

case "${1:-status}" in
    status) status ;;
    max) set_max; echo; status ;;
    base) set_base; echo; status ;;
    restore) restore; echo; status ;;
    *) echo "usage: $0 status|max|base|restore" >&2; exit 1 ;;
esac
