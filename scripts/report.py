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

ORDER = ["baseline", "prune", "tc", "tc-prune", "xdp", "xdp-inline",
         "xdp-prune", "xdp-inline-prune"]
LABEL = {"baseline": "baseline", "prune": "quorum prune",
         "tc": "Electrode (TC)", "tc-prune": "Electrode both",
         "xdp": "XDP\\_CLONE", "xdp-inline": "XDP\\_CLONE inline",
         "xdp-prune": "XDP\\_CLONE + prune",
         "xdp-inline-prune": "inline + prune"}


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
    os.makedirs(outdir, exist_ok=True)

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

    def col(rs, name):
        vals = [float(r[name]) for r in rs if r.get(name) not in (None, "")]
        return agg(vals)[0] if vals else None

    summary = {}
    for key, rs in rows.items():
        tp, tp_sd = agg([float(r["throughput_kops"]) for r in rs])
        med, med_sd = agg([float(r["median_us"]) for r in rs])
        p90, _ = agg([float(r["p90_us"]) for r in rs])
        p95, _ = agg([float(r["p95_us"]) for r in rs])
        p99, _ = agg([float(r["p99_us"]) for r in rs])
        spread, _ = agg([float(r["elapsed_spread"]) for r in rs
                         if r.get("elapsed_spread")])
        summary[key] = dict(n=len(rs), tp=tp, tp_sd=tp_sd, med=med,
                            med_sd=med_sd, p90=p90, p95=p95, p99=p99,
                            spread=spread,
                            dut_busy=col(rs, "dut_busy_cores"),
                            dut_softirq=col(rs, "dut_softirq_cores"),
                            dut_loader=col(rs, "dut_loader_cpu_s"))

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

        # What the DUT spent getting there, in cores: the fan-out node's own
        # cost, which the throughput alone does not show.
        print()
        for v in present:
            sq = [summary[(n, v, t)]["dut_softirq"] for t in threads
                  if (n, v, t) in summary
                  and summary[(n, v, t)]["dut_softirq"] is not None]
            if sq:
                print(f"  DUT softirq {LABEL[v].replace(chr(92), ''):>20}: "
                      f"{max(sq):.2f} cores at its busiest")

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

    # Everything the .dat files hold, in one table: one row per (replicas,
    # variant, clients), so the whole experiment can be read or re-plotted
    # without opening twelve files.
    summary_csv = os.path.join(outdir, "summary.csv")
    cols = ["replicas", "variant", "clients", "reps", "kops", "kops_sd",
            "p50_us", "p50_sd", "p90_us", "p95_us", "p99_us", "elapsed_spread",
            "dut_busy_cores", "dut_softirq_cores", "dut_loader_cpu_s"]
    with open(summary_csv, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for (n, v, t), s_ in sorted(summary.items(),
                                    key=lambda kv: (kv[0][0],
                                                    ORDER.index(kv[0][1]),
                                                    kv[0][2])):
            w.writerow([n, v, t, s_["n"],
                        f"{s_['tp']:.3f}", f"{s_['tp_sd']:.3f}",
                        f"{s_['med']:.3f}", f"{s_['med_sd']:.3f}",
                        f"{s_['p90']:.3f}", f"{s_['p95']:.3f}",
                        f"{s_['p99']:.3f}",
                        f"{s_['spread']:.4f}" if s_["spread"] else "",
                        f"{s_['dut_busy']:.4f}" if s_["dut_busy"] is not None else "",
                        f"{s_['dut_softirq']:.4f}" if s_["dut_softirq"] is not None else "",
                        f"{s_['dut_loader']:.3f}" if s_["dut_loader"] is not None else ""])
    print(f"summary in {summary_csv}")

    # pgfplots: one file per (replicas, variant), x = clients, y = kops, with
    # the latency alongside so a throughput-latency curve needs no second file.
    # Gathered first and written once, so a rerun never appends to a stale file.
    files = defaultdict(list)
    for (n, v, t), s in sorted(summary.items()):
        files[(n, v)].append(
            f"{t} {s['tp']:.3f} {s['tp_sd']:.3f} {s['med']:.3f} {s['p99']:.3f}")
    for (n, v), lines in files.items():
        with open(os.path.join(outdir, f"pgf_n{n}_{v}.dat"), "w") as fh:
            fh.write("clients kops kops_sd p50_us p99_us\n")
            fh.write("\n".join(lines) + "\n")
    print(f"pgfplots tables in {outdir}/pgf_n<replicas>_<variant>.dat")


if __name__ == "__main__":
    main()
