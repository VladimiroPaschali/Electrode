#!/usr/bin/env bash
# Narrow the DUT to a single core, and put it back.
#
#   sudo ./dut-cores.sh fanout <ifname> [cpu] [port]
#   sudo ./dut-cores.sh one <ifname> [cpu]
#   sudo ./dut-cores.sh restore <ifname> [queues]
#
# Two things together, because either alone leaves the work spread:
#
#   the RSS indirection   which queues a flow may land on
#   the queue's IRQ       pinned to one cpu, so that queue is served by one core
#
# What it is for: across sixteen queues the fan-out node runs at a few percent
# of a core, and nothing there can distinguish the copy path from the
# shared-page one -- there is no limit to reach. On one core there is.
#
# `fanout` is the one to use, and `one` is kept for the old topology. `one`
# puts *everything* this interface receives on a single core, which was right
# while the only thing arriving was the cluster's traffic to be routed. It is
# wrong now that the clients run here: their replies arrive on this interface
# too, and each is an XDP_PASS -- an skb, the UDP stack, a socket wakeup -- so
# a core shared with them saturates on the clients and reports it as the cost
# of duplicating.
#
# `fanout` steers the broadcast alone, by its destination port, to queue 0 and
# spreads everything else over the rest. The core serving queue 0 then does the
# duplication and nothing else, which is what makes its utilisation mean
# something.

set -euo pipefail

action=${1:-}
dev=${2:-}
arg=${3:-}
[ -n "$action" ] && [ -n "$dev" ] || {
    echo "usage: $0 {fanout|one|cores|restore} <ifname> [cpu|queues] [port]" >&2; exit 1; }

# The completion interrupt of the first channel. mlx5 numbers them from
# comp1, not comp0, and both ports of a card appear in /proc/interrupts, so
# the name alone is not enough -- the pci address of this device decides it.
irq_of_queue0() {
    local pci
    pci=$(basename "$(readlink -f "/sys/class/net/$dev/device")")

    for irq in $(ls "/sys/class/net/$dev/device/msi_irqs" 2>/dev/null | sort -n); do
        name=$(awk -v i="$irq:" '$1 == i {print $NF; exit}' /proc/interrupts)
        case "$name" in
            mlx5_comp*@pci:"$pci") echo "$irq"; return ;;
        esac
    done
}

# Every steering rule this script has left behind. Flushed before a new one, so
# that a second run does not stack a rule on top of the first and send the
# broadcast to a queue the previous one chose.
flush_rules() {
    local id
    for id in $(ethtool -n "$dev" 2>/dev/null | awk '/^Filter:/ {print $2}'); do
        ethtool -N "$dev" delete "$id" >/dev/null 2>&1 || true
    done
}

# Spread across N queues, one core each: the IRQ of queue i on cpu i. Not
# irqbalance's doing -- it moves them about, and a benchmark wants them still.
cores() {
    local n=$1 i=0 irq pci name
    pci=$(basename "$(readlink -f "/sys/class/net/$dev/device")")
    ethtool -X "$dev" equal "$n"
    systemctl is-active --quiet irqbalance && systemctl stop irqbalance

    for irq in $(ls "/sys/class/net/$dev/device/msi_irqs" | sort -n); do
        name=$(awk -v k="$irq:" '$1 == k {print $NF; exit}' /proc/interrupts)
        case "$name" in
            mlx5_comp*@pci:"$pci")
                [ "$i" -lt "$n" ] || break
                echo "$i" > "/proc/irq/$irq/smp_affinity_list"
                i=$(( i + 1 )) ;;
        esac
    done
    echo "$dev: $n queues, irqs pinned to cpus 0-$(( n - 1 ))"
}

case "$action" in
cores)
    cores "${arg:?how many}"
    ;;
fanout)
    cpu=${arg:-1}
    port=${4:-12000}
    ncpu=$(nproc)

    if systemctl is-active --quiet irqbalance; then
        systemctl stop irqbalance
        echo "irqbalance stopped"
    fi

    ethtool -K "$dev" ntuple on
    flush_rules
    ethtool -N "$dev" flow-type udp4 dst-port "$port" action 0 >/dev/null
    # Everything the rule does not match goes to queues 1..n-1, so queue 0
    # carries the broadcast and only the broadcast.
    ethtool -X "$dev" start 1 equal $(( ncpu - 1 ))

    # Queue 0 gets that core to itself. The other queues have to be moved off
    # it: the default assignment is comp_i on cpu i, so comp1 would sit on cpu 1
    # beside it, and a core shared with another queue is not a core doing only
    # duplication.
    pci=$(basename "$(readlink -f "/sys/class/net/$dev/device")")
    i=0
    next=0
    for irq in $(ls "/sys/class/net/$dev/device/msi_irqs" | sort -n); do
        name=$(awk -v k="$irq:" '$1 == k {print $NF; exit}' /proc/interrupts)
        case "$name" in
            mlx5_comp*@pci:"$pci") ;;
            *) continue ;;
        esac
        if [ "$i" -eq 0 ]; then
            echo "$cpu" > "/proc/irq/$irq/smp_affinity_list"
        else
            [ "$next" = "$cpu" ] && next=$(( next + 1 ))
            [ "$next" -lt "$ncpu" ] || break
            echo "$next" > "/proc/irq/$irq/smp_affinity_list"
            next=$(( next + 1 ))
        fi
        i=$(( i + 1 ))
    done
    [ "$i" -gt 0 ] || echo "warning: found no completion interrupts for $dev" >&2
    echo "$dev: udp/$port -> queue 0 on cpu $cpu alone; $(( i - 1 )) other queues elsewhere"
    ;;
one)
    cpu=${arg:-1}
    ethtool -X "$dev" equal 1
    if systemctl is-active --quiet irqbalance; then
        systemctl stop irqbalance
        echo "irqbalance stopped"
    fi
    irq=$(irq_of_queue0)
    if [ -n "$irq" ]; then
        echo "$cpu" > "/proc/irq/$irq/smp_affinity_list"
        echo "queue 0 irq $irq -> cpu $cpu"
    else
        echo "warning: could not find the irq of queue 0" >&2
    fi
    echo "$dev: one receive queue, one core"
    ;;
restore)
    queues=${arg:-16}
    flush_rules
    ethtool -K "$dev" ntuple off 2>/dev/null || true
    ethtool -X "$dev" equal "$queues"
    irq=$(irq_of_queue0)
    [ -n "$irq" ] && echo "0-$(( $(nproc) - 1 ))" > "/proc/irq/$irq/smp_affinity_list" || true
    systemctl start irqbalance 2>/dev/null || true
    echo "$dev: $queues queues, irq unpinned"
    ;;
*) echo "usage: $0 {fanout|one|cores|restore} <ifname> [cpu|queues] [port]" >&2; exit 1 ;;
esac
