#!/usr/bin/env bash
# The grecale half of verify.sh. A file rather than a heredoc: the nested
# escaping of a heredoc that both the local and the remote shell expand is its
# own source of bugs, and this script has to be trusted to say whether the
# measurement is trustworthy.
#
#   sudo ./verify-node.sh <variant> <cxx-build> <requests> <fanout-ip> <port>

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
cd "$root"

v=${1:?variant}
cxx=${2:?cxx build}
requests=${3:?requests}
fanout_ip=${4:?fanout ip}
port=${5:?port}

for ns in elec-r0 elec-r1 elec-r2 elec-cl; do
    if ! ip netns list | awk '{print $1}' | grep -qx "$ns"; then
        echo "no namespace $ns -- run 'sudo scripts/cluster.sh up 3' first" >&2
        exit 1
    fi
done

if [ "$v" = tc ]; then
    ./scripts/node.sh start-tc 0 >/dev/null || exit 1
fi
./scripts/node.sh start-replicas "$cxx" 3 >/dev/null || exit 1
sleep 1

# A file per variant, removed first: a stale capture from the previous one
# reads as a perfectly plausible result, and did.
rm -f "/tmp/v-$v-r"*.pcap
pids=()
ip netns exec elec-r0 tcpdump -i mv -nn -Q out -w "/tmp/v-$v-r0.pcap" udp port "$port" >/dev/null 2>&1 &
pids+=($!)
for i in 1 2; do
    ip netns exec "elec-r$i" tcpdump -i mv -nn -Q in -w "/tmp/v-$v-r$i.pcap" \
        "udp port $port and src 192.168.101.10" >/dev/null 2>&1 &
    pids+=($!)
done
sleep 2   # let them open their sockets before any traffic

udp() { ip netns exec elec-r0 nstat -az UdpOutDatagrams | awk 'NR==2{print $2}'; }

before=$(udp)
ip netns exec elec-cl "./build/$cxx/client" -c config.txt -m vr -n "$requests" -t 4 -w 0 >/dev/null 2>&1
after=$(udp)

sleep 1
for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done
wait 2>/dev/null || true

count() { tcpdump -r "$1" ${2:+"$2"} 2>/dev/null | wc -l; }

printf '  leader datagrams from userspace : %s\n' "$(( after - before ))"
printf '  leader frames on the wire       : %s\n' "$(count "/tmp/v-$v-r0.pcap")"
printf '    to the fan-out node           : %s\n' "$(count "/tmp/v-$v-r0.pcap" "dst host $fanout_ip")"
printf '    to a follower                 : %s\n' \
    "$(count "/tmp/v-$v-r0.pcap" "dst host 192.168.101.11 or dst host 192.168.101.12")"
for i in 1 2; do
    printf '  follower %s frames from leader   : %s\n' "$i" "$(count "/tmp/v-$v-r$i.pcap")"
done

./scripts/node.sh stop >/dev/null
