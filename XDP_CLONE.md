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
    │ grecale: one netns per replica                                    │
    │   elec-r0 .10   elec-r1 .11   elec-r2 .12                         │
    └───────────────────────────────────────────────────────────────────┘
```

The clients run on maestrale, beside the fan-out program; see *Saturating the
fan-out node*.

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

## What it measures

216 runs, three repetitions each, three cluster sizes, one to thirty-two
clients. Peak throughput, and the median latency at thirty-two clients:

| replicas | baseline | Electrode (TC) | XDP_CLONE | XDP_CLONE inline |
|---|---|---|---|---|
| 3 | 45.9 kops | 51.4 (1.12x) | 59.3 (1.29x) | 59.8 (1.30x) |
| 5 | 26.8 kops | 35.8 (1.34x) | 46.5 (1.74x) | 46.5 (1.73x) |
| 7 | 18.4 kops | 28.9 (1.57x) | 37.2 (2.02x) | 37.5 (2.03x) |

| replicas | baseline | Electrode (TC) | XDP_CLONE |
|---|---|---|---|
| 3 | 705 us | 626 | 532 |
| 5 | 1212 us | 897 | 709 |
| 7 | 1722 us | 1106 | 841 |

The leader's core is the contended resource: it saturates at four to eight
clients in every variant, and what separates them is how much of the broadcast
it still has to do itself. Both offloads save it the same system calls -- one
`sendmsg` instead of one per follower -- but TC then makes the copies **on that
same core**, inside its own egress path, a full `dev_queue_xmit` each. XDP
makes them on another machine. So the advantage of XDP over TC grows with the
cluster: 1.15x at three replicas, 1.30x at five and seven.

`xdp` and `xdp-inline` come out the same everywhere. That is expected here and
is not a null result about the mechanism: see *Known limits*.

Reproduce with:

```bash
scripts/sweep.sh --replicas 3 5 7 --threads 1 2 4 8 16 32 \
                 --client-procs 4 --reps 3 --out results/e1.csv
scripts/report.py results/e1.csv
```

## Checking that each variant does what it says

Three of the four would produce a full set of plausible numbers if their
offload silently did nothing, so `scripts/verify.sh` counts, on the leader, the
datagrams userspace handed to the stack against the frames that actually left
its interface, over 3000 requests:

| variant | datagrams | frames on the wire | to the fan-out node | to a follower |
|---|---|---|---|---|
| baseline | 60060 | 59696 | 0 | 47758 |
| tc | 36042 | **60076** | 0 | 48062 |
| xdp | 36036 | 36039 | **24027** | 0 |
| xdp-inline | 36039 | 36042 | **24029** | 0 |

The baseline's two counts agree: one frame per datagram, all of them addressed
to a follower. The TC point sends 40% fewer datagrams and puts **more** frames
on the wire than it sent -- the difference is `bpf_clone_redirect()` working
below the IP counter. The XDP points send the same 40% fewer datagrams and put
exactly that many frames on the wire, addressed to the fan-out node; both
followers still receive their 24027, which were made there.

## Scaling past seven replicas

Upstream's `FastBroadCast` re-enters its own hook once per follower: it stashes
the next replica index in the first byte of the type string, calls
`bpf_clone_redirect()`, and the clone comes back to do the same for the one
after. That nests one `dev_queue_xmit()` per follower against
`XMIT_RECURSION_LIMIT`, which is **8**. It works to seven replicas and then
silently stops broadcasting: at fifteen the followers stop hearing PREPARE and
the cluster falls into a view change, `DoViewChangeMessage` in 287 fragments.

One run can clone as many times as it likes instead, since
`bpf_clone_redirect()` leaves the original alone. What is then needed is a way
for a copy not to be duplicated again on its way out, and `skb->mark` does that
without touching the packet — which also means the type string no longer has to
carry an index and be restored afterwards. The loop is rolled, not unrolled;
two things about it are worth knowing, because each cost an hour:

- **The map key must not be `&i`.** Passing the address of the loop counter to
  a helper puts it on the stack, the verifier stops tracking it as a scalar,
  and it reports *"infinite loop detected"* on a loop that plainly terminates.
  A `__u32 key = i` beside it is the whole fix.
- **`#pragma unroll` will not save you.** clang does not unroll a loop with more
  than one exit, so an early `return` inside the body quietly leaves it rolled.

