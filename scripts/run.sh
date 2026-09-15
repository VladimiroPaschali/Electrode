#!/usr/bin/env bash
# One measurement of one variant. Runs on maestrale -- the DUT and the fan-out
# node -- and drives grecale over ssh.
#
#   ./run.sh --variant xdp --replicas 3 --requests 10000 --threads 4
#
# The four variants differ in exactly one thing, where the leader's broadcast is
# duplicated:
#
#   baseline     nowhere: the leader sends one packet per follower
#   tc           on the leader's own TC egress hook (Electrode's offload)
#   prune        nowhere, but Electrode's *other* offload is on: the leader's
#                PrepareOKs are pruned in XDP before they reach userspace
#   tc-prune     Electrode with both of its offloads, which is what its paper
#                runs and the fair counterpart of xdp-prune
#   xdp-prune    both, which is the question -- the broadcast takes the sends
#                off the leader and the receives are what is left
#   xdp          on this node, XDP_CLONE_TX, a page and a header per copy
#   xdp-inline   on this node, XDP_CLONE_TX with the descriptor stamped on the
#                original, so every frame leaves from the one RX page and each
#                copy's header reaches the NIC as the WQE inline header
#
# In all four the packet crosses this node on its way to a follower, so the hop
# count is the same and what the numbers compare is the duplication.

set -euo pipefail

ETH=${ETH:-enp52s0f1np1}
GRECALE=${GRECALE:-grecale}
REMOTE=${REMOTE:-XDP_CLONE/electrode}
PORT=${PORT:-12345}
FANOUT_IP=${FANOUT_IP:-192.168.101.1}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")

variant=xdp
replicas=3
requests=10000
threads=1
client_procs=1
warmup=2
rep=0
out=""
keep_topology=0

while [ $# -gt 0 ]; do
    case "$1" in
        --variant)  variant=$2; shift 2 ;;
        --replicas) replicas=$2; shift 2 ;;
        --requests) requests=$2; shift 2 ;;
        --threads)  threads=$2; shift 2 ;;
        --client-procs) client_procs=$2; shift 2 ;;
        --warmup)   warmup=$2; shift 2 ;;
        --rep)      rep=$2; shift 2 ;;
        --out)      out=$2; shift 2 ;;
        --keep-topology) keep_topology=1; shift ;;
        *) echo "unknown argument $1" >&2; exit 1 ;;
    esac
done

case "$variant" in
    baseline|tc)      cxx=$variant;   object=fanout.bpf.o ;;
    xdp)              cxx=xdp;        object=fanout.bpf.o ;;
    xdp-inline)       cxx=xdp;        object=fanout_inline.bpf.o ;;
    prune)            cxx=prune;      object=fanout.bpf.o ;;
    tc-prune)         cxx=tc-prune;   object=fanout.bpf.o ;;
    xdp-prune)        cxx=xdp-prune;  object=fanout.bpf.o ;;
    xdp-inline-prune) cxx=xdp-prune;  object=fanout_inline.bpf.o ;;
    *) echo "variant must be baseline, tc, xdp, xdp-inline, prune," \
            "tc-prune, xdp-prune or xdp-inline-prune" >&2; exit 1 ;;
esac

rsh() { ssh "$GRECALE" "$@"; }

preflight() {
    # The clone actions only exist on the legacy-RQ path, and the TX descriptor
    # is only read on the regular-WQE path. Either flag left on produces a
    # complete set of plausible numbers that measure something else.
    local flags
    flags=$(sudo ethtool --show-priv-flags "$ETH")
    for f in rx_striding_rq xdp_tx_mpwqe; do
        if ! echo "$flags" | grep -qE "^$f *: off"; then
            echo "$ETH has $f on; the fan-out needs it off:" >&2
            echo "  sudo ethtool --set-priv-flags $ETH $f off" >&2
            exit 1
        fi
    done
    [ -r /sys/module/mlx5_core/srcversion ] || {
        echo "mlx5_core is not loaded" >&2; exit 1; }
}

# By pid, never by pattern: pkill -f matches any process whose command line
# contains the pattern, which includes the shell that invoked this script if
# the pattern happens to appear in its arguments -- and killing the caller is
# a memorable way to find that out.
fanout_pid=/tmp/electrode-fanout.pid

cleanup() {
    rsh "sudo $REMOTE/scripts/node.sh stop" >/dev/null 2>&1 || true
    if [ -r "$fanout_pid" ]; then
        sudo kill -TERM "$(cat "$fanout_pid")" 2>/dev/null || true
        sleep 0.3
        sudo kill -9 "$(cat "$fanout_pid")" 2>/dev/null || true
        sudo rm -f "$fanout_pid"
    fi
    # And anything an earlier run left behind. -x matches the process name
    # only, so unlike a -f pattern it cannot match the shell that called this.
    local stale
    stale=$(pgrep -x fanout || true)
    [ -n "$stale" ] && sudo kill -9 $stale 2>/dev/null || true

    # Whatever is still attached, so that the next run is not measured through
    # someone else's program.
    sudo bpftool net detach xdp dev "$ETH" 2>/dev/null || true
}
trap cleanup EXIT

preflight
cleanup

if [ "$keep_topology" = 0 ]; then
    rsh "sudo $REMOTE/scripts/cluster.sh up $replicas" >/dev/null
fi

# The topology's own generated files: the replica list, the MACs the fan-out
# node routes by, and the gateway MAC the TC offload has to write.
for f in config.txt config.macs config.extra config.gwmac; do
    scp -q "$GRECALE:$REMOTE/$f" "$root/$f"
done

