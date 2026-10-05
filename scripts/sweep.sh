#!/usr/bin/env bash
# The whole experiment: four variants, several cluster sizes, several client
# counts, several repetitions. Runs on maestrale.
#
#   ./sweep.sh --replicas 3 5 --threads 1 2 4 8 16 --reps 3 --out results/e1.csv
#
# The clients run on this machine by default (CLIENTS_ON_DUT), so grecale
# spends all of itself on replicas and --client-procs can be as wide as the
# cores this node has spare -- DUT_CLIENT_CPUS is twenty-four of them, hence a
# default of 24. At every client count in the sweep that leaves one or two
# clients per process, so the thing that saturates is the leader or the fan-out
# core, never a client process. That was the failure the per-process split was
# introduced for in the first place.
#
# Note that raising it does not raise the offered load: it spreads the same
# clients over more cores. What raises the load is more clients.
#
# Which is why the sweep runs to 64 and not 32. At three replicas the leader's
# core sits at 93% with 32 clients and reaches 100% with 64, where the
# throughput peaks; at 128 the throughput is unchanged and the latency doubles,
# which is queueing and not measurement. A run whose leader is not saturated
# has its bottleneck somewhere else and says nothing about the offload, so
# `leader_steady_pct` belongs beside every number in the table.
#
# Both machines are pinned to `performance` and have interrupt coalescing
# turned off for the duration, and put back afterwards -- a Paxos round trip is
# tens of microseconds and the mlx5 default adapts rx-usecs to the load, so
# without that the numbers describe the coalescing.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")

ETH=${ETH:-enp52s0f1np1}
GRECALE=${GRECALE:-grecale}
GRECALE_ETH=${GRECALE_ETH:-enp172s0f0np0}
REMOTE=${REMOTE:-XDP_CLONE/electrode}

variants=(baseline tc xdp xdp-inline)
replicas=(3)
threads=(2 4 8 16 32 64 128)
client_procs=24
requests=10000
warmup=3
# Seconds of measurement per run. The client then stops on a clock and every
# client of a run measures the same window, which is what makes the sum of the
# per-client rates a throughput rather than an artefact of who finished first.
duration=10
reps=3
# Dead weight on the PREPARE, the one message the fan-out node duplicates. The
# benchmark's request is a dozen bytes, so at the default the frame being copied
# is 152 bytes: the shared page and the memcpy it saves are then too small to
# separate `xdp` from `xdp-inline` whatever the load. Raising it is how that
# difference is given something to be. The replicas refuse a padding that no
# longer fits in one frame, which is the only ceiling there is.
payload=0
out="$root/results/sweep-$(date +%Y%m%d_%H%M%S).csv"

while [ $# -gt 0 ]; do
    case "$1" in
        --variants) shift; variants=(); while [ $# -gt 0 ] && [[ $1 != --* ]]; do variants+=("$1"); shift; done ;;
        --replicas) shift; replicas=(); while [ $# -gt 0 ] && [[ $1 != --* ]]; do replicas+=("$1"); shift; done ;;
        --threads)  shift; threads=();  while [ $# -gt 0 ] && [[ $1 != --* ]]; do threads+=("$1");  shift; done ;;
        --client-procs) client_procs=$2; shift 2 ;;
        --requests) requests=$2; shift 2 ;;
        --warmup)   warmup=$2; shift 2 ;;
        --duration) duration=$2; shift 2 ;;
        --reps)     reps=$2; shift 2 ;;
        --payload)  payload=$2; shift 2 ;;
        --out)      out=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$out")"

# How many processes to spread this many clients over. It has to divide them:
# each process runs clients/procs of them, and a remainder is refused rather
# than quietly measured as a different client count. So: the largest divisor of
# the client count that is no bigger than --client-procs. At 6 clients and
# --client-procs 4 that is 3, not 4, which is what the old min() got wrong.
procs_for() {
    local t=$1 d
    for (( d = (client_procs < t ? client_procs : t); d >= 1; d-- )); do
        if [ $(( t % d )) -eq 0 ]; then echo "$d"; return; fi
    done
    echo 1
}

untune() {
    sudo "$here/tune.sh" off "$ETH" >/dev/null 2>&1 || true
    ssh "$GRECALE" "sudo $REMOTE/scripts/tune.sh off $GRECALE_ETH" >/dev/null 2>&1 || true
}
trap untune EXIT

sudo "$here/tune.sh" on "$ETH"
ssh "$GRECALE" "sudo $REMOTE/scripts/tune.sh on $GRECALE_ETH"

total=$(( ${#replicas[@]} * ${#variants[@]} * ${#threads[@]} * reps ))
i=0

for n in "${replicas[@]}"; do
    # The eBPF object has its cluster size compiled in, so it is the one thing
    # that has to be rebuilt when that changes. The flags have to match
    # scripts/build.sh.
    ssh "$GRECALE" "make -C $REMOTE/xdp-handler clean >/dev/null && \
                    make -C $REMOTE/xdp-handler EXTRA_CFLAGS='-DCLUSTER_SIZE=$n' \
                        >/dev/null"
    ssh "$GRECALE" "sudo DUT_REPLICA=${DUT_REPLICA:-0} CLIENTS_ON_DUT=${CLIENTS_ON_DUT:-1} \
                        $REMOTE/scripts/cluster.sh up $n" >/dev/null

    for rep in $(seq 1 "$reps"); do
        for v in "${variants[@]}"; do
            for t in "${threads[@]}"; do
                i=$(( i + 1 ))
                printf '[%d/%d] n=%s %-10s t=%-3s pad=%-4s rep=%s  ' \
                    "$i" "$total" "$n" "$v" "$t" "$payload" "$rep"
                procs=$(procs_for "$t")
                "$here/run.sh" --variant "$v" --replicas "$n" --requests "$requests" \
                    --threads "$t" --client-procs "$procs" \
                    --warmup "$warmup" --duration "$duration" --rep "$rep" \
                    --payload "$payload" --out "$out" \
                    --keep-topology || echo "  (run failed)"
            done
        done
    done
done

echo
echo "results in $out"

# The summary is part of the run, not a step to remember afterwards: a sweep
# that ends without one invites reading the raw rows, which is where the
# repetitions get mistaken for measurements.
if ! python3 "$here/report.py" "$out"; then
    echo "the sweep finished but the summary failed; the rows are in $out" >&2
fi
