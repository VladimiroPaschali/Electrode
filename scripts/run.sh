#!/usr/bin/env bash
# One measurement of one variant. Runs on maestrale -- the DUT and the fan-out
# node -- and drives grecale over ssh.
#
#   ./run.sh --variant xdp --replicas 3 --requests 10000 --threads 4
#
# The variants differ in exactly one thing, where the leader's broadcast is
# duplicated:
#
#   baseline          nowhere: the leader sends one packet per follower
#   tc                on the leader's own TC egress hook (Electrode's offload)
#   xdp               on this node, XDP_CLONE_TX, a page and a header per copy
#   xdp-inline        on this node, XDP_CLONE_TX with the descriptor stamped on
#                     the original, so every frame leaves from the one RX page
#                     and each copy's header reaches the NIC as the WQE inline
#                     header
#
# In all of them the packet crosses this node on its way to a follower, so the
# hop count is the same and what the numbers compare is the duplication.

set -euo pipefail

ETH=${ETH:-enp52s0f1np1}
GRECALE=${GRECALE:-grecale}
REMOTE=${REMOTE:-XDP_CLONE/electrode}
PORT=${PORT:-12345}
FANOUT_IP=${FANOUT_IP:-192.168.101.1}
FANOUT_PORT=${FANOUT_PORT:-12000}
REPLICA_PORT=${REPLICA_PORT:-12345}
LEADER_SAMPLES=${LEADER_SAMPLES:-/tmp/electrode-leader-samples}
# With this set the last replica of the cluster runs here, on the fan-out node,
# instead of in a namespace on the other machine: the duplication point is then
# a cluster member rather than a server the comparison needs on top of the
# baseline's. A broadcast becomes XDP_CLONE_PASS -- the original goes up this
# node's own stack -- which gives up the driver's shared page and keeps the WQE
# inline header.
DUT_REPLICA=${DUT_REPLICA:-0}
# The clients run here, on the fan-out node, rather than on grecale. Grecale
# was the ceiling otherwise: it could not offer enough load to bring the
# fan-out core near saturation, and while that core has headroom the copy path
# and the shared-page one cannot be told apart -- nothing is competing for what
# the second saves. With the clients here, grecale spends all of itself on
# replicas and this node has thirty-one cores that are not the fan-out's.
CLIENTS_ON_DUT=${CLIENTS_ON_DUT:-1}
# Away from the fan-out core (dut-cores.sh pins it to cpu 1) and away from the
# local replica's (DUT_REPLICA_CPU, 3).
DUT_CLIENT_CPUS=${DUT_CLIENT_CPUS:-8-31}
# All of grecale for the replicas when the clients are not there; otherwise the
# split the old topology used.
REPLICA_CPUS=${REPLICA_CPUS:-0-31}
CLIENT_CPUS=${CLIENT_CPUS:-28-31}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")

variant=xdp
replicas=3
requests=10000
threads=1
client_procs=1
warmup=2
# Seconds of measurement. With this set the client stops on a clock instead of
# after --requests, so every client of the run measures the same window --
# which is what the throughput metric, a sum of per-client rates, assumes. With
# a request count they stop as much as 10x apart at thirty-one replicas and the
# sum reads twice what the cluster sustained.
duration=0
rep=0
# Bytes of dead weight on the PREPARE -- the one message the fan-out node
# duplicates. The benchmark's own request is a dozen bytes, so at 0 the frame
# being copied is 152 bytes and the shared-page build saves a memcpy nothing in
# a throughput number can see. The replicas take it as ELECTRODE_PREPARE_PAD and
# refuse anything that would no longer fit in one frame.
payload=0
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
        --duration) duration=$2; shift 2 ;;
        --rep)      rep=$2; shift 2 ;;
        --payload)  payload=$2; shift 2 ;;
        --out)      out=$2; shift 2 ;;
        --keep-topology) keep_topology=1; shift ;;
        *) echo "unknown argument $1" >&2; exit 1 ;;
    esac
done

