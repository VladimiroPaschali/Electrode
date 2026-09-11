#!/usr/bin/env bash
# The grecale half of a run: start and stop the replicas, the client, and -- for
# the TC variant -- Electrode's own broadcast offload on the leader.
#
#   sudo ./node.sh start-replicas <variant> <n> 
#   sudo ./node.sh start-tc <leaderIdx>
#   sudo ./node.sh client <variant> <requests> <threads> <warmup> <logfile>
#   sudo ./node.sh stop
#
# Everything runs inside the namespaces cluster.sh made, so every packet between
# two cluster members crosses the wire through the DUT.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
run=/tmp/electrode-run
NS=elec
DEV=mv
CORE_BASE=${CORE_BASE:-2}      # replica i runs on core CORE_BASE+i
CLIENT_CORE=${CLIENT_CORE:-1}

mkdir -p "$run"

cmd_start_replicas() {
    local variant=$1 n=$2 i core
    for (( i = 0; i < n; i++ )); do
        core=$(( CORE_BASE + i ))
        ip netns exec "$NS-r$i" \
            setsid taskset -c "$core" "$root/build/$variant/replica" \
                -c "$root/config.txt" -m vr -i "$i" \
                > "$run/replica$i.log" 2>&1 &
        echo $! > "$run/replica$i.pid"
    done
    sleep 1
    for (( i = 0; i < n; i++ )); do
        kill -0 "$(cat "$run/replica$i.pid")" 2>/dev/null || {
            echo "replica $i died at once:" >&2; tail -5 "$run/replica$i.log" >&2; exit 1; }
    done
    echo "started $n replicas ($variant)"
}

# Electrode's broadcast offload lives on the leader's egress hook. Its
# map_configure carries a destination MAC per replica, which it writes into the
# clone; here that has to be the fan-out node's MAC and not the follower's,
# exactly as the leader's own stack would have resolved it -- a macvlan handed a
# frame addressed to another macvlan on the same parent short-circuits it in
# software, and the packet would never reach the wire.
cmd_start_tc() {
    local leader=${1:-0} gw_mac
    gw_mac=$(cat "$root/config.gwmac")

    awk -v m="$gw_mac" '{print m}' "$root/config.macs" > "$root/config.macs.gw"

    ip netns exec "$NS-r$leader" \
        setsid "$root/xdp-handler/fast" "$DEV" \
            -c "$root/config.txt" -m "$root/config.macs.gw" -l "$leader" \
            > "$run/tc.log" 2>&1 &
    echo $! > "$run/tc.pid"

    for _ in $(seq 50); do
        grep -q '^ready' "$run/tc.log" && { echo "FastBroadCast up on $NS-r$leader"; return; }
        sleep 0.1
    done
    echo "FastBroadCast did not come up:" >&2; cat "$run/tc.log" >&2; exit 1
}

cmd_client() {
    local variant=$1 requests=$2 threads=$3 warmup=$4 log=$5
    ip netns exec "$NS-cl" \
        taskset -c "$CLIENT_CORE" "$root/build/$variant/client" \
            -c "$root/config.txt" -m vr -n "$requests" -t "$threads" -w "$warmup" \
        > "$log" 2>&1
}

cmd_stop() {
    local p
    for p in "$run"/*.pid; do
        [ -e "$p" ] || continue
        kill -TERM "$(cat "$p")" 2>/dev/null || true
        rm -f "$p"
    done
    sleep 0.5
    pkill -f "$root/build/.*/replica" 2>/dev/null || true
    pkill -f "$root/xdp-handler/fast" 2>/dev/null || true
    sleep 0.3
    pkill -9 -f "$root/build/.*/replica" 2>/dev/null || true
    echo stopped
}

case "${1:-}" in
    start-replicas) shift; cmd_start_replicas "$@" ;;
    start-tc)       shift; cmd_start_tc "$@" ;;
    client)         shift; cmd_client "$@" ;;
    stop)           cmd_stop ;;
    *) echo "usage: $0 {start-replicas <variant> <n>|start-tc <leader>|client ...|stop}" >&2; exit 1 ;;
esac
