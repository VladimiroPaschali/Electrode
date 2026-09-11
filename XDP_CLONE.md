# Electrode on the XDP_CLONE driver

This fork adds two XDP points to Electrode's broadcast comparison and makes the
tree build and run on Ubuntu 24.04 with a stock kernel. Upstream is
[Electrode-NSDI23/Electrode](https://github.com/Electrode-NSDI23/Electrode),
NSDI'23.

## Why a fan-out node

Electrode's broadcast offload, `SEC("FastBroadCast")` in
`xdp-handler/fast_kern.c`, is a **TC egress** program on the leader. The leader
sends one packet with the top bit of the view word set;
`bpf_clone_redirect(skb, skb->ifindex, 0)` re-injects a clone into the same
egress path, the program runs again on the clone with the replica index
incremented, and the chain produces one packet per follower.

XDP cannot do that. A locally generated packet never passes an XDP hook, so
`XDP_CLONE_TX` has nothing to act on: the driver clones a packet on the path it
*arrives* on. The duplication therefore has to happen on a machine the packet
reaches — an intermediate node. The leader sends one packet to it, and the
copies leave from there.

```
                      ┌─────────────── maestrale (DUT) ──────────────┐
                      │  xdp-fanout: XDP_CLONE_TX + L3 routing       │
                      └───────▲──────────────────────┬───────────────┘
                              │ 1 packet             │ n packets
    ┌─────────────────────────┴──────────────────────▼─────────────────┐
    │ grecale: one netns per replica, one for the client                │
    │   elec-r0 .10   elec-r1 .11   elec-r2 .12   elec-cl .200          │
    └───────────────────────────────────────────────────────────────────┘
```

## The four points

| variant | where the broadcast is duplicated | packets on the wire |
|---|---|---|
| `baseline` | nowhere: `SendMessageToAll()` sends one per follower | n in, n out |
| `tc` | the leader's own TC egress hook — Electrode's offload | n in, n out |
| `xdp` | the fan-out node, `XDP_CLONE_TX`, a page and a header rewrite per copy | 1 in, n out |
| `xdp-inline` | the fan-out node, descriptor stamped on the original: one shared RX page, each copy's header handed to the NIC as the WQE inline header | 1 in, n out |

In all four the packet crosses the fan-out node on its way to a follower, so
the hop count is identical and what the numbers compare is the duplication
itself. That parity is the whole reason for the network-namespace topology:
put the replicas side by side in one namespace and their packets never reach a
wire, so the baseline and the TC point would be measured on loopback while the
XDP ones crossed the link.

## What had to change upstream

**Build.** The top-level `Makefile` linked a libbpf built inside a kernel-5.8
source tree that `kernel-src-download.sh` fetched; it now uses the
distribution's libbpf and protobuf, so no kernel is downloaded or installed.
`nistore/` and `timeserver/` are excluded — a transactional KV store unrelated
to Multi-Paxos, which does not compile against a modern libstdc++.

**eBPF.** `fast_kern.c` used `struct bpf_map_def`, dropped by libbpf 1.0; the
maps are BTF definitions now. `fast_user.c` used
`bpf_object__find_program_by_title()`, `bpf_object__load_xattr()`,
`bpf_program__pin_instance()`, `bpf_set_link_xdp_fd()` and `tc(8)` through
`system()`, all replaced by their libbpf 1.x equivalents. The five XDP
programs — the `FAST_REPLY` and `FAST_QUORUM_PRUNE` offloads, which this
comparison does not use and which were written against 5.8 — are behind
`ELECTRODE_XDP_OFFLOADS`, off by default. The replica MAC addresses were
hardcoded in `fast_user.c` and now come from a file.

`FastBroadCast` reads `leaderIdx` from `map_ctr_state`, which upstream is only
ever written by the replica's `ModifyKernelState()` — and that only runs with
one of the other three offloads compiled in. With the broadcast offload alone
nothing would write it, so the loader seeds it.

**Sending once.** `lib/configuration.cc` learns a `fanout host:port`
directive, and under `-DXDP_BROADCAST` `TransportCommon::SendMessageToAll()`
sends one packet there instead of one per follower. Nothing is marked in the
payload: `TC_BROADCAST` sets the top bit of the view word, which sits some
ninety bytes into the frame, out of reach of a 64-byte WQE inline header. The
fan-out node recognises a broadcast by the address it is sent to, which is the
only thing the shared-page build could act on.

## The fan-out program

`xdp-fanout/fanout.bpf.c`, one source, two builds (`-DAXDP_INLINE` for the
second). It does two jobs:

- **the broadcast**: a packet addressed to the fan-out address becomes one per
  replica *except the sender*. The original is the first recipient's frame and
  `XDP_CLONE_TX(count - 1)` produces the rest; each copy's run rewrites the
  destination for its own recipient. The source address and port are never
  touched, so a follower answers the leader and not this node.
- **routing**: everything else is forwarded to its destination by rewriting the
  two MAC addresses, which is what gives the four variants the same hop count.

*Except the sender*, not *except the leader*. `VRClient::SendRequest()` sends
**every** request with `SendMessageToAll()`, not just the retries — so a
fan-out that excluded the leader would drop every client request on the floor,
which is exactly what the first version did.

That same call is also why `SendMessageToAll()` uses the fan-out **for replicas
only**. `TC_BROADCAST` acts on packets whose view word has the top bit set, and
only the leader's `CloseBatch()`, `SendNullCommit()` and `ResendPrepare()` set
it; offloading the client's request broadcast as well would hand the XDP points
a saving the TC point does not have, and with `-t` clients sharing one process
and one event loop, a large one. The client sends its three unicasts in all
four variants.

On the inline build nothing in the packet is written at all: the 42-byte
Ethernet/IP/UDP header is built in the run's own metadata, stamped with
`axdp_stamp_tx_replace()`, and the NIC puts it on the wire in place of the
packet's first 42 bytes, which the driver leaves out of the DMA. That is what
the shared page requires — every frame of the batch points at the one RX page
and the DMA is asynchronous, so editing the packet on one copy would corrupt
the frames already queued for the others.

## Running it

On grecale, once:

```bash
scripts/build.sh 3                 # the three C++ builds and the TC object
```

On maestrale (the DUT), which drives the whole thing over ssh:

```bash
make -C xdp-fanout                                   # once
scripts/run.sh --variant xdp-inline --replicas 3 --threads 4
scripts/sweep.sh --replicas 3 5 7 --threads 1 2 4 8 16 --reps 3 --out results/e1.csv
```

`sweep.sh` pins both machines to `performance` and turns interrupt coalescing
off for the duration, then puts them back: a Paxos round trip here is under a
hundred microseconds and the mlx5 default adapts `rx-usecs` to the load, so
without that the numbers would describe the coalescing.

The fan-out needs `rx_striding_rq off` (the clone actions only exist on the
legacy-RQ path) and `xdp_tx_mpwqe off` (an MPWQE session shares one eseg
between packets, so the inline header would be silently ignored). `run.sh`
refuses to start otherwise.

## Measuring it

Throughput is the **sum of the per-client rates**, `sum(N_i / T_i)`. The
obvious `sum(N_i) / max(T_i)` is the same number only while the clients finish
together, and silently wrong when they do not: at seven replicas one client
process saturated its core -- 85% against the leader's 75%, because
`VRClient::SendRequest()` sends one unicast per replica and that is seven per
request -- the clients spread over 1.2x, and the metric read 25.9 kops where
the cluster was serving 44.8.

Two things follow, and both are in the harness now. The clients are spread over
one process per core (`--client-procs`), which puts the bottleneck back on the
leader, where the experiment wants it: at seven replicas the leader then sits
at 77-81% and no client process is among the six busiest. And `elapsed_spread`,
`max(T_i)/min(T_i)`, is recorded next to every measurement, so a run whose
clients were served unevenly says so instead of folding it into the throughput.

The symptom worth remembering: under a closed loop, `clients / throughput`
should equal the reported median latency. Where it did not -- 1.23 to 1.45
against 1.00 to 1.03 everywhere else -- the harness was the thing being
measured.

## Known limits

- **Namespaces, not machines.** The replicas share grecale's CPU, so the
  absolute throughput is not comparable with the paper's; the four variants are
  comparable with each other, which is what the experiment is for.
- **The fan-out node is nowhere near its limit here.** Maestrale's busiest core
  is 94-99% idle during a run, which is why `xdp` and `xdp-inline` come out the
  same: the shared page and the missing 320-byte memcpy are a saving on a
  resource nothing is competing for. That difference belongs to
  `microbenchmark/`, which measures the node itself.
- **The TC point nests `bpf_clone_redirect`.** One level per follower, against
  the kernel's `xmit_recursion` limit of 8 — fine to seven replicas, not beyond.
- **View changes are not handled**, upstream's own caveat. A run in which one
  happens is reported with `ok=0` rather than as a measurement.
