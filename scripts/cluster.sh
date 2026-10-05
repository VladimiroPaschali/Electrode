#!/usr/bin/env bash
# The cluster side of the Electrode benchmark: one network namespace per
# replica plus one for the client, on grecale.
#
# Why namespaces. Electrode wants one machine per replica; there are two here,
# and one of them has to be the fan-out node. Put the replicas side by side in
# the root namespace instead and their packets never reach a wire -- the kernel
# delivers them locally -- so the baseline and the TC variant would be measured
# on loopback while the XDP ones crossed the link. Each replica gets a
# namespace with a macvlan of its own and a /32 route to every peer via the
# fan-out node, so *every* packet between two cluster members leaves the NIC,
# crosses the DUT and comes back, in all four variants alike. That is the only
# thing that makes the four numbers comparable.
#
#   sudo ./cluster.sh up 3      three replicas (and a client, see below)
#   sudo ./cluster.sh down      remove everything it made
#   ./cluster.sh show           what is there now
#
# With CLIENTS_ON_DUT=1, the default, the clients do not live here at all: they
# run on the fan-out node, which has the cores to spare. Grecale was the limit
# otherwise -- it could not offer enough load to bring the fan-out core near
# saturation, and a comparison of two duplication paths on a core with headroom
# compares nothing.
#
# Nothing here survives a reboot and nothing touches the root namespace's own
# addressing: `down` removes the namespaces, and the macvlans go with them.

set -euo pipefail

PARENT=${PARENT:-enp172s0f0np0}   # grecale's port on the link to maestrale
FANOUT=${FANOUT:-192.168.101.1}   # maestrale, the DUT
PORT=${PORT:-12345}
# The address a leader built with -DXDP_BROADCAST sends its one packet to. A
# port of its own, not the replica port: with the fan-out node also running a
# replica the two would otherwise collide on the same address.
FANOUT_PORT=${FANOUT_PORT:-12000}
# With this set, the last replica of the cluster runs on the fan-out node
# itself rather than in a namespace here -- the duplication point is then a
# cluster member and not a machine the comparison needs on top.
DUT_REPLICA=${DUT_REPLICA:-0}
# The clients run on the fan-out node rather than here. Nothing has to route
# for them then: they send from the fan-out node's own address, and the replies
# come back to it and go up its stack -- the program already passes anything
# addressed to the local address that is not the fan-out port.
CLIENTS_ON_DUT=${CLIENTS_ON_DUT:-1}
PREFIX=${PREFIX:-192.168.101}
DEV=mv
REPLICA_BASE=${REPLICA_BASE:-10}  # replica i is $PREFIX.$((REPLICA_BASE+i))
CLIENT_HOST=${CLIENT_HOST:-200}
NS=elec

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")

HOSTS_BEGIN="# BEGIN XDP_CLONE cluster (scripts/cluster.sh)"
HOSTS_END="# END XDP_CLONE cluster"

ip_of()  { echo "$PREFIX.$1"; }
mac_of() { printf '02:00:00:00:00:%02x\n' "$1"; }

ns_of() {  # $1 = host octet
    if [ "$1" = "$CLIENT_HOST" ]; then echo "$NS-cl"; else echo "$NS-r$(( $1 - REPLICA_BASE ))"; fi
}

make_ns() {  # $1 = host octet
    local host=$1 ns dev
    ns=$(ns_of "$host"); dev=$DEV

    ip netns add "$ns"
    ip link add link "$PARENT" name "$ns-tmp" type macvlan mode bridge
    ip link set "$ns-tmp" address "$(mac_of "$host")"
    ip link set "$ns-tmp" netns "$ns" name "$dev"
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip link set "$dev" up
    ip netns exec "$ns" ip addr add "$(ip_of "$host")/24" dev "$dev"
}

route_ns() {  # $1 = host octet, rest = the other host octets
    local host=$1 ns dev peer
    shift
    ns=$(ns_of "$host"); dev=$DEV

    # Every peer is reached through the fan-out node, never on-link. Without
    # this the macvlans would resolve each other by ARP and talk inside the
    # kernel; the point of the whole setup is that they do not.
    for peer in "$@"; do
        [ "$peer" = "$host" ] && continue
        ip netns exec "$ns" ip route add "$(ip_of "$peer")/32" via "$FANOUT" dev "$dev"
    done
}

