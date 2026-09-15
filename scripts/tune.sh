#!/usr/bin/env bash
# Put a machine into the state the measurement assumes, and put it back.
#
#   sudo ./tune.sh on  <ifname>
#   sudo ./tune.sh off <ifname>
#
# The governor, always: schedutil on an idle machine measures the governor.
#
# Interrupt coalescing only when asked (COALESCE=off), and it is off by
# default for a reason. Turning it off pins rx-usecs to 0 -- an interrupt per
# packet -- which is right for a latency measurement on a quiet link and wrong
# for a throughput one at scale. At thirty-one replicas on one machine the
# cluster moves some 680,000 packets a second, and an interrupt for each of
# them **halves the throughput**: 10.06 kops with coalescing off against 22.0
# with the driver default, reproducibly, on the same configuration.
#
# Electrode's own setup disables it, but Electrode runs one replica per
# machine, where per-packet interrupts are cheap. Thirty-one replicas sharing a
# NIC is not that.
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
    if [ "${COALESCE:-default}" = off ] && [ ! -e "$save.coalesce" ]; then
        ethtool -c "$dev" > "$save.coalesce" 2>/dev/null || true
    fi
    if [ ! -e "$save.governor" ]; then
        cat $(governors | head -1) > "$save.governor" 2>/dev/null || echo schedutil > "$save.governor"
    fi

    if [ "${COALESCE:-default}" = off ]; then
        ethtool -C "$dev" adaptive-rx off adaptive-tx off \
            rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1 2>/dev/null \
            || echo "warning: could not set coalescing on $dev" >&2
    fi

    for g in $(governors); do echo performance > "$g" 2>/dev/null || true; done
    echo "tuned $dev: governor performance${COALESCE:+, coalescing $COALESCE}"
    ;;
off)
    if [ -e "$save.coalesce" ]; then
        # `ethtool -c` prints the adaptive pair on one line,
        #   Adaptive RX: on  TX: on
        # and everything else as "name: value". Splitting that first line on
        # ":" gave "offTX" and every restore of it failed silently, which left
        # both machines with adaptive coalescing off after a run.
        val() { awk -v k="$1" -F': *' '$1 == k {print $2; exit}' "$save.coalesce"; }
        arx=$(awk '/^Adaptive RX:/ {print $3}' "$save.coalesce")
        atx=$(awk '/^Adaptive RX:/ {print $5}' "$save.coalesce")

        ethtool -C "$dev" adaptive-rx "${arx:-on}" adaptive-tx "${atx:-on}" \
            2>/dev/null || echo "warning: could not restore adaptive coalescing" >&2
        ethtool -C "$dev" \
            rx-usecs "$(val rx-usecs)" rx-frames "$(val rx-frames)" \
            tx-usecs "$(val tx-usecs)" tx-frames "$(val tx-frames)" \
            2>/dev/null || echo "warning: could not restore coalescing values" >&2
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