Verified at 31 replicas: the leader hands 12,012 datagrams to the stack and
732,822 frames leave its interface — the same count the baseline puts there
from 732,732 datagrams of its own.

| 31 replicas, 8 clients | throughput | median |
|---|---|---|
| baseline | 5.39 kops | 1485 µs |
| Electrode (TC) | 7.47 (1.39×) | 1067 |
| XDP_CLONE | 10.41 (1.93×) | 765 |
| XDP_CLONE inline | 10.68 (1.98×) | 744 |

## The other half: where the leader's time actually goes

The broadcast offload takes the *sends* off the leader and leaves the
*receives*, and the receives are what is left. Measured, at four cluster sizes:

| replicas | leader CPU per request | datagrams **received**/request | datagrams **sent**/request |
|---|---|---|---|
| 3 | 21.4 µs | 4.9 | 4.9 |
| 7 | 34.0 µs | 11.3 | 4.8 |
| 15 | 51.2 µs | 22.2 | 4.4 |
| 31 | 97.5 µs | 44.9 | 4.3 |

The sends stay flat while the cluster grows tenfold — that is the offload, and
it has already removed everything it can. The receives grow linearly, because
every follower still answers with a PrepareOK the leader has to take off the
socket and parse. A fit gives **12 µs fixed plus 1.9 µs for every datagram
received**; at thirty-one replicas the receives are 85% of the leader's cost.
(The absolute figures include the warmup, so read the slope, not the
intercept.)

That is precisely what Electrode's *other* offload attacks, so the two belong
in the same table. At 31 replicas, 16 clients, two repetitions each:

| | throughput | vs baseline | median |
|---|---|---|---|
| baseline | 3.35 kops | 1.00x | 4864 µs |
| `prune` — quorum prune alone | 3.80 | 1.13x | 4209 |
| `tc` — Electrode's broadcast | 6.15 | 1.84x | 2436 |
| `xdp` — XDP_CLONE broadcast | 7.76 | 2.32x | 1774 |
| **`xdp-prune` — both** | **10.09** | **3.01x** | **1595** |

The two are **more than additive**: +132% and +13% on their own, +201%
together. Pruning receives is worth little while the leader is still send-bound
— which is why `prune` alone barely moves — and worth a further 1.30x once the
sends are gone.

### They are not separable

`FastBroadCast`, the **TC** program, clears the quorum bitset whenever it sees
a PREPARE leave, *before* its own `is_broadcast` check. `HandlePrepareOK`, the
**XDP** program, counts into that same bitset. Attach the XDP half alone and
the entry never matches the current (view, opnum), so nothing is pruned — and
since `FAST_QUORUM_PRUNE` compiles the userspace quorum count out, a leader
handed every PrepareOK commits on the first one. The leader then sits in
`ResendPrepare` for ever. Both halves have to go on together.

(The harness has since been cut down to the four broadcast points, so it no
longer starts either half: the numbers in this section were measured with
`scripts/node.sh xdp-start`, which was removed with them.)

### What it took to run them at all

- **The 6.14 verifier turns down `HandleRequest_main`**: 1,000,001 instructions
  against a limit of 1,000,000. It belongs to the batching offload, so it is
  behind `FAST_BATCH` now and the three the quorum prune needs verify as they
  are.
- **A macvlan has no native XDP.** Upstream only ever asks for
  `XDP_FLAGS_DRV_MODE`; the loader now falls back to generic and says which it
  used. Generic runs after the skb is built, so it does not save the
  allocation — it still takes the datagram before the socket queue, the
  `recvfrom` and the protobuf parse, which is the 1.9 µs.
- **`/sys/fs/bpf` is invisible inside a namespace.** `ip netns exec` remounts
  `/sys` in a mount namespace of its own, shadowing the bpffs; and a replica in
  another namespace could not have found the pin anyway. A bpffs at `/run/bpf`
  is inherited by all of them, one directory per replica since they pin the
  same names.

## Saturating the fan-out node

The comparison between `xdp` and `xdp-inline` only means something while the
core doing the duplication has none to spare, and for a long time it had
plenty: maestrale's busiest core was 94-99% idle, and the two came out the same
everywhere. Two things were in the way, and both are fixed here.