case "$variant" in
    baseline|tc) cxx=$variant; object=fanout.bpf.o ;;
    xdp)         cxx=xdp;      object=fanout.bpf.o ;;
    xdp-inline)  cxx=xdp;      object=fanout_inline.bpf.o ;;
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

# "8-31,3" -> "8 9 10 ... 31 3"
expand_cpus() {
    local spec=$1 out=() parts=() part lo hi c
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

local_client_log=/tmp/electrode-client-local.log
follower_samples=/tmp/electrode-follower.samples

# The middle half of a series of "proc_ticks core_busy core_total" samples,
# differenced and reduced to a median. The first and last quarter go because
# they hold the client processes starting, the warmup ramp and the tail where
# the early clients have finished -- over the whole window a leader that runs
# at 93% in steady state reads 78%, which is the difference between a run that
# was leader-bound and one that looks like it was not.
steady_median() {  # $1 = samples file -> "<proc pct> <core pct>"
    awk '
        { t[NR] = $1; b[NR] = $2; tot[NR] = $3 }
        function sort_n(a, len,   i, j, tmp) {
            for (i = 2; i <= len; i++) {
                tmp = a[i]
                for (j = i - 1; j >= 1 && a[j] > tmp; j--) a[j+1] = a[j]
                a[j+1] = tmp
            }
        }
        END {
            n = 0
            for (i = 2; i <= NR; i++) {
                dt = tot[i] - tot[i-1]
                if (dt <= 0) continue
                n++
                proc[n] = (t[i] - t[i-1]) / dt * 100
                core[n] = (b[i] - b[i-1]) / dt * 100
            }
            if (n < 4) exit
            lo = int(n / 4) + 1; hi = n - int(n / 4)
            m = 0
            for (i = lo; i <= hi; i++) { p[++m] = proc[i]; c[m] = core[i] }
            sort_n(p, m); sort_n(c, m)
            printf "%.1f %.1f\n", p[int((m + 1) / 2)], c[int((m + 1) / 2)]
        }' "$1"
}

# The follower this node runs, when DUT_REPLICA=1 -- and under the XDP variants
# that follower is also the node doing the duplication, which is the point of
# running one here: the duplication point is a cluster member rather than a
# server the comparison needs on top of the baseline's.
#
# Its two costs land on different cores and stay separate numbers: the replica
# process on DUT_REPLICA_CPU, the duplication in NAPI softirq on the fan-out
# core. `fanout_busy_pct` is the second; this is the first.
sample_local_replica() {
    local pid core
    pid=$(pgrep -x replica | head -1 || true)
    core=${DUT_REPLICA_CPU:-3}
    : > "$follower_samples"
    [ -n "$pid" ] || return 0
    while :; do
        {
            printf '%s ' "$( [ -r "/proc/$pid/stat" ] && awk '{print $14+$15}' "/proc/$pid/stat" || echo 0 )"
            awk -v c="cpu$core" '$1 == c { print $2+$3+$4+$7+$8+$9, $2+$3+$4+$5+$6+$7+$8+$9 }' /proc/stat
        } >> "$follower_samples"
        sleep 1
    done
}

# The clients, when they run here. The same shape as node.sh's client
# subcommand: one process per core so that no single client process saturates
# its own core before the cluster does, a deadline so a wedged run cannot hang
# a sweep, and the per-process logs concatenated -- parse.py reads one
# "Completed" line per client wherever it came from.
#
# They send from this node's own address, so the replies come back to it and
# the fan-out program passes them up: it already passes anything addressed to
# the local address that is not the fan-out port.
run_clients_local() {
    local per=$(( threads / client_procs )) j cpus pids=() dur_opt=()

    # -D makes the client stop on a clock; -n stays as the fallback for the
    # request-count mode, and the client ignores it when -D is given.
    [ "${duration:-0}" -gt 0 ] && dur_opt=(-D "$duration")

    if [ $(( per * client_procs )) -ne "$threads" ]; then
        echo "clients ($threads) must divide by processes ($client_procs)" >&2
        return 1
    fi
    read -ra cpus <<< "$(expand_cpus "$DUT_CLIENT_CPUS")"

    rm -f "$local_client_log" "$local_client_log".*
    for (( j = 0; j < client_procs; j++ )); do
        timeout "${CLIENT_TIMEOUT:-300}" \
            taskset -c "${cpus[$(( j % ${#cpus[@]} ))]}" \
                "$root/build/$cxx/client" \
                -c "$root/config.txt" -m vr -n "$requests" -t "$per" -w "$warmup" \
                "${dur_opt[@]}" \
            > "$local_client_log.$j" 2>&1 &
        pids+=($!)
    done
    for j in "${pids[@]}"; do wait "$j" || true; done
    cat "$local_client_log".* > "$local_client_log" 2>/dev/null || true
    rm -f "$local_client_log".*
}

# The replica this node runs, when it does. It is the last index, so never the
# leader: the leader has to send its broadcast *to* the duplication point.
start_local_replica() {
    [ "$DUT_REPLICA" = 1 ] || return 0
    sudo env ELECTRODE_PREPARE_PAD="$payload" setsid nohup taskset -c "${DUT_REPLICA_CPU:-3}" \
        "$root/build/$cxx/replica" -c "$root/config.txt" -m vr \
        -i "$(( replicas - 1 ))" > /tmp/electrode-local-replica.log 2>&1 < /dev/null &
    sleep 1
}

stop_local_replica() {
    local p
    p=$(pgrep -x replica || true)
    [ -n "$p" ] && sudo kill -9 $p 2>/dev/null || true
    return 0
}

# By pid, never by pattern: pkill -f matches any process whose command line
# contains the pattern, which includes the shell that invoked this script if
# the pattern happens to appear in its arguments -- and killing the caller is
# a memorable way to find that out.
fanout_pid=/tmp/electrode-fanout.pid

stop_local_clients() {
    local p
    p=$(pgrep -x client || true)
    [ -n "$p" ] && sudo kill -9 $p 2>/dev/null || true
    return 0
}

cleanup() {
    stop_local_replica
    stop_local_clients
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
    rsh "sudo DUT_REPLICA=$DUT_REPLICA CLIENTS_ON_DUT=$CLIENTS_ON_DUT \
            $REMOTE/scripts/cluster.sh up $replicas" >/dev/null
fi

# The topology's own generated files: the replica list, the MACs the fan-out
# node routes by, and the gateway MAC the TC offload has to write.
for f in config.txt config.macs config.extra config.gwmac; do
    scp -q "$GRECALE:$REMOTE/$f" "$root/$f"
done

# The fan-out node comes up first: it is the router for everything else, and
# without it the namespaces cannot reach each other at all.
# With DUT_REPLICA the last replica is this node's own: -L/-I tell the program
# to keep the original for it instead of transmitting it.
local_opts=()
if [ "$DUT_REPLICA" = 1 ]; then
    local_opts=(-L "$FANOUT_IP:$REPLICA_PORT" -I "$(( replicas - 1 ))")
fi

# One -e per host this node routes for. The file is empty when the clients run
# here, since there is then nothing to route for: the program passes what is
# addressed to this node up its own stack.
extra_opts=()
while read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && extra_opts+=(-e "$line")
done < "$root/config.extra"

sudo setsid nohup "$root/xdp-fanout/fanout" "$ETH" \
    -f "$FANOUT_IP:$FANOUT_PORT" -o "$root/xdp-fanout/$object" \
    -c "$root/config.txt" -m "$root/config.macs" \
    "${extra_opts[@]}" "${local_opts[@]}" \
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

start_local_replica
rsh "sudo env REPLICA_CPUS='$REPLICA_CPUS' CLIENT_CPUS='$CLIENT_CPUS' \
        PREPARE_PAD='$payload' \
        $REMOTE/scripts/node.sh start-replicas $cxx $(( DUT_REPLICA ? replicas - 1 : replicas ))" >/dev/null
sleep 1

# What the DUT costs, measured across the whole client run.
#
# With the clients here, the machine-wide figures below cover them too, so they
# no longer say what the fan-out costs; the per-core ones do, and the core they
# name is the one that duplicates.
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
# cpuN <busy> <softirq> <total>
percore_snapshot() {
    awk '/^cpu[0-9]/{print $1, $2+$3+$4+$7+$8+$9, $8, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat
}

# Which core does the duplication: the one serving receive queue 0, where
# `dut-cores.sh fanout` steers the broadcast and nothing else. Read off that
# queue's interrupt affinity, which is the only thing that identifies it.
#
# Not the busiest core on the machine -- with DUT_REPLICA=1 that is the local
# replica's, and it was reporting the replica for every variant. And not the
# core with the most completion interrupts either: with the clients on this
# node their replies far outnumber the broadcast, so the busiest *queue* is one
# of theirs. That heuristic picked cpu 8 over cpu 1 in eleven of the fifteen
# runs at seven replicas, which is what this replaced.
#
# mlx5 numbers the completion interrupts from comp0 on some builds and comp1 on
# others -- the out-of-tree clone driver does the latter -- so queue 0 is the
# first of them in numeric order, never a fixed name.
fanout_queue_cpu() {
    local pci irq name f
    pci=$(basename "$(readlink -f "/sys/class/net/$ETH/device")")
    for irq in $(ls "/sys/class/net/$ETH/device/msi_irqs" 2>/dev/null | sort -n); do
        name=$(awk -v k="$irq:" '$1 == k {print $NF; exit}' /proc/interrupts)
        case "$name" in
            mlx5_comp*@pci:"$pci") ;;
            *) continue ;;
        esac
        for f in effective_affinity_list smp_affinity_list; do
            if [ -r "/proc/irq/$irq/$f" ]; then
                # One cpu when it is pinned; the first of the set if it is not,
                # which is as much as an unpinned queue can be said to have.
                cut -d, -f1 < "/proc/irq/$irq/$f" | cut -d- -f1
                return
            fi
        done
        return
    done
}

