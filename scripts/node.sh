#!/usr/bin/env bash
# The grecale half of a run: start and stop the replicas, the client, and -- for
# the TC variant -- Electrode's own broadcast offload on the leader.
#
#   sudo ./node.sh start-replicas <variant> <n> 
#   sudo ./node.sh start-tc <leaderIdx>
#   sudo ./node.sh leader-cpu [idx]
#   sudo ./node.sh sample-cpu <idx> <outfile>
#   sudo ./node.sh client <variant> <requests> <clients> <warmup> <procs> <log> [duration]
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

# PREPARE_PAD travels to the replicas as ELECTRODE_PREPARE_PAD: dead weight the
# leader hangs on the PREPARE, which is the one message the fan-out node
# duplicates. It is set on every replica and not just the leader, because any of
# them can become one.
cmd_start_replicas() {
    local variant=$1 n=$2 i core
    for (( i = 0; i < n; i++ )); do
        core=${REPLICA_CPU_LIST[$(( i % ${#REPLICA_CPU_LIST[@]} ))]}
        ip netns exec "$NS-r$i" env ELECTRODE_BPF_DIR="/run/bpf/r$i" \
            ELECTRODE_PREPARE_PAD="${PREPARE_PAD:-0}" \
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

# What the leader costs, which is the resource the whole comparison is about:
# the offloads take work off the leader's core, so a run in which that core is
# not saturated is a run whose bottleneck is somewhere else and whose numbers
# say nothing about the offload.
#
# Prints, for replica <idx>: the process's own ticks, then its core's busy and
# total ticks. Two of these around the client run give both the share of the
# core the replica itself used and what the core did altogether -- and since a
# core's total ticks *are* its wall time, neither needs a clock.
cmd_leader_cpu() {
    local idx=${1:-0} pid core t b tot
    core=${REPLICA_CPU_LIST[$(( idx % ${#REPLICA_CPU_LIST[@]} ))]}
    pid=$(cat "$run/replica$idx.pid" 2>/dev/null || echo "")
    t=0
    if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
        # utime + stime. The comm field holds no spaces for "replica", so the
        # field numbers are not shifted.
        t=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    fi
    read -r b tot <<< "$(awk -v c="cpu$core" \
        '$1 == c { print $2+$3+$4+$7+$8+$9, $2+$3+$4+$5+$6+$7+$8+$9 }' /proc/stat)"
    echo "$t ${b:-0} ${tot:-0} $core"
}

# The same numbers once a second, until killed. Averaging over the whole client
# run understates the leader badly: the window also holds the client processes
# starting, the warmup ramp and the tail where the early clients have finished
# and the load has fallen away. Measured over the whole window the leader's
# core reads 78%; sampled in the middle of the same run it is at 99%. Only the
# second answers the question the experiment asks, which is whether the run was
# leader-bound at all.
cmd_sample_cpu() {
    local idx=${1:-0} out=${2:?outfile} pid core
    core=${REPLICA_CPU_LIST[$(( idx % ${#REPLICA_CPU_LIST[@]} ))]}
    pid=$(cat "$run/replica$idx.pid" 2>/dev/null || echo "")
    : > "$out"
    while :; do
        cmd_leader_cpu "$idx" >> "$out"
        sleep 1
    done
}

# One client process saturates a core well before the cluster saturates: at
# seven replicas it sends seven unicasts per request and sat at 85% of a core
# while the leader was at 75%, so the measurement was of the client. Spreading
# the clients over several processes, one core each, puts the bottleneck back
# where the experiment wants it. The logs are concatenated, and parse.py reads
# one "Completed" line per client wherever it came from.
cmd_client() {
    local variant=$1 requests=$2 clients=$3 warmup=$4 procs=$5 log=$6 duration=${7:-0}
    local per=$(( clients / procs )) j pids=() dur_opt=()

    # Stop on a clock rather than a request count, so that every client of the
    # run measures the same window -- see run.sh.
    [ "$duration" -gt 0 ] && dur_opt=(-D "$duration")

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
                "${dur_opt[@]}" \
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
    leader-cpu)     shift; cmd_leader_cpu "$@" ;;
    sample-cpu)     shift; cmd_sample_cpu "$@" ;;
    client)         shift; cmd_client "$@" ;;
    stop)           cmd_stop ;;
    *) echo "usage: $0 {start-replicas <variant> <n>|start-tc <leader>|leader-cpu [idx]|client ...|stop}" >&2; exit 1 ;;
esac
