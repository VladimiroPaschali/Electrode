#!/usr/bin/env python3
"""Summarise a sweep.

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
LABEL = {"baseline": "baseline",
         "tc": "Electrode (TC)",
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
    os.makedirs(outdir, exist_ok=True)

    rows = defaultdict(list)
    dropped = 0
    unmeasured = defaultdict(int)
    for r in csv.DictReader(open(a.csv)):
        # ok=0, or a row with no latency at all: the clients ran and the
        # cluster served none of them, which parse.py called ok=1 before it
        # knew to look. Either way there is nothing in it to summarise.
        if r.get("ok") != "1" or not r.get("median_us"):
            dropped += 1
            continue
        # A sweep from before the comparison was cut down to four points can
        # still be summarised; the variants it no longer covers are named
        # rather than silently folded in.
        if r["variant"] not in ORDER:
            unmeasured[r["variant"]] += 1
            continue
        # The padding is part of the key, not a column to average over: the
        # duplicated packet's size is what the whole comparison is about, so
        # rows measured at two paddings are two experiments. A sweep from before
        # the knob existed has no column and reads as 0, which is what it was.
        key = (int(r.get("payload") or 0), int(r["replicas"]), r["variant"],
               int(r["threads"]))
        rows[key].append(r)

    if dropped:
        print(f"({dropped} rows dropped: ok=0)")
    if unmeasured:
        print("(ignored: " + ", ".join(f"{v} x{c}" for v, c in
                                       sorted(unmeasured.items())) + ")")
    if dropped or unmeasured:
        print()

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
                            dut_loader=col(rs, "dut_loader_cpu_s"),
                            fan_busy=col(rs, "fanout_busy_pct"),
                            fan_softirq=col(rs, "fanout_softirq_pct"),
                            fan_share=col(rs, "fanout_irq_share"),
                            fan_cpu=next((r["fanout_cpu"] for r in rs
                                          if r.get("fanout_cpu")), None),
                            leader=col(rs, "leader_steady_pct"),
                            follower=col(rs, "follower_steady_pct"),
                            little=col(rs, "little_ratio"),
                            starved=col(rs, "starved_clients"))

    payloads = sorted({k[0] for k in summary})
    replicas = sorted({k[1] for k in summary})
    threads = sorted({k[3] for k in summary})

    for pad, n in [(p_, n_) for p_ in payloads for n_ in replicas
                   if any(k[0] == p_ and k[1] == n_ for k in summary)]:
        head = f"=== {n} replicas" + (f", {pad} B on the PREPARE " if pad else " ")
        print(head + "=" * max(4, 70 - len(head)))
        print(f"{'clients':>8} | " + " | ".join(f"{LABEL[v].replace(chr(92),''):>22}"
                                               for v in ORDER if any((pad, n, v, t) in summary for t in threads)))
        present = [v for v in ORDER if any((pad, n, v, t) in summary for t in threads)]
        print(f"{'':>8} | " + " | ".join(f"{'kops  (sd)   p50 us':>22}" for _ in present))
        for t in threads:
            cells = []
            for v in present:
                s = summary.get((pad, n, v, t))
                if s:
                    # "!" where clients / throughput does not match the median
                    # latency: the clients finished far apart and the rate sum
                    # credits the fast ones. The latency stands, the throughput
                    # does not.
                    # Starvation first: it is observed, not inferred. The
                    # ratio is the backstop for a run that adds up wrong with
                    # every client served.
                    bad = ((s["starved"] or 0) > 0 or
                           (s["little"] is not None
                            and not 0.67 <= s["little"] <= 1.5))
                    cells.append(f"{s['tp']:7.1f}{'!' if bad else ' '}"
                                 f"({s['tp_sd']:4.1f}) {s['med']:7.1f}")
                else:
                    cells.append(" " * 22)
            print(f"{t:>8} | " + " | ".join(cells))

        # Whether the run was leader-bound at all. A variant whose leader is
        # short of saturation was limited by something else, and its throughput
        # is not a statement about the offload -- except where the offload is
        # itself the reason the leader has headroom, which is the result.
        print()
        for v in present:
            pts = [(t, summary[(pad, n, v, t)]) for t in threads
                   if (pad, n, v, t) in summary
                   and summary[(pad, n, v, t)]["leader"] is not None]
            if not pts:
                continue
            top_t, top = max(pts, key=lambda kv: kv[1]["leader"])
            fol = (f", follower {top['follower']:.0f}%"
                   if top["follower"] is not None else "")
            print(f"  leader at its peak {LABEL[v].replace(chr(92), ''):>20}: "
                  f"{top['leader']:5.1f}% at {top_t:>4} clients{fol}")

        # What the duplication cost the core that did it. This is the number
        # the comparison turns on once the DUT is narrowed to one queue: while
        # that core has headroom, the copy path and the shared-page one cannot
        # be told apart, because nothing is competing for what the second saves.
        print()
        for v in present:
            pts = [summary[(pad, n, v, t)] for t in threads
                   if (pad, n, v, t) in summary
                   and summary[(pad, n, v, t)]["fan_busy"] is not None]
            if not pts:
                continue
            top = max(pts, key=lambda p: p["fan_busy"])
            share = (f", {top['fan_share']:.2f} of its interrupts"
                     if top["fan_share"] is not None and top["fan_share"] < 0.9
                     else "")
            print(f"  fan-out cpu{top['fan_cpu'] or '?':>3} "
                  f"{LABEL[v].replace(chr(92), ''):>20}: "
                  f"{top['fan_busy']:5.1f}% busy, {top['fan_softirq']:5.1f}% "
                  f"softirq at its peak{share}")

        # The DUT as a whole, and its busiest core whatever that is: when the
        # busiest is not the fan-out core, the limit is something else -- with
        # DUT_REPLICA=1, usually the local replica.
        print()
        for v in present:
            sq = [summary[(pad, n, v, t)]["dut_softirq"] for t in threads
                  if (pad, n, v, t) in summary
                  and summary[(pad, n, v, t)]["dut_softirq"] is not None]
            if sq:
                print(f"  DUT softirq {LABEL[v].replace(chr(92), ''):>20}: "
                      f"{max(sq):.2f} cores at its busiest")

        # Peak throughput, which is what the broadcast offload is supposed to move.
        print()
        base = None
        suspect = 0
        for v in present:
            pts = []
            for t in threads:
                s_ = summary.get((pad, n, v, t))
                if not s_:
                    continue
                if ((s_["starved"] or 0) > 0 or
                        (s_["little"] is not None
                         and not 0.67 <= s_["little"] <= 1.5)):
                    suspect += 1
                    continue
                pts.append((t, s_))
            if not pts:
                continue
            at, top = max(pts, key=lambda kv: kv[1]["tp"])
            peak = top["tp"]
            if v == "baseline":
                base = peak
            rel = f"  {peak / base:.2f}x baseline" if base else ""
            print(f"  peak {LABEL[v].replace(chr(92), ''):>20}: {peak:8.1f} kops "
                  f"at {at:>3} clients{rel}")
        if suspect:
            starved = max((summary[(pad, n, v, t)]["starved"] or 0)
                          for v in present for t in threads
                          if (pad, n, v, t) in summary)
            why = (f"up to {starved:.0f} of the clients were not served at all"
                   if starved else
                   "the clients did not measure the same window")
            print(f"  ({suspect} points marked ! left out of the peaks: "
                  f"clients/throughput does not match the median latency -- "
                  f"{why}, so the run did not have the concurrency it claims)")
        print()

    # One row per (replicas, variant, clients): the whole experiment in one
    # table, to be read or plotted from without opening the raw rows.
    summary_csv = os.path.join(outdir, "summary.csv")
    cols = ["replicas", "payload", "variant", "clients", "reps", "kops", "kops_sd",
            "p50_us", "p50_sd", "p90_us", "p95_us", "p99_us", "elapsed_spread",
            "dut_busy_cores", "dut_softirq_cores", "dut_loader_cpu_s",
            "fanout_cpu", "fanout_busy_pct", "fanout_softirq_pct",
            "fanout_irq_share", "leader_steady_pct", "follower_steady_pct",
            "little_ratio", "starved_clients"]
    with open(summary_csv, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for (pad, n, v, t), s_ in sorted(summary.items(),
                                         key=lambda kv: (kv[0][1], kv[0][0],
                                                         ORDER.index(kv[0][2]),
                                                         kv[0][3])):
            w.writerow([n, pad, v, t, s_["n"],
                        f"{s_['tp']:.3f}", f"{s_['tp_sd']:.3f}",
                        f"{s_['med']:.3f}", f"{s_['med_sd']:.3f}",
                        f"{s_['p90']:.3f}", f"{s_['p95']:.3f}",
                        f"{s_['p99']:.3f}",
                        f"{s_['spread']:.4f}" if s_["spread"] else "",
                        f"{s_['dut_busy']:.4f}" if s_["dut_busy"] is not None else "",
                        f"{s_['dut_softirq']:.4f}" if s_["dut_softirq"] is not None else "",
                        f"{s_['dut_loader']:.3f}" if s_["dut_loader"] is not None else "",
                        s_["fan_cpu"] or "",
                        f"{s_['fan_busy']:.1f}" if s_["fan_busy"] is not None else "",
                        f"{s_['fan_softirq']:.1f}" if s_["fan_softirq"] is not None else "",
                        f"{s_['fan_share']:.4f}" if s_["fan_share"] is not None else "",
                        f"{s_['leader']:.1f}" if s_["leader"] is not None else "",
                        f"{s_['follower']:.1f}" if s_["follower"] is not None else "",
                        f"{s_['little']:.3f}" if s_["little"] is not None else "",
                        f"{s_['starved']:.1f}" if s_["starved"] is not None else ""])
    print(f"summary in {summary_csv}")


if __name__ == "__main__":
    main()