# The completion interrupts per core, to say what share of them that core took.
irq_snapshot() {
    local pci
    pci=$(basename "$(readlink -f "/sys/class/net/$ETH/device")")
    awk -v pci="$pci" '
        NR == 1 { ncpu = NF; next }
        {
            name = $NF
            if (name !~ /^mlx5_comp[0-9]+@pci:/) next
            if (substr(name, index(name, "@pci:") + 5) != pci) next
            for (i = 1; i <= ncpu; i++) s[i] += $(i + 1)
        }
        END { for (i = 1; i <= ncpu; i++) printf "cpu%d %d\n", i - 1, s[i] }
    ' /proc/interrupts
}

proc_cpu() {
    [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" || echo 0
}

# The leader's core, on the other machine. This is the resource the comparison
# is about -- the offloads take sends off the leader -- so a run in which it is
# not near saturation has its bottleneck somewhere else, and the throughput
# then measures that somewhere else instead of the broadcast.
leader_snapshot() {
    rsh "sudo env REPLICA_CPUS='$REPLICA_CPUS' $REMOTE/scripts/node.sh leader-cpu 0" \
        2>/dev/null || echo "0 0 0 0"
}

fpid=$(cat "$fanout_pid" 2>/dev/null || echo 0)
read -r cpu_b0 cpu_sq0 cpu_t0 <<< "$(cpu_snapshot)"
percore_snapshot > /tmp/electrode-percore.0
irq_snapshot > /tmp/electrode-irq.0
proc0=$(proc_cpu "$fpid")
read -r ld_t0 ld_b0 ld_tot0 ld_core <<< "$(leader_snapshot)"
# And a sample a second through the run, because the window average is not the
# answer: it carries the client processes starting, the warmup and the tail in
# which the early clients have finished. The steady middle is what says whether
# the run was leader-bound.
rsh "sudo rm -f $LEADER_SAMPLES; sudo env REPLICA_CPUS='$REPLICA_CPUS' setsid nohup \
        $REMOTE/scripts/node.sh sample-cpu 0 $LEADER_SAMPLES >/dev/null 2>&1 < /dev/null &" \
    >/dev/null 2>&1 || true
follower_sampler=0
if [ "$DUT_REPLICA" = 1 ]; then
    sample_local_replica &
    follower_sampler=$!
fi

if [ "$CLIENTS_ON_DUT" = 1 ]; then
    run_clients_local || true
else
    rsh "sudo rm -f /tmp/electrode-run/client.log" >/dev/null 2>&1 || true
    rsh "sudo env REPLICA_CPUS='$REPLICA_CPUS' CLIENT_CPUS='$CLIENT_CPUS' \
            $REMOTE/scripts/node.sh client $cxx $requests $threads $warmup $client_procs /tmp/electrode-run/client.log $duration" || true
fi

read -r cpu_b1 cpu_sq1 cpu_t1 <<< "$(cpu_snapshot)"
percore_snapshot > /tmp/electrode-percore.1
irq_snapshot > /tmp/electrode-irq.1
proc1=$(proc_cpu "$fpid")
rsh "sudo pkill -f 'node.sh sample-cpu'" >/dev/null 2>&1 || true
if [ "$follower_sampler" != 0 ]; then
    kill "$follower_sampler" 2>/dev/null || true
    wait "$follower_sampler" 2>/dev/null || true
fi
read -r ld_t1 ld_b1 ld_tot1 _ <<< "$(leader_snapshot)"

ncpu=$(nproc)
hz=$(getconf CLK_TCK)
dut_busy=$(awk -v d=$((cpu_b1 - cpu_b0)) -v t=$((cpu_t1 - cpu_t0)) -v n="$ncpu" \
    'BEGIN { printf "%.4f", (t > 0 ? d / t * n : 0) }')
dut_softirq=$(awk -v d=$((cpu_sq1 - cpu_sq0)) -v t=$((cpu_t1 - cpu_t0)) -v n="$ncpu" \
    'BEGIN { printf "%.4f", (t > 0 ? d / t * n : 0) }')
dut_loader=$(awk -v d=$((proc1 - proc0)) -v hz="$hz" 'BEGIN { printf "%.3f", d / hz }')
# join pairs the two snapshots line by line: cpuN b0 sq0 t0 b1 sq1 t1.
percore=$(join /tmp/electrode-percore.0 /tmp/electrode-percore.1)

# The busiest core, whatever it is -- kept as a cross-check on the one below.
# When the two differ, something other than the fan-out is the DUT's limit.
dut_busiest=$(echo "$percore" | awk '
    { db = $5 - $2; dt = $7 - $4; if (dt > 0) { p = db / dt * 100; if (p > m) m = p } }
    END { printf "%.1f", m }')
dut_busiest_cpu=$(echo "$percore" | awk '
    { db = $5 - $2; dt = $7 - $4; if (dt > 0) { p = db / dt * 100; if (p > m) { m = p; c = $1 } } }
    END { print c }')

# The core serving queue 0, and what share of the interface's completion
# interrupts it took. Under `dut-cores.sh fanout` that share is *low* by
# design -- queue 0 carries the broadcast alone while the clients' replies go
# to the other thirty-one queues -- so it is a description of the split, not a
# warning. It is near 1.0 only under `dut-cores.sh one`, which gives that core
# everything.
fanout_cpu=""
fanout_irq_share=""
fanout_queue=$(fanout_queue_cpu)
if [ -n "$fanout_queue" ]; then
    fanout_cpu="cpu$fanout_queue"
    fanout_irq_share=$(join /tmp/electrode-irq.0 /tmp/electrode-irq.1 | awk -v c="$fanout_cpu" '
        { d = $3 - $2; tot += d; if ($1 == c) m = d }
        END { if (tot > 0) printf "%.4f\n", m / tot }')
fi

fanout_busy=""
fanout_softirq=""
if [ -n "$fanout_cpu" ]; then
    read -r fanout_busy fanout_softirq <<< "$(echo "$percore" | awk -v c="$fanout_cpu" '
        $1 == c { db = $5 - $2; dsq = $6 - $3; dt = $7 - $4
                  if (dt > 0) printf "%.1f %.1f\n", db / dt * 100, dsq / dt * 100 }')"
fi

# A core's total ticks are its wall time, so the shares need no clock: what the
# leader process itself used of its core, and what that core did altogether
# (the replica plus the softirq for its own traffic).
leader_cpu_pct=$(awk -v d=$(( ld_t1 - ld_t0 )) -v t=$(( ld_tot1 - ld_tot0 )) \
    'BEGIN { if (t > 0) printf "%.1f", d / t * 100 }')
leader_core_pct=$(awk -v d=$(( ld_b1 - ld_b0 )) -v t=$(( ld_tot1 - ld_tot0 )) \
    'BEGIN { if (t > 0) printf "%.1f", d / t * 100 }')

# The steady middle of the run: consecutive samples differenced, the first and
# last quarter dropped, and the median of what is left. The median rather than
# the peak so that a single sample straddling the ramp cannot stand in for the
# run.
leader_steady_pct=""
leader_steady_core_pct=""
if rsh "cat $LEADER_SAMPLES" > /tmp/electrode-leader.samples 2>/dev/null &&
   [ -s /tmp/electrode-leader.samples ]; then
    read -r leader_steady_pct leader_steady_core_pct \
        <<< "$(steady_median /tmp/electrode-leader.samples)"
fi

follower_steady_pct=""
follower_steady_core_pct=""
if [ -s "$follower_samples" ]; then
    read -r follower_steady_pct follower_steady_core_pct \
        <<< "$(steady_median "$follower_samples")"
fi

# Both copies go first. A run that fails leaves the previous one's log where
# it was, and parsing that reports the last measurement again under this run's
# labels -- which is how three different modes came out with the same latency
# to the second decimal, and the same packet count, before anyone noticed.
rm -f /tmp/electrode-client.log
if [ "$CLIENTS_ON_DUT" = 1 ]; then
    if [ -s "$local_client_log" ]; then
        mv "$local_client_log" /tmp/electrode-client.log
    fi
else
    rsh "cat /tmp/electrode-run/client.log" > /tmp/electrode-client.log 2>/dev/null || true
fi
# It has to exist even when the clients produced nothing -- a refused client
# count, a job that died at once -- so that the run is reported as ok=0 with a
# reason rather than ending in a traceback from parse.py.
: >> /tmp/electrode-client.log
if [ ! -s /tmp/electrode-client.log ]; then
    echo "the job produced no output; the run is not a measurement" >&2
fi

python3 "$here/parse.py" \
    --variant "$variant" --replicas "$replicas" --requests "$requests" \
    --threads "$threads" --client-procs "$client_procs" --warmup "$warmup" --rep "$rep" \
    --payload "$payload" \
    --dut-busy-cores "$dut_busy" --dut-softirq-cores "$dut_softirq" \
    --dut-loader-cpu-s "$dut_loader" \
    --dut-busiest-pct "$dut_busiest" --dut-busiest-cpu "${dut_busiest_cpu#cpu}" \
    ${fanout_cpu:+--fanout-cpu "${fanout_cpu#cpu}"} \
    ${fanout_busy:+--fanout-busy-pct "$fanout_busy"} \
    ${fanout_softirq:+--fanout-softirq-pct "$fanout_softirq"} \
    ${fanout_irq_share:+--fanout-irq-share "$fanout_irq_share"} \
    ${leader_cpu_pct:+--leader-cpu-pct "$leader_cpu_pct"} \
    ${leader_core_pct:+--leader-core-pct "$leader_core_pct"} \
    --leader-cpu "$ld_core" \
    ${leader_steady_pct:+--leader-steady-pct "$leader_steady_pct"} \
    ${leader_steady_core_pct:+--leader-steady-core-pct "$leader_steady_core_pct"} \
    ${follower_steady_pct:+--follower-steady-pct "$follower_steady_pct"} \
    ${follower_steady_core_pct:+--follower-steady-core-pct "$follower_steady_core_pct"} \
    $( [ "$DUT_REPLICA" = 1 ] && echo "--follower-cpu ${DUT_REPLICA_CPU:-3} --follower-is-fanout 1" ) \
    ${out:+--out "$out"} /tmp/electrode-client.log
