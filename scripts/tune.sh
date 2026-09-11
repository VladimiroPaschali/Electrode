#!/usr/bin/env bash
# Put a machine into the state the measurement assumes, and put it back.
#
#   sudo ./tune.sh on  <ifname>
#   sudo ./tune.sh off <ifname>
#
# Two things, both of which otherwise show up in the latency and neither of
# which is what this benchmark is about:
#
#   interrupt coalescing  the mlx5 default adapts rx-usecs to the load, so a
#                         quiet link answers late. Electrode's own setup turns
#                         it off; without that a Paxos round trip carries tens
#                         of microseconds of it.
#   cpufreq governor      schedutil on an idle machine measures the governor.
#
# The previous settings are saved under /var/tmp and restored by `off`, so
# nothing here outlives the run.

set -euo pipefail

# Plain checks rather than ${1:?...}: the '}' of a '{on|off}' inside the
# expansion closes it early, and what follows is then parsed as a redirection.
action=${1:-}
dev=${2:-}
if [ -z "$action" ] || [ -z "$dev" ]; then
    echo "usage: $0 {on|off} <ifname>" >&2
    exit 1
fi
save=/var/tmp/electrode-tune.$dev

governors() { ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true; }

case "$action" in
on)
    if [ ! -e "$save.coalesce" ]; then
        ethtool -c "$dev" > "$save.coalesce" 2>/dev/null || true
    fi
    if [ ! -e "$save.governor" ]; then
        cat $(governors | head -1) > "$save.governor" 2>/dev/null || echo schedutil > "$save.governor"
    fi

    ethtool -C "$dev" adaptive-rx off adaptive-tx off \
        rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1 2>/dev/null \
        || echo "warning: could not set coalescing on $dev" >&2

    for g in $(governors); do echo performance > "$g" 2>/dev/null || true; done
    echo "tuned $dev: coalescing off, governor performance"
    ;;
off)
    if [ -e "$save.coalesce" ]; then
        # Restore the four knobs this script touched, from the saved dump.
        get() { awk -F: "/^$1:/ {gsub(/ /,\"\",\$2); print \$2}" "$save.coalesce"; }
        ethtool -C "$dev" \
            adaptive-rx "$(get 'Adaptive RX' | cut -d' ' -f1 || echo on)" \
            2>/dev/null || true
        ethtool -C "$dev" \
            rx-usecs "$(get 'rx-usecs')" rx-frames "$(get 'rx-frames')" \
            tx-usecs "$(get 'tx-usecs')" tx-frames "$(get 'tx-frames')" \
            2>/dev/null || true
        rm -f "$save.coalesce"
    fi
    if [ -e "$save.governor" ]; then
        for g in $(governors); do cat "$save.governor" > "$g" 2>/dev/null || true; done
        rm -f "$save.governor"
    fi
    echo "restored $dev"
    ;;
*)
    echo "usage: $0 {on|off} <ifname>" >&2; exit 1 ;;
esac
