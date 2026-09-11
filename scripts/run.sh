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
        --warmup)   warmup=$2; shift 2 ;;
        --rep)      rep=$2; shift 2 ;;
        --out)      out=$2; shift 2 ;;
        --keep-topology) keep_topology=1; shift ;;
        *) echo "unknown argument $1" >&2; exit 1 ;;
    esac
done

case "$variant" in
    baseline|tc)  cxx=$variant;  object=fanout.bpf.o ;;
    xdp)          cxx=xdp;       object=fanout.bpf.o ;;
    xdp-inline)   cxx=xdp;       object=fanout_inline.bpf.o ;;
    *) echo "variant must be baseline, tc, xdp or xdp-inline" >&2; exit 1 ;;
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

rsh "sudo $REMOTE/scripts/node.sh start-replicas $cxx $replicas" >/dev/null
sleep 1

rsh "sudo $REMOTE/scripts/node.sh client $cxx $requests $threads $warmup /tmp/electrode-run/client.log" || true
rsh "cat /tmp/electrode-run/client.log" > /tmp/electrode-client.log

python3 "$here/parse.py" \
    --variant "$variant" --replicas "$replicas" --requests "$requests" \
    --threads "$threads" --warmup "$warmup" --rep "$rep" \
    ${out:+--out "$out"} /tmp/electrode-client.log