# The fan-out node comes up first: it is the router for everything else, and
# without it the namespaces cannot reach each other at all.
sudo setsid nohup "$root/xdp-fanout/fanout" "$ETH" \
    -f "$FANOUT_IP:$PORT" -o "$root/xdp-fanout/$object" \
    -c "$root/config.txt" -m "$root/config.macs" \
    -e "$(cat "$root/config.extra")" \
    > /tmp/electrode-fanout.log 2>&1 < /dev/null &
for _ in $(seq 50); do
    grep -q '^ready' /tmp/electrode-fanout.log && break
    sleep 0.1
done
grep -q '^ready' /tmp/electrode-fanout.log || {
    echo "the fan-out node did not come up:" >&2; cat /tmp/electrode-fanout.log >&2; exit 1; }
awk '/^pid /{print $2}' /tmp/electrode-fanout.log | sudo tee "$fanout_pid" >/dev/null

if [ "$variant" = tc ]; then
    rsh "sudo $REMOTE/scripts/node.sh start-tc 0" >/dev/null
fi

# Before the replicas: they open the pinned map at startup and give up if it
# is not there.
case "$variant" in
    prune|tc-prune|xdp-prune|xdp-inline-prune)
        rsh "sudo $REMOTE/scripts/node.sh xdp-start $replicas" >/dev/null ;;
esac

rsh "sudo $REMOTE/scripts/node.sh start-replicas $cxx $replicas" >/dev/null
sleep 1

# What the DUT costs, measured across the whole client run.
#
# The loader process is not the thing to watch: it sits in pause() and burns
# nothing, because the work is the XDP program, which runs in NAPI softirq on
# whichever core takes the interrupt. So the number that means something is
# softirq time, in cores rather than percent -- "this node spent 0.4 of a core
# forwarding" reads the same whatever the machine has. The loader's own CPU is
# recorded beside it precisely to show that it is nil.
cpu_snapshot() {
    awk '/^cpu /{busy=$2+$3+$4+$7+$8+$9; printf "%d %d %d\n", busy, $8, busy+$5+$6}' /proc/stat
}

# Per-core, because the total hides the thing that matters when the RSS
# indirection is narrow: sixteen cores at 4% and one core at 64% are the same
# 0.64 cores, and only one of them is close to a limit.
percore_snapshot() { awk '/^cpu[0-9]/{print $1, $2+$3+$4+$7+$8+$9, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat; }
proc_cpu() {
    [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" || echo 0
}

fpid=$(cat "$fanout_pid" 2>/dev/null || echo 0)
read -r cpu_b0 cpu_sq0 cpu_t0 <<< "$(cpu_snapshot)"
percore_snapshot > /tmp/electrode-percore.0
proc0=$(proc_cpu "$fpid")

rsh "sudo rm -f /tmp/electrode-run/client.log" >/dev/null 2>&1 || true
rsh "sudo $REMOTE/scripts/node.sh client $cxx $requests $threads $warmup $client_procs /tmp/electrode-run/client.log" || true

read -r cpu_b1 cpu_sq1 cpu_t1 <<< "$(cpu_snapshot)"
percore_snapshot > /tmp/electrode-percore.1
proc1=$(proc_cpu "$fpid")

ncpu=$(nproc)
hz=$(getconf CLK_TCK)
dut_busy=$(awk -v d=$((cpu_b1 - cpu_b0)) -v t=$((cpu_t1 - cpu_t0)) -v n="$ncpu" \
    'BEGIN { printf "%.4f", (t > 0 ? d / t * n : 0) }')
dut_softirq=$(awk -v d=$((cpu_sq1 - cpu_sq0)) -v t=$((cpu_t1 - cpu_t0)) -v n="$ncpu" \
    'BEGIN { printf "%.4f", (t > 0 ? d / t * n : 0) }')
dut_loader=$(awk -v d=$((proc1 - proc0)) -v hz="$hz" 'BEGIN { printf "%.3f", d / hz }')
dut_busiest=$(join /tmp/electrode-percore.0 /tmp/electrode-percore.1 | awk '
    { db = $4 - $2; dt = $5 - $3; if (dt > 0) { p = db / dt * 100; if (p > m) { m = p; c = $1 } } }
    END { printf "%.1f", m }')
dut_busiest_cpu=$(join /tmp/electrode-percore.0 /tmp/electrode-percore.1 | awk '
    { db = $4 - $2; dt = $5 - $3; if (dt > 0) { p = db / dt * 100; if (p > m) { m = p; c = $1 } } }
    END { print c }')

# Both copies go first. A run that fails leaves the previous one's log where
# it was, and parsing that reports the last measurement again under this run's
# labels -- which is how three different modes came out with the same latency
# to the second decimal, and the same packet count, before anyone noticed.
rm -f /tmp/electrode-client.log
rsh "cat /tmp/electrode-run/client.log" > /tmp/electrode-client.log 2>/dev/null || true
if [ ! -s /tmp/electrode-client.log ]; then
    echo "the job produced no output; the run is not a measurement" >&2
fi

python3 "$here/parse.py" \
    --variant "$variant" --replicas "$replicas" --requests "$requests" \
    --threads "$threads" --client-procs "$client_procs" --warmup "$warmup" --rep "$rep" \
    --dut-busy-cores "$dut_busy" --dut-softirq-cores "$dut_softirq" \
    --dut-loader-cpu-s "$dut_loader" \
    --dut-busiest-pct "$dut_busiest" --dut-busiest-cpu "${dut_busiest_cpu#cpu}" \
    ${out:+--out "$out"} /tmp/electrode-client.log
