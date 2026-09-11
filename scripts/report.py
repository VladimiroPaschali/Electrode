#!/usr/bin/env python3
"""Summarise a sweep, and write the tables the paper needs.

One row per (replicas, variant, clients), aggregated over the repetitions:
throughput as the median of the repetitions with its spread, latency likewise.
The median rather than the mean because a run that hit a hiccup should not move
the number, and the spread is what says whether the repetitions agree.
"""
import argparse
import csv
import os
import statistics as st
from collections import defaultdict

ORDER = ["baseline", "tc", "xdp", "xdp-inline"]
LABEL = {"baseline": "baseline", "tc": "Electrode (TC)",
         "xdp": "XDP\\_CLONE", "xdp-inline": "XDP\\_CLONE inline"}


def agg(vals):
    if not vals:
        return None, None
    return st.median(vals), (st.stdev(vals) if len(vals) > 1 else 0.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()

    outdir = a.outdir or os.path.dirname(os.path.abspath(a.csv))

    rows = defaultdict(list)
    dropped = 0
    for r in csv.DictReader(open(a.csv)):
        if r.get("ok") != "1":
            dropped += 1
            continue
        key = (int(r["replicas"]), r["variant"], int(r["threads"]))
        rows[key].append(r)

    if dropped:
        print(f"({dropped} rows dropped: ok=0)\n")

    summary = {}
    for key, rs in rows.items():
        tp, tp_sd = agg([float(r["throughput_kops"]) for r in rs])
        med, _ = agg([float(r["median_us"]) for r in rs])
        p99, _ = agg([float(r["p99_us"]) for r in rs])
        summary[key] = dict(n=len(rs), tp=tp, tp_sd=tp_sd, med=med, p99=p99)

    replicas = sorted({k[0] for k in summary})
    threads = sorted({k[2] for k in summary})

    for n in replicas:
        print(f"=== {n} replicas " + "=" * 52)
        print(f"{'clients':>8} | " + " | ".join(f"{LABEL[v].replace(chr(92),''):>22}"
                                               for v in ORDER if any((n, v, t) in summary for t in threads)))
        present = [v for v in ORDER if any((n, v, t) in summary for t in threads)]
        print(f"{'':>8} | " + " | ".join(f"{'kops  (sd)   p50 us':>22}" for _ in present))
        for t in threads:
            cells = []
            for v in present:
                s = summary.get((n, v, t))
                cells.append(f"{s['tp']:8.1f} ({s['tp_sd']:4.1f}) {s['med']:7.1f}"
                             if s else " " * 22)
            print(f"{t:>8} | " + " | ".join(cells))

        # Peak throughput, which is what the broadcast offload is supposed to move.
        print()
        base = None
        for v in present:
            pts = [summary[(n, v, t)] for t in threads if (n, v, t) in summary]
            peak = max(p["tp"] for p in pts)
            at = [t for t in threads if (n, v, t) in summary
                  and summary[(n, v, t)]["tp"] == peak][0]
            if v == "baseline":
                base = peak
            rel = f"  {peak / base:.2f}x baseline" if base else ""
            print(f"  peak {LABEL[v].replace(chr(92), ''):>20}: {peak:8.1f} kops "
                  f"at {at:>3} clients{rel}")
        print()

    # pgfplots: one file per (replicas, variant), x = clients, y = kops, with
    # the latency alongside so a throughput-latency curve needs no second file.
    for (n, v, t), s in sorted(summary.items()):
        path = os.path.join(outdir, f"pgf_n{n}_{v}.dat")
        new = not os.path.exists(path) or (n, v, min(threads)) == (n, v, t)
        with open(path, "w" if new else "a") as fh:
            if new:
                fh.write("clients kops kops_sd p50_us p99_us\n")
            fh.write(f"{t} {s['tp']:.3f} {s['tp_sd']:.3f} {s['med']:.3f} {s['p99']:.3f}\n")
    print(f"pgfplots tables in {outdir}/pgf_n<replicas>_<variant>.dat")


if __name__ == "__main__":
    main()