**Grecale could not offer enough load.** With every replica *and* every client
on the one machine, the cluster saturated grecale long before it saturated the
duplication. The clients moved to maestrale, which has thirty-one cores that
are not the fan-out's (`CLIENTS_ON_DUT=1`, the default; `0` restores the old
topology, which `scripts/verify.sh` still wants). Nothing in the eBPF had to
change: the program already passes anything addressed to the local address that
is not the fan-out port, which is exactly what a client's replies are. Hop
parity is untouched — client traffic takes the same path in all four variants,
and replica-to-replica traffic still crosses the fan-out node.

**Narrowing the DUT to one core stopped meaning what it meant.**
`dut-cores.sh one` put everything the interface received on a single core,
which was right while the only thing arriving was cluster traffic to be routed.
With the clients here it is not: their replies are `XDP_PASS`es — an skb, the
UDP stack, a socket wakeup each — and a core shared with them saturates on the
clients while reporting it as the cost of duplicating. `dut-cores.sh fanout`
steers UDP/12000, the broadcast and nothing else, to queue 0 with an ntuple
rule, spreads the rest over queues 1..n-1, and moves the other queues'
interrupts off that core — the default assignment puts `comp1` on cpu 1 beside
`comp0`.

**And the measurement was of the wrong core.** `dut_busiest_pct` reported the
busiest core on the DUT, which with `DUT_REPLICA=1` is the local replica's:
`results16_in_comp` names cpu 3 — `DUT_REPLICA_CPU` — in 70 of the 72 rows of
each XDP point, and wanders elsewhere in the rest, which is the other half of
the complaint: it was not tracking any particular core. The
core to measure is the one taking the interface's completion interrupts, and
`run.sh` now diffs `/proc/interrupts` across the run to name it —
`fanout_cpu`, `fanout_busy_pct`, `fanout_softirq_pct`, and `fanout_irq_share`,
which says whether there was a single such core at all.

## How big the packet being duplicated is

Nothing in the benchmark ever asked. `BenchmarkClient::SendNext()` sends
`"request" << n`, a dozen bytes, and the replica runs with the default batch
size of one, so the PREPARE the fan-out node copies is **152 bytes on the
wire** — 42 of Ethernet, IP and UDP, 65 of `SerializeMessage()`'s framing (the
magic word, the 33-character type name, the twelve bytes Electrode's XDP half
reads, two lengths), and some forty-five of protobuf. The copy the non-inline
build makes is that plus the headroom, about 400 bytes of `memcpy`. That is the
second half of why `xdp` and `xdp-inline` come out the same here: not only does
the fan-out core have headroom, the thing the shared page saves is 400 bytes.

`--payload N` on `run.sh` and `sweep.sh` hangs N bytes of dead weight on the
PREPARE and on nothing else — the replicas take it as `ELECTRODE_PREPARE_PAD`,
`CloseBatch()` fills a `padding` field the followers ignore. The client's
requests and the replies stay the size they always were, so a sweep at two
paddings varies the duplicated packet and nothing else. At 1024 the PREPARE
arriving at a follower measures 1165 bytes on the wire, confirmed with
`tcpdump` inside `elec-r1`, and the null COMMITs beside it stay at 110.

The ceiling is the MTU, and the replica refuses a padding above 1200 bytes
rather than measure what happens past it: IP would fragment the PREPARE, and
the fan-out program recognises a broadcast by its UDP destination port, which
only the first fragment carries. The rest would go up the DUT's own stack and
the followers would simply stop hearing PREPARE.

The answer, from a sweep at 1024 over all five cluster sizes with one
repetition (`results_payload/`), is that **it changes nothing that can be
measured here**. Peak throughput against the baseline's, beside the archived
sweep at no padding (`results16_out_comp`, three repetitions, and only to 32
clients):

| replicas | TC, 0 B | TC, 1024 B | `xdp`, 0 B | `xdp`, 1024 B | inline, 0 B | inline, 1024 B |
|---|---|---|---|---|---|---|
| 3  | 1.02x | 1.05x | 1.13x | 1.20x | 1.14x | 1.21x |
| 7  | 1.23x | 1.25x | 1.69x | 1.72x | 1.69x | 1.74x |
| 15 | 1.34x | 1.36x | 2.07x | 2.07x | 2.08x | 2.05x |
| 31 | 1.46x | 1.45x | 2.30x | 2.25x | 2.30x | 2.27x |

