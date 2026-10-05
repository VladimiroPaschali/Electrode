#!/usr/bin/env bash
# Build every variant of the benchmark, on grecale.
#
#   ./build.sh [replicas]
#
# Three C++ builds, because the broadcast is a compile-time choice in
# vr/replica.cc and lib/transportcommon.h -- one per point of the comparison:
#
#   baseline   SendMessageToAll() sends one packet per follower
#   tc         one packet, cloned on the leader's own TC egress hook
#   xdp        one packet to the fan-out node, cloned there
#
# The two XDP points share this last binary: what separates them is which
# object maestrale loads, not anything the replica does.
#
# The TC object has its cluster size compiled in (CLUSTER_SIZE in
# fast_common.h), so it is rebuilt here whenever that changes.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
n=${1:-3}
jobs=${JOBS:-8}

cd "$root"

build_one() {  # $1 = name, $2 = CXXFLAGS
    echo "=== $1 ${2:-(no flags)}"
    make clean >/dev/null 2>&1 || true
    make PARANOID=0 CXXFLAGS="$2" -j"$jobs" >/dev/null
    mkdir -p "build/$1"
    cp bench/replica bench/client "build/$1/"
}

build_one baseline ""
build_one tc "-DTC_BROADCAST"
build_one xdp "-DXDP_BROADCAST"
make clean >/dev/null 2>&1 || true

# Only FastBroadCast, the TC program the `tc` point attaches. The five XDP
# programs behind ELECTRODE_XDP_OFFLOADS belong to Electrode's other offloads,
# which nothing here measures, and none of them is ever loaded.
echo "=== eBPF, CLUSTER_SIZE=$n"
make -C xdp-handler clean >/dev/null
make -C xdp-handler EXTRA_CFLAGS="-DCLUSTER_SIZE=$n" >/dev/null

echo
echo "built:"
ls -1 build/*/replica
