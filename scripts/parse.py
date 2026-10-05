#!/usr/bin/env python3
"""Turn one client log into one CSV row.

The client prints, per benchmark client, a line "Completed N requests in S.uuuuuu
seconds" and its own median / 90th / 95th / 99th percentile.

Throughput is the **sum of the per-client rates**, sum(N_i / T_i).  It used to
be sum(N_i) / max(T_i), which is the same number only while the clients finish
together, and badly wrong when they do not: at seven replicas the clients
spread over 1.2x and that metric read 25.9 kops where the cluster was serving
40.4.  Little's law ties the sum of the rates to the latency each client
reports, and `elapsed_spread` -- max(T_i)/min(T_i) -- is carried alongside so
that an uneven run is visible rather than folded into the throughput.

The percentiles are averaged over the clients, since each reports its own.
"""
import argparse
import csv
import os
import re
import statistics as st
import sys

COMPLETED = re.compile(r"Completed (\d+) requests in (\d+)\.(\d+) seconds")
PCT = re.compile(r"(Median|90th percentile|95th percentile|99th percentile) "
                 r"latency is (\d+) ns")

KEY = {"Median": "median_us", "90th percentile": "p90_us",
       "95th percentile": "p95_us", "99th percentile": "p99_us"}

FIELDS = ["variant", "replicas", "threads", "payload", "client_procs", "requests",
          "warmup", "rep", "throughput_kops", "median_us", "p90_us", "p95_us",
          "p99_us", "elapsed_s", "elapsed_spread", "clients_done",
          "dut_busy_cores", "dut_softirq_cores", "dut_loader_cpu_s",
          "dut_busiest_pct", "dut_busiest_cpu",
          "fanout_cpu", "fanout_busy_pct", "fanout_softirq_pct",
          "fanout_irq_share",
          "leader_cpu", "leader_cpu_pct", "leader_core_pct",
          "leader_steady_pct", "leader_steady_core_pct",
          "follower_cpu", "follower_steady_pct", "follower_steady_core_pct",
          "follower_is_fanout", "little_ratio", "starved_clients",
          "ok", "note"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--variant", required=True)
    ap.add_argument("--replicas", type=int, required=True)
    ap.add_argument("--requests", type=int, required=True)
    ap.add_argument("--threads", type=int, required=True)
    ap.add_argument("--warmup", type=int, required=True)
    ap.add_argument("--rep", type=int, default=0)
    # Bytes of dead weight the leader hangs on the PREPARE, which is the one
    # message the fan-out node duplicates. It belongs in the row because the
    # whole comparison is about what duplicating a packet costs, and that
    # depends on how big the packet is: two sweeps at two paddings are two
    # experiments, not repetitions of one.
    ap.add_argument("--payload", type=int, default=0)
    ap.add_argument("--client-procs", type=int, default=1)
    # Measured on the DUT across the whole client run, in cores rather than
    # percent. The loader's own CPU is there to show it is nil: the work is the
    # XDP program, in softirq.
    ap.add_argument("--dut-busy-cores", type=float, default=None)
    ap.add_argument("--dut-softirq-cores", type=float, default=None)
    ap.add_argument("--dut-loader-cpu-s", type=float, default=None)
    # The busiest single core, whatever it is. Kept as a cross-check: when it
    # is not the fan-out core, something else on the DUT is the limit -- with
    # DUT_REPLICA=1 it is usually the local replica's core.
    ap.add_argument("--dut-busiest-pct", type=float, default=None)
    ap.add_argument("--dut-busiest-cpu", default=None)
    # The core that actually duplicates the packets: the one that took the
    # interface's completion interrupts, since the XDP program runs in NAPI
    # softirq on whichever core is handed the queue. `fanout_irq_share` says
    # what fraction of those interrupts landed there -- below ~0.9 the receive
    # side is spread over several queues and there is no single such core, so
    # the two percentages describe one of many.
    ap.add_argument("--fanout-cpu", default=None)
    ap.add_argument("--fanout-busy-pct", type=float, default=None)
    ap.add_argument("--fanout-softirq-pct", type=float, default=None)
    ap.add_argument("--fanout-irq-share", type=float, default=None)
    # The leader's core on the other machine, which is what the offloads are
    # supposed to free. `leader_cpu_pct` is the replica process's own share of
    # it; `leader_core_pct` is the core altogether, the process plus the
    # softirq for its traffic. Well under 100 means the run was not
    # leader-bound and its throughput describes some other limit.
    ap.add_argument("--leader-cpu", default=None)
    ap.add_argument("--leader-cpu-pct", type=float, default=None)
    ap.add_argument("--leader-core-pct", type=float, default=None)
    # The same two over the steady middle of the run, which is the pair that
    # answers "was this run leader-bound": the window averages are dragged down
    # by the client ramp and the tail.
    ap.add_argument("--leader-steady-pct", type=float, default=None)
    ap.add_argument("--leader-steady-core-pct", type=float, default=None)
    # The follower this node runs, which under the XDP variants is also the one
    # doing the duplication. Its replica process and the duplication sit on
    # different cores, so this is the replica's own cost and `fanout_busy_pct`
    # is the duplication's -- the node's total is the two together.
    ap.add_argument("--follower-cpu", default=None)
    ap.add_argument("--follower-steady-pct", type=float, default=None)
    ap.add_argument("--follower-steady-core-pct", type=float, default=None)
    ap.add_argument("--follower-is-fanout", default=None)
    ap.add_argument("--out")
    a = ap.parse_args()

    text = open(a.log, errors="replace").read()

    done = COMPLETED.findall(text)
    pcts = {}
    for name, ns in PCT.findall(text):
        pcts.setdefault(KEY[name], []).append(int(ns) / 1000.0)

    row = {f: "" for f in FIELDS}
    row.update(variant=a.variant, replicas=a.replicas, requests=a.requests,
               threads=a.threads, client_procs=a.client_procs,
               warmup=a.warmup, rep=a.rep, payload=a.payload,
               clients_done=len(done))
    for k, v in (("dut_busy_cores", a.dut_busy_cores),
                 ("dut_softirq_cores", a.dut_softirq_cores),
                 ("dut_loader_cpu_s", a.dut_loader_cpu_s),
                 ("dut_busiest_pct", a.dut_busiest_pct),
                 ("fanout_busy_pct", a.fanout_busy_pct),
                 ("fanout_softirq_pct", a.fanout_softirq_pct),
                 ("fanout_irq_share", a.fanout_irq_share),
                 ("leader_cpu_pct", a.leader_cpu_pct),
                 ("leader_core_pct", a.leader_core_pct),
                 ("leader_steady_pct", a.leader_steady_pct),
                 ("leader_steady_core_pct", a.leader_steady_core_pct),
                 ("follower_steady_pct", a.follower_steady_pct),
                 ("follower_steady_core_pct", a.follower_steady_core_pct)):
        if v is not None:
            row[k] = round(v, 4)
    if a.dut_busiest_cpu:
        row["dut_busiest_cpu"] = a.dut_busiest_cpu
    if a.fanout_cpu:
        row["fanout_cpu"] = a.fanout_cpu
    if a.leader_cpu:
        row["leader_cpu"] = a.leader_cpu
    if a.follower_cpu:
        row["follower_cpu"] = a.follower_cpu
    if a.follower_is_fanout:
        row["follower_is_fanout"] = a.follower_is_fanout

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
        per = [(int(n), int(s) + int(us.ljust(6, "0")) / 1e6)
               for n, s, us in done]
        row["elapsed_s"] = round(max(t for _, t in per), 6)
        row["elapsed_spread"] = round(max(t for _, t in per) /
                                      min(t for _, t in per), 4)
        row["throughput_kops"] = round(sum(n / t for n, t in per) / 1000.0, 3)

        # Clients the cluster effectively did not serve: with the window fixed
        # by -D they all report, and a starved one shows up as a request count
        # a fraction of the rest. They are counted rather than dropped, because
        # the run is not a clean measurement of anything while they exist --
        # Little's law below fails precisely because the load was not spread
        # over the clients the run claims to have.
        counts = [n for n, _ in per]
        typical = st.median(counts)
        row["starved_clients"] = sum(1 for c in counts if c < typical * 0.1)
        # The median of the per-client medians, not their mean. A client whose
        # requests are being dropped reports the 7-second retransmission
        # timeout as its median, and one such client in a hundred drags a mean
        # from 2 ms to 112 ms. The median of medians describes the clients that
        # were actually served, and `starved_clients` says how many were not.
        for k, v in pcts.items():
            row[k] = round(st.median(v), 3)

        # Little's law, as a check on the harness rather than on the system.
        # Under a closed loop with `threads` outstanding requests,
        # clients / throughput is the *mean* cycle time, while the client
        # reports the *median* latency -- and latency is right-skewed, so a
        # healthy run sits a little above 1 rather than at it. On this testbed
        # the runs with nothing starved have a median ratio of 1.05 and a 99th
        # percentile of 1.52, which is why the bound below is 1.5 and not 1.3:
        # tighter than that flags skew rather than error. Where it is really
        # off, the two numbers were measured over different windows: the
        # clients finished far apart (see elapsed_spread) and the sum of their
        # rates credits the fast ones with a throughput the cluster never
        # sustained. Such a point shows latency falling while throughput rises,
        # which a closed loop cannot do, so it is not a measurement.
        tp = row["throughput_kops"]
        med = row.get("median_us")
        if tp and med:
            row["little_ratio"] = round(
                (a.threads / (tp * 1000.0) * 1e6) / med, 3)
        row["ok"] = 1 if "view change" not in text.lower() else 0
        if not row["ok"]:
            row["note"] = "view change"
        elif not row["median_us"]:
            # Every client reported, and not one of them completed a request
            # inside the window: the clients ran, the cluster did not serve
            # them. That is an absent measurement, not a slow one -- it has a
            # throughput of zero and no latency at all -- so it is not a row to
            # summarise.
            row["ok"] = 0
            row["note"] = "no request completed in the window"
        elif row["starved_clients"]:
            row["note"] = f"starved={row['starved_clients']}"
        elif row["little_ratio"] and not 0.67 <= row["little_ratio"] <= 1.5:
            # Kept as ok=1 -- the run happened and its latency stands -- but
            # named, so that report.py can leave it out of the peak instead of
            # quietly reporting a throughput the cluster never reached.
            row["note"] = f"little={row['little_ratio']}"

    print(",".join(f"{k}={row[k]}" for k in
                   ("variant", "replicas", "threads", "throughput_kops",
                    "median_us", "p99_us", "leader_steady_pct",
                    "follower_steady_pct", "fanout_busy_pct", "ok")))

    if a.out:
        new = not os.path.exists(a.out)
        with open(a.out, "a", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=FIELDS)
            if new:
                w.writeheader()
            w.writerow(row)


if __name__ == "__main__":
    main()
