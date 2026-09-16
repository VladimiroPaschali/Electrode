#!/usr/bin/env bash
# The grecale half of a run: start and stop the replicas, the client, and -- for
# the TC variant -- Electrode's own broadcast offload on the leader.
#
#   sudo ./node.sh start-replicas <variant> <n> 
#   sudo ./node.sh start-tc <leaderIdx>
#   sudo ./node.sh xdp-start <replicas>
#   sudo ./node.sh client <variant> <requests> <clients> <warmup> <procs> <log>
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
# Cores 0-15 are one hardware thread each of the sixteen physical cores on
# grecale; 16-31 are their SMT siblings. The replicas get the physical ones and
# the clients the siblings of the two the system keeps, so that a client never
# shares a core with a replica.
#
# Past fourteen replicas they have to share, and the assignment wraps: at
# thirty-one replicas most cores carry two. That is a property of running a
# thirty-one node cluster on one sixteen-core machine, not of any variant, and
# it is the same for all four.
REPLICA_CPUS=${REPLICA_CPUS:-2-15}
CLIENT_CPUS=${CLIENT_CPUS:-16-19}

# "2-15,20" -> "2 3 4 ... 15 20"
expand_cpus() {
    local spec=$1 out=() part lo hi
    IFS=, read -ra parts <<< "$spec"
    for part in "${parts[@]}"; do
        if [[ $part == *-* ]]; then
            lo=${part%%-*}; hi=${part##*-}
            for (( c = lo; c <= hi; c++ )); do out+=("$c"); done
        else
            out+=("$part")
        fi
    done
    echo "${out[@]}"
}

read -ra REPLICA_CPU_LIST <<< "$(expand_cpus "$REPLICA_CPUS")"
read -ra CLIENT_CPU_LIST <<< "$(expand_cpus "$CLIENT_CPUS")"

mkdir -p "$run"

cmd_start_replicas() {
    local variant=$1 n=$2 i core
    for (( i = 0; i < n; i++ )); do
        core=${REPLICA_CPU_LIST[$(( i % ${#REPLICA_CPU_LIST[@]} ))]}
        ip netns exec "$NS-r$i" env ELECTRODE_BPF_DIR="/run/bpf/r$i" \
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
# A bpffs every namespace can see. `ip netns exec` remounts /sys inside a
# mount namespace of its own, which shadows the one at /sys/fs/bpf; a mount
# made here, in the root namespace, propagates into all of them.
ensure_bpffs() {
    mountpoint -q /run/bpf 2>/dev/null && return
    mkdir -p /run/bpf
    mount -t bpf bpf /run/bpf
}

# Electrode's other offload: the leader's PrepareOK handling, in XDP. Every
# replica gets it, as upstream does, and a pin directory of its own -- they all
# pin the same names.
#
# The TC program goes on with it, and not by choice. FastBroadCast clears the
# quorum bitset whenever it sees a PREPARE leave, *before* its own
# is_broadcast check, and HandlePrepareOK counts into that same bitset. Attach
# the XDP half alone and the entry never matches the current (view, opnum), so
# nothing is ever pruned -- and since FAST_QUORUM_PRUNE compiles the userspace
# quorum count out, a leader that is handed every PrepareOK commits on the
# first one. The two halves of Electrode are not separable.
cmd_xdp_start() {
    local n=$1 i
    ensure_bpffs
    # Old logs first: the readiness check counts files, and a bigger cluster's
    # leftovers make it count "31 of 7".
    rm -f "$run"/xdp*.log
    for (( i = 0; i < n; i++ )); do
        rm -rf "/run/bpf/r$i"; mkdir -p "/run/bpf/r$i"
        ip netns exec "$NS-r$i" env ELECTRODE_BPF_DIR="/run/bpf/r$i" \
            setsid "$root/xdp-handler/fast" "$DEV" -x \
                -c "$root/config.txt" -m "$root/config.macs" -l 0 \
            > "$run/xdp$i.log" 2>&1 &
    done
    sleep 2
    local up
    up=$(grep -l '^ready' "$run"/xdp*.log 2>/dev/null | wc -l)
    [ "$up" -eq "$n" ] || {
        echo "quorum prune up on $up of $n namespaces:" >&2
        grep -h Error "$run"/xdp*.log | head -3 >&2
        exit 1
    }
    grep -ho "(.* mode)" "$run/xdp0.log" | head -1
    echo "quorum prune on $n namespaces"
}

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

# One client process saturates a core well before the cluster saturates: at
# seven replicas it sends seven unicasts per request and sat at 85% of a core
# while the leader was at 75%, so the measurement was of the client. Spreading
# the clients over several processes, one core each, puts the bottleneck back
# where the experiment wants it. The logs are concatenated, and parse.py reads
# one "Completed" line per client wherever it came from.
cmd_client() {
    local variant=$1 requests=$2 clients=$3 warmup=$4 procs=$5 log=$6
    local per=$(( clients / procs )) j pids=()

    if [ $(( per * procs )) -ne "$clients" ]; then
        echo "clients ($clients) must divide by processes ($procs)" >&2
        exit 1
    fi

    # Unlink rather than truncate: with fs.protected_regular set, root cannot
    # open someone else's file for writing in a sticky directory like /tmp.
    rm -f "$log" "$log".* 2>/dev/null || true
    : > "$log"
    for (( j = 0; j < procs; j++ )); do
        # A deadline, because a run that hangs otherwise hangs the whole sweep.
        # It happens: at thirty-one replicas a straggler asks for a state
        # transfer, the leader answers with a message in 1836 fragments, and
        # the cluster livelocks -- upstream's own caveat about the non-critical
        # path. parse.py reports the run as ok=0, which is what it is.
        ip netns exec "$NS-cl" \
            timeout "${CLIENT_TIMEOUT:-300}" \
            taskset -c "${CLIENT_CPU_LIST[$(( j % ${#CLIENT_CPU_LIST[@]} ))]}" \
                "$root/build/$variant/client" \
                -c "$root/config.txt" -m vr -n "$requests" -t "$per" -w "$warmup" \
            > "$log.$j" 2>&1 &
        pids+=($!)
    done
    for j in "${pids[@]}"; do wait "$j" || true; done
    cat "$log".* >> "$log"
    rm -f "$log".*
}

cmd_stop() {
    local p i
    for p in "$run"/*.pid; do
        [ -e "$p" ] || continue
        kill -TERM "$(cat "$p")" 2>/dev/null || true
        rm -f "$p"
    done
    sleep 0.5
    # The client too: a run that timed out leaves one behind, and the next
    # build then fails with ETXTBSY on the binary it is still executing.
    pkill -f "$root/build/.*/replica" 2>/dev/null || true
    pkill -f "$root/build/.*/client" 2>/dev/null || true
    pkill -f "$root/xdp-handler/fast" 2>/dev/null || true
    # `fast` detaches on SIGTERM, but not when it is killed outright, and an
    # XDP program left on mv makes the next attach fail with "Exclusivity flag
    # on, cannot modify".
    for (( i = 0; i < 64; i++ )); do
        ip netns list | awk '{print $1}' | grep -qx "$NS-r$i" || break
        ip netns exec "$NS-r$i" ip link set dev "$DEV" xdpgeneric off 2>/dev/null || true
        ip netns exec "$NS-r$i" ip link set dev "$DEV" xdp off 2>/dev/null || true
    done
    rm -f "$run"/xdp*.log
    rm -rf /run/bpf/r[0-9]* 2>/dev/null || true
    sleep 0.3
    pkill -9 -f "$root/build/.*/replica" 2>/dev/null || true
    pkill -9 -f "$root/build/.*/client" 2>/dev/null || true
    echo stopped
}

case "${1:-}" in
    start-replicas) shift; cmd_start_replicas "$@" ;;
    start-tc)       shift; cmd_start_tc "$@" ;;
    xdp-start)      shift; cmd_xdp_start "$@" ;;
    client)         shift; cmd_client "$@" ;;
    stop)           cmd_stop ;;
    *) echo "usage: $0 {start-replicas <variant> <n>|start-tc <leader>|client ...|stop}" >&2; exit 1 ;;
esac