cmd_up() {
    local n=${1:?usage: cluster.sh up <replicas>} hosts=() i host local_n
    [ "$n" -ge 1 ] || { echo "need at least one replica" >&2; exit 1; }

    cmd_down >/dev/null

    # One fewer namespace when the fan-out node takes the last replica.
    local_n=$(( DUT_REPLICA ? n - 1 : n ))
    for (( i = 0; i < local_n; i++ )); do hosts+=( $(( REPLICA_BASE + i )) ); done
    [ "$CLIENTS_ON_DUT" = 1 ] || hosts+=( "$CLIENT_HOST" )

    for host in "${hosts[@]}"; do make_ns "$host"; done
    for host in "${hosts[@]}"; do route_ns "$host" "${hosts[@]}"; done

    # config.txt in Electrode's own format, and the MAC list beside it, so that
    # the replicas, the TC program and the fan-out node all agree on who is who.
    # The gateway MAC, resolved before the config is written: with the fan-out
    # node taking a replica, that replica's MAC is the gateway's.
    ip netns exec "$NS-r0" ping -c 1 -W 2 "$FANOUT" >/dev/null 2>&1 || true
    ip netns exec "$NS-r0" ip neigh show "$FANOUT" | awk '{print $5; exit}' \
        > "$root/config.gwmac"
    if ! grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' "$root/config.gwmac"; then
        echo "could not resolve the MAC of $FANOUT -- is the fan-out node up?" >&2
        exit 1
    fi

    {
        echo "f $(( (n - 1) / 2 ))"
        for (( i = 0; i < local_n; i++ )); do
            echo "replica $(ip_of $(( REPLICA_BASE + i ))):$PORT"
        done
        [ "$DUT_REPLICA" = 1 ] && echo "replica $FANOUT:$PORT"
        # Where a leader built with -DXDP_BROADCAST sends its one packet. The
        # directive is parsed by every build; only that one acts on it.
        echo "fanout $FANOUT:$FANOUT_PORT"
    } > "$root/config.txt"

    : > "$root/config.macs"
    for (( i = 0; i < local_n; i++ )); do mac_of $(( REPLICA_BASE + i )) >> "$root/config.macs"; done
    [ "$DUT_REPLICA" = 1 ] && cat "$root/config.gwmac" >> "$root/config.macs"

    # The client is not a replica, but the fan-out node routes for it too --
    # unless it runs there, in which case there is nothing to route and the
    # file is empty.
    : > "$root/config.extra"
    [ "$CLIENTS_ON_DUT" = 1 ] || \
        echo "$(ip_of "$CLIENT_HOST")=$(mac_of "$CLIENT_HOST")" > "$root/config.extra"


    hosts_write "${hosts[@]}"

    echo "up: $n replicas$([ "$DUT_REPLICA" = 1 ] && echo " (the last on the fan-out node)")" \
         "$([ "$CLIENTS_ON_DUT" = 1 ] && echo "; clients on the fan-out node" || echo "+ client")"
    cmd_show
}

# One /etc/hosts line per namespace, rewritten on every `up` and taken out on
# `down`. Open MPI resolves each rank by name -- the launch agent enters the
# namespace whose name it is given -- so a cluster bigger than the names on
# file simply cannot be launched. Generated rather than hand-kept for that
# reason: it has to follow the size.
hosts_write() {  # $@ = host octets
    local host
    hosts_remove
    {
        echo "$HOSTS_BEGIN"
        for host in "$@"; do printf '%s %s\n' "$(ip_of "$host")" "$(ns_of "$host")"; done
        echo "$HOSTS_END"
    } >> /etc/hosts
}

hosts_remove() {
    sed -i "/^${HOSTS_BEGIN//\//\\/}$/,/^${HOSTS_END//\//\\/}$/d" /etc/hosts
}

cmd_down() {
    local ns i
    for ns in $(ip netns list | awk '{print $1}' | grep "^$NS-" || true); do
        # Delete the macvlan first: `ip netns del` only drops the namespace's
        # last reference, and the device -- with its unicast filter on the
        # parent -- can outlive the call by a moment. Reusing its MAC before
        # then fails with EADDRINUSE.
        ip netns exec "$ns" ip link del "$DEV" 2>/dev/null || true
        ip netns del "$ns" 2>/dev/null || true
    done
    # Anything left in the root namespace from a run that died halfway.
    for ns in $(ip -br link show type macvlan 2>/dev/null | awk '{print $1}' | \
                sed 's/@.*//' | grep "^$NS-" || true); do
        ip link del "$ns" 2>/dev/null || true
    done
    for i in $(seq 50); do
        [ -z "$(ip -br link show type macvlan 2>/dev/null | grep "@$PARENT" || true)" ] && break
        sleep 0.1
    done
    hosts_remove
    echo "down"
}

cmd_show() {
    local ns
    for ns in $(ip netns list | awk '{print $1}' | grep "^$NS-" | sort || true); do
        printf '%-10s %s\n' "$ns" \
            "$(ip netns exec "$ns" ip -br addr show mv | awk '{print $3}')"
    done
}

case "${1:-}" in
    up)   shift; cmd_up "$@" ;;
    down) cmd_down ;;
    show) cmd_show ;;
    *)    echo "usage: $0 {up <replicas>|down|show}" >&2; exit 1 ;;
esac
