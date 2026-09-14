#!/usr/bin/env bash
# The whole experiment: four variants, several cluster sizes, several client
# counts, several repetitions. Runs on maestrale.
#
#   ./sweep.sh --replicas 3 5 --threads 1 2 4 8 16 --reps 3 --out results/e1.csv
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
threads=(1 2 4 8 16)
client_procs=4
requests=10000
warmup=3
reps=3
out="$root/results/sweep-$(date +%Y%m%d_%H%M%S).csv"

while [ $# -gt 0 ]; do
    case "$1" in
        --variants) shift; variants=(); while [ $# -gt 0 ] && [[ $1 != --* ]]; do variants+=("$1"); shift; done ;;
        --replicas) shift; replicas=(); while [ $# -gt 0 ] && [[ $1 != --* ]]; do replicas+=("$1"); shift; done ;;
        --threads)  shift; threads=();  while [ $# -gt 0 ] && [[ $1 != --* ]]; do threads+=("$1");  shift; done ;;
        --client-procs) client_procs=$2; shift 2 ;;
        --requests) requests=$2; shift 2 ;;
        --warmup)   warmup=$2; shift 2 ;;
        --reps)     reps=$2; shift 2 ;;
        --out)      out=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$out")"

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
    # FastBroadCast has its cluster size compiled in, so the TC object is the
    # one thing that has to be rebuilt when it changes.
    ssh "$GRECALE" "make -C $REMOTE/xdp-handler clean >/dev/null && \
                    make -C $REMOTE/xdp-handler EXTRA_CFLAGS=-DCLUSTER_SIZE=$n >/dev/null"
    ssh "$GRECALE" "sudo $REMOTE/scripts/cluster.sh up $n" >/dev/null

    for rep in $(seq 1 "$reps"); do
        for v in "${variants[@]}"; do
            for t in "${threads[@]}"; do
                i=$(( i + 1 ))
                printf '[%d/%d] n=%s %-10s t=%-3s rep=%s  ' "$i" "$total" "$n" "$v" "$t" "$rep"
                # One process while there are fewer clients than processes.
                procs=$(( t < client_procs ? t : client_procs ))
                "$here/run.sh" --variant "$v" --replicas "$n" --requests "$requests" \
                    --threads "$t" --client-procs "$procs" \
                    --warmup "$warmup" --rep "$rep" --out "$out" \
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
