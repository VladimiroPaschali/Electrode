#!/usr/bin/env bash
# Check that each variant duplicates the broadcast where it claims to, rather
# than quietly falling back to the baseline. Runs on maestrale.
#
#   ./verify.sh [variant ...]     default: all four
#
# What distinguishes them is not visible in the throughput, and three of the
# four would produce a full set of plausible numbers if their offload silently
# did nothing. Two counters settle it, both taken on the leader:
#
#   UdpOutDatagrams   datagrams the leader's *userspace* handed to the stack
#   frames on mv      what actually left its interface
#
#   baseline    equal, and every frame is addressed to a follower
#   tc          more frames than datagrams: bpf_clone_redirect() made the
#               difference, inside the egress path, below the IP counter
#   xdp*        equal, and the broadcast frames are addressed to the fan-out
#               node -- one packet for the whole batch. The copies appear at
#               the followers, which is where they are counted.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")

ETH=${ETH:-enp52s0f1np1}
GRECALE=${GRECALE:-grecale}
REMOTE=${REMOTE:-XDP_CLONE/electrode}
FANOUT_IP=${FANOUT_IP:-192.168.101.1}
PORT=${PORT:-12345}
REQUESTS=${REQUESTS:-3000}

variants=("$@")
[ ${#variants[@]} -eq 0 ] && variants=(baseline tc xdp xdp-inline)

fanout_pid=/tmp/electrode-verify.pid

cleanup() {
    ssh "$GRECALE" "sudo $REMOTE/scripts/node.sh stop" >/dev/null 2>&1 || true
    [ -r "$fanout_pid" ] && { sudo kill -9 "$(cat "$fanout_pid")" 2>/dev/null || true; sudo rm -f "$fanout_pid"; }
    local stale; stale=$(pgrep -x fanout || true)
    [ -n "$stale" ] && sudo kill -9 $stale 2>/dev/null || true
    sudo bpftool net detach xdp dev "$ETH" 2>/dev/null || true
}
trap cleanup EXIT

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
    for _ in $(seq 50); do grep -q '^ready' /tmp/electrode-verify.log && break; sleep 0.1; done
    awk '/^pid /{print $2}' /tmp/electrode-verify.log | sudo tee "$fanout_pid" >/dev/null

    echo "===== $v"
    ssh "$GRECALE" "sudo bash -s" <<REMOTE_SH
set -e
cd \$HOME/$REMOTE
[ "$v" = tc ] && ./scripts/node.sh start-tc 0 >/dev/null
./scripts/node.sh start-replicas $cxx 3 >/dev/null
sleep 1

ip netns exec elec-r0 nstat -n >/dev/null 2>&1 || true
ip netns exec elec-r0 timeout 20 tcpdump -i mv -nn -Q out -w /tmp/v-r0.pcap udp port $PORT >/dev/null 2>&1 &
for i in 1 2; do
    ip netns exec elec-r\$i timeout 20 tcpdump -i mv -nn -Q in -w /tmp/v-r\$i.pcap \
        "udp port $PORT and src 192.168.101.10" >/dev/null 2>&1 &
done
sleep 1

ip netns exec elec-cl ./build/$cxx/client -c config.txt -m vr -n $REQUESTS -t 4 -w 0 >/dev/null 2>&1
sleep 1
pkill -INT tcpdump 2>/dev/null || true
sleep 1

echo "  leader UdpOutDatagrams : \$(ip netns exec elec-r0 nstat -az UdpOutDatagrams | awk 'NR==2{print \$2}')"
echo "  leader frames out      : \$(tcpdump -r /tmp/v-r0.pcap 2>/dev/null | wc -l)"
echo "    of them to the fan-out node: \$(tcpdump -r /tmp/v-r0.pcap "dst host $FANOUT_IP" 2>/dev/null | wc -l)"
echo "    of them to a follower      : \$(tcpdump -r /tmp/v-r0.pcap "dst host 192.168.101.11 or dst host 192.168.101.12" 2>/dev/null | wc -l)"
for i in 1 2; do
    echo "  follower \$i frames from leader: \$(tcpdump -r /tmp/v-r\$i.pcap 2>/dev/null | wc -l)"
done
./scripts/node.sh stop >/dev/null
REMOTE_SH
    echo
done
