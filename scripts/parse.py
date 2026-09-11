#!/usr/bin/env python3
"""Turn one client log into one CSV row.

The client prints, per benchmark client, a line "Completed N requests in S.uuuuuu
seconds" and its own median / 90th / 95th / 99th percentile.  Throughput is the
requests all of them completed over the longest of their windows, which is the
rate the cluster actually sustained; the percentiles are averaged over the
clients, since each already reports its own distribution.
"""
import argparse
import csv
import os
import re
import sys

COMPLETED = re.compile(r"Completed (\d+) requests in (\d+)\.(\d+) seconds")
PCT = re.compile(r"(Median|90th percentile|95th percentile|99th percentile) "
                 r"latency is (\d+) ns")

KEY = {"Median": "median_us", "90th percentile": "p90_us",
       "95th percentile": "p95_us", "99th percentile": "p99_us"}

FIELDS = ["variant", "replicas", "threads", "requests", "warmup", "rep",
          "throughput_kops", "median_us", "p90_us", "p95_us", "p99_us",
          "elapsed_s", "clients_done", "ok", "note"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--variant", required=True)
    ap.add_argument("--replicas", type=int, required=True)
    ap.add_argument("--requests", type=int, required=True)
    ap.add_argument("--threads", type=int, required=True)
    ap.add_argument("--warmup", type=int, required=True)
    ap.add_argument("--rep", type=int, default=0)
    ap.add_argument("--out")
    a = ap.parse_args()

    text = open(a.log, errors="replace").read()

    done = COMPLETED.findall(text)
    pcts = {}
    for name, ns in PCT.findall(text):
        pcts.setdefault(KEY[name], []).append(int(ns) / 1000.0)

    row = {f: "" for f in FIELDS}
    row.update(variant=a.variant, replicas=a.replicas, requests=a.requests,
               threads=a.threads, warmup=a.warmup, rep=a.rep,
               clients_done=len(done))

    if not done:
        row["ok"] = 0
        # A view change means the run measured a protocol recovery, not a
        # broadcast, so say so rather than reporting the number.
        row["note"] = ("view change" if "view change" in text.lower()
                       else "no client completed")
        tail = [l for l in text.strip().splitlines() if l.strip()][-3:]
        print(f"FAILED {a.variant} n={a.replicas} t={a.threads}: "
              f"{row['note']}", file=sys.stderr)
        for l in tail:
            print("  " + l, file=sys.stderr)
    else:
        total = sum(int(n) for n, _, _ in done)
        elapsed = max(int(s) + int(us.ljust(6, '0')) / 1e6 for _, s, us in done)
        row["elapsed_s"] = round(elapsed, 6)
        row["throughput_kops"] = round(total / elapsed / 1000.0, 3)
        for k, v in pcts.items():
            row[k] = round(sum(v) / len(v), 3)
        row["ok"] = 1 if "view change" not in text.lower() else 0
        if not row["ok"]:
            row["note"] = "view change"

    print(",".join(f"{k}={row[k]}" for k in
                   ("variant", "replicas", "threads", "throughput_kops",
                    "median_us", "p99_us", "ok")))

    if a.out:
        new = not os.path.exists(a.out)
        with open(a.out, "a", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=FIELDS)
            if new:
                w.writeheader()
            w.writerow(row)


if __name__ == "__main__":
    main()
