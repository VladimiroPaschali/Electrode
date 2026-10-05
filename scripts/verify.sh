#!/usr/bin/env bash
# Check that each variant duplicates the broadcast where it claims to, rather
# than quietly falling back to the baseline. Runs on maestrale; the grecale half
# is scripts/verify-node.sh.
#
#   REPLICAS=31 ./verify.sh [variant ...]    default: all four, three replicas
#   sudo CLIENTS_ON_DUT=0 scripts/cluster.sh up <n>    on grecale first
#
# CLIENTS_ON_DUT=0 because this check drives the client from a namespace on
# grecale. Where the broadcast is duplicated does not depend on where the
# clients live, so the counts below mean the same thing in either topology.
#
# What distinguishes the four is not visible in the throughput, and three of
# them would produce a full set of plausible numbers if their offload silently
# did nothing. Two counters on the leader settle it:
#
#   datagrams from userspace   what the replica handed to the stack
#   frames on the wire         what actually left its interface
#
#   baseline    equal, every frame addressed to a follower
#   tc          more frames than datagrams: bpf_clone_redirect() made the
#               difference inside the egress path, below the IP counter
#   xdp*        equal, and the broadcast frames are addressed to the fan-out
#               node -- one packet for the whole batch. The copies show up at
#               the followers, which is where they are counted.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")

ETH=${ETH:-enp52s0f1np1}
GRECALE=${GRECALE:-grecale}
REMOTE=${REMOTE:-XDP_CLONE/electrode}
FANOUT_IP=${FANOUT_IP:-192.168.101.1}
PORT=${PORT:-12345}
REQUESTS=${REQUESTS:-3000}
REPLICAS=${REPLICAS:-3}

# Resolved as the login user: under sudo, $HOME is /root.
REMOTE_ROOT=$(ssh "$GRECALE" "echo \$HOME/$REMOTE")

variants=("$@")
[ ${#variants[@]} -eq 0 ] && variants=(baseline tc xdp xdp-inline)

fanout_pid=/tmp/electrode-verify.pid

cleanup() {
    ssh "$GRECALE" "sudo $REMOTE_ROOT/scripts/node.sh stop" >/dev/null 2>&1
    if [ -r "$fanout_pid" ]; then
        sudo kill -9 "$(cat "$fanout_pid")" 2>/dev/null
        sudo rm -f "$fanout_pid"
    fi
    # By name, never by a -f pattern: that would match the shell that called us.
    local stale
    stale=$(pgrep -x fanout)
    [ -n "$stale" ] && sudo kill -9 $stale 2>/dev/null
    sudo bpftool net detach xdp dev "$ETH" 2>/dev/null
    return 0
}
trap cleanup EXIT

rc=0
for v in "${variants[@]}"; do
    case "$v" in
        baseline|tc) cxx=$v;  object=fanout.bpf.o ;;
        xdp)         cxx=xdp; object=fanout.bpf.o ;;
        xdp-inline)  cxx=xdp; object=fanout_inline.bpf.o ;;
        *) echo "unknown variant $v" >&2; exit 1 ;;
    esac

    cleanup
    sudo setsid nohup "$root/xdp-fanout/fanout" "$ETH" \
        -f "$FANOUT_IP:$PORT" -o "$root/xdp-fanout/$object" \
        -c "$root/config.txt" -m "$root/config.macs" \
        -e "$(cat "$root/config.extra")" \
        > /tmp/electrode-verify.log 2>&1 < /dev/null &
    for _ in $(seq 50); do
        grep -q '^ready' /tmp/electrode-verify.log && break
        sleep 0.1
    done
    if ! grep -q '^ready' /tmp/electrode-verify.log; then
        echo "the fan-out node did not come up:" >&2
        cat /tmp/electrode-verify.log >&2
        exit 1
    fi
    awk '/^pid /{print $2}' /tmp/electrode-verify.log | sudo tee "$fanout_pid" >/dev/null

    echo "===== $v"
    ssh "$GRECALE" \
        "sudo $REMOTE_ROOT/scripts/verify-node.sh $v $cxx $REQUESTS $FANOUT_IP $PORT $REPLICAS" \
        || { echo "  (failed)" >&2; rc=1; }
    echo
done
exit $rc