Eight times the bytes on the duplicated packet, and the same ratios to within
the spread of a single repetition. What the offload takes off the leader is a
`sendto()` per follower, and that cost is per packet, not per byte, at any size
that fits in a frame. The two XDP points stay within 3% of each other in both
directions — 1.21x against 1.20x at three replicas, 2.05x against 2.07x at
fifteen — so the shared page still has nothing to show: the fan-out core peaks
at 18% busy, and what the inline build saves is a `memcpy` on a core that is
idle 82% of the time. That difference belongs to `microbenchmark/`, which
measures the node rather than the cluster.

Where the padding does show is the DUT as a whole. At 31 replicas the baseline
has it in softirq for 1.14 cores against the XDP points' 0.39, because the
baseline's thirty 1.2-kB frames cross it in both directions while the XDP
points' one does.

## Known limits

- **Namespaces, not machines.** The replicas share grecale's CPU, so the
  absolute throughput is not comparable with the paper's; the four variants are
  comparable with each other, which is what the experiment is for.
- **The fan-out node is nowhere near its limit here.** Maestrale's busiest core
  is 94-99% idle during a run, which is why `xdp` and `xdp-inline` come out the
  same: the shared page and the missing 320-byte memcpy are a saving on a
  resource nothing is competing for. That difference belongs to
  `microbenchmark/`, which measures the node itself.
- **Cluster sizes are odd.** Multi-Paxos wants 2f+1, so the sizes near thirty
  are 31 and 33, not 32.
- **Past fourteen replicas they share cores.** grecale has sixteen physical
  cores, `scripts/node.sh` gives the replicas fourteen of them and wraps, so at
  thirty-one most cores carry two. That is a property of running a thirty-one
  node cluster on one machine, not of any variant, and it is the same for all
  four — but it is why the absolute throughput falls away with the cluster
  size.
- **View changes are not handled**, upstream's own caveat. A run in which one
  happens is reported with `ok=0` rather than as a measurement.
- **The two machines did not agree on the MTU, and a replica that fell behind
  could never catch up.** grecale's interface and every macvlan on it were at
  9000; the DUT is at 1500. `UDPTransport` fragments only above
  `MAX_UDP_MESSAGE_SIZE`, which is 9000, so any message between the MTU and
  that — in practice the state transfer a straggler asks for — left grecale as
  one oversize frame, and since all replica-to-replica traffic is routed through
  the DUT, the DUT's NIC dropped it at the PHY. 50 such 9010-byte frames left
  the leader in one 25-second run and `rx_oversize_pkts_phy` on maestrale
  counted 104 (the other replicas send them too); in another run the leader sent
  29,586 of them, to a follower that was never going to receive one. The
  follower asks again, for ever. With three replicas a run survives one
  straggler and measures nothing when both fall behind: at 128 clients and 1024
  bytes of padding, four attempts out of six ended with the leader looping in
  `ResendPrepare` and every client completing zero requests. It was never a
  property of any variant — padding only makes a straggler more likely — and it
  is the real mechanism behind the state-transfer livelock at 31 replicas that
  `scripts/node.sh` warns about.

  **grecale was set to 1500 on 2026-09-22** (`sudo ip link set
  enp172s0f0np0 mtu 1500`; the macvlans follow the parent down). The kernel then
  fragments at 1500 instead, and the fragments cross the DUT because the fan-out
  program's routing half never looks at the UDP header — only the broadcast half
  does, and a broadcast is one frame. The point that had stalled four times out
  of six came back at 80.3 kops with the leader at 100% and no oversize frames
  at all, and the sweep in `results_payload/` is the first in this tree in which
  all 140 runs, 31 replicas included, are `ok=1`. Everything archived before
  that date was measured with the mismatch in place, so any run of theirs at 15
  or 31 replicas may have been carrying stragglers that were never coming back.
  The alternative fix, fragmenting below the DUT's MTU in
  `lib/udptransport.cc`, was not needed once the link agreed with itself; and
  the other experiments in the tree now see a 1500-byte grecale, which is a
  change to put back deliberately rather than to discover.
