/* SPDX-License-Identifier: GPL-2.0 */
/* The intermediate fan-out node for Electrode on the XDP_CLONE driver.
 *
 * Why it exists. Electrode's broadcast offload (SEC("FastBroadCast") in
 * ../xdp-handler/fast_kern.c) is a *TC egress* program on the leader: the
 * leader sends one packet and bpf_clone_redirect() re-injects a clone into its
 * own egress path, once per follower. XDP cannot do that -- a locally
 * generated packet never passes an XDP hook -- so the duplication has to
 * happen on a machine the packet *arrives* at. That is this program: the
 * leader sends one packet to the fan-out address, and the copies leave here.
 *
 * The same program is also the plain router for every other packet in the
 * cluster, so that the baseline and the TC variant traverse exactly the same
 * hops as the two XDP ones and only the number of packets on the wire differs.
 *
 * Two builds out of this file:
 *
 *   (default)      each copy gets its own page and its headers are rewritten
 *                  in place, the way XDP has always done it;
 *   -DAXDP_INLINE  the descriptor is stamped on the original, which puts the
 *                  driver on its shared-page path: all n+1 frames leave from
 *                  the one RX page, and each copy's 42-byte L2/L3/L4 header is
 *                  handed to the NIC as the WQE inline header instead of being
 *                  written into the packet. Nothing in the packet is touched,
 *                  which is exactly what that path requires.
 */
#define BPF_NO_GLOBAL_DATA
#include <linux/bpf.h>

#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>

#include "axdp_tx.h"
#include "fanout_common.h"

#define __XDP_CLONE_PASS 5
#define __XDP_CLONE_TX 6
#define XDP_CLONE_PASS(num_copy) (((int)(num_copy) << 5) | (int)__XDP_CLONE_PASS)
#define XDP_CLONE_TX(num_copy) (((int)(num_copy) << 5) | (int)__XDP_CLONE_TX)

/* Every replica, in the order of the configuration file. */
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __type(key, __u32);
  __type(value, struct fanout_peer);
  __uint(max_entries, FANOUT_MAX_PEERS);
} replicas SEC(".maps");

/* Every address in the cluster, for the routing half of the job. */
struct {
  __uint(type, BPF_MAP_TYPE_HASH);
  __type(key, __u32);
  __type(value, struct fanout_peer);
  __uint(max_entries, FANOUT_MAX_PEERS * 4);
} peer_by_ip SEC(".maps");

/* Written by the loader before the attach. */
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __type(key, __u32);
  __type(value, struct fanout_cfg);
  __uint(max_entries, 1);
} cfg SEC(".maps");

static __always_inline __u16 ip_checksum(struct iphdr *ip) {
  __u32 sum = 0;
  __u16 *w = (__u16 *)ip;

#pragma unroll
  for (int i = 0; i < 10; i++) {
    if (i == 5)
      continue; /* the checksum field itself */
    sum += bpf_ntohs(w[i]);
  }
  while (sum >> 16)
    sum = (sum & 0xFFFF) + (sum >> 16);

  return bpf_htons(~sum);
}

struct hdrs {
  struct ethhdr *eth;
  struct iphdr *ip;
  struct udphdr *udp;
};

/* Ethernet and IPv4 only: enough to route by destination address. */
static __always_inline int parse_ip(struct xdp_md *ctx, struct hdrs *h) {
  void *data = (void *)(long)ctx->data;
  void *data_end = (void *)(long)ctx->data_end;

  h->eth = data;
  if ((void *)(h->eth + 1) > data_end)
    return -1;
  if (h->eth->h_proto != bpf_htons(ETH_P_IP))
    return -1;

  h->ip = (void *)(h->eth + 1);
  if ((void *)(h->ip + 1) > data_end)
    return -1;
  /* The 42-byte header the inline build replaces assumes no IP options. */
  if (h->ip->ihl != 5)
    return -1;

  h->udp = 0;
  return 0;
}

/* ...and the UDP header on top, which only the fan-out half needs. */
static __always_inline int parse_udp(struct xdp_md *ctx, struct hdrs *h) {
  void *data_end = (void *)(long)ctx->data_end;

  if (h->ip->protocol != IPPROTO_UDP)
    return -1;

  h->udp = (void *)h->ip + sizeof(struct iphdr);
  if ((void *)(h->udp + 1) > data_end)
    return -1;

  return 0;
}

#ifndef AXDP_INLINE

/* Rewrite the frame's first 42 bytes in place and transmit. The source address
 * and port are left alone on purpose: the follower answers the PrepareOK to
 * whoever the packet says it came from, and that has to stay the leader.
 */
static __always_inline int send_to(struct xdp_md *ctx, struct hdrs *h,
                                   const struct fanout_peer *peer,
                                   const struct fanout_cfg *c) {
  __builtin_memcpy(h->eth->h_source, c->self_mac, ETH_ALEN);
  __builtin_memcpy(h->eth->h_dest, peer->eth, ETH_ALEN);

  h->udp->dest = peer->port;
  h->udp->check = 0;

  h->ip->daddr = peer->addr;
  h->ip->check = ip_checksum(h->ip);

  return XDP_TX;
}

#else /* AXDP_INLINE */

#define FANOUT_HDR_LEN (ETH_HLEN + sizeof(struct iphdr) + sizeof(struct udphdr))
#define FANOUT_META_NEED (((AXDP_TX_DESC_LEN + FANOUT_HDR_LEN) + 3) & ~3U)

/* Build the outgoing 42-byte header in this run's own metadata and hand it to
 * the NIC as the WQE inline header, replacing the packet's first 42 bytes,
 * which the driver then leaves out of the DMA. The packet itself is never
 * written to -- the requirement that comes with the shared page, since all the
 * frames of the batch point at it and the DMA is asynchronous.
 *
 * @cur_meta is how wide the metadata is on entry: nothing on an original, four
 * bytes on a copy. It is a constant at both call sites deliberately; a
 * bpf_xdp_adjust_meta() with a variable delta leaves the metadata unknown to
 * the patched verifier, which then refuses the clone action.
 */
static __always_inline int send_to_inline(struct xdp_md *ctx, struct hdrs *h,
                                          const struct fanout_peer *peer,
                                          const struct fanout_cfg *c,
                                          __u32 cur_meta) {
  /* Separately aligned locals rather than one byte buffer: overlaying them
   * puts the IP header at an odd stack offset and the verifier rejects the
   * misaligned access.
   */
  struct ethhdr e;
  struct iphdr ip;
  struct udphdr udp;
  void *meta;

  __builtin_memcpy(&e, h->eth, sizeof(e));
  __builtin_memcpy(&ip, h->ip, sizeof(ip));
  __builtin_memcpy(&udp, h->udp, sizeof(udp));

  __builtin_memcpy(e.h_source, c->self_mac, ETH_ALEN);
  __builtin_memcpy(e.h_dest, peer->eth, ETH_ALEN);

  udp.dest = peer->port;
  udp.check = 0;

  ip.daddr = peer->addr;
  ip.check = ip_checksum(&ip);

  if (bpf_xdp_adjust_meta(ctx, -(int)(FANOUT_META_NEED - cur_meta)))
    return XDP_DROP;

  /* Every pointer taken before that call is stale. */
  meta = (void *)(long)ctx->data_meta;
  if (meta + FANOUT_META_NEED > (void *)(long)ctx->data)
    return XDP_DROP;

  meta += AXDP_TX_DESC_LEN;
  __builtin_memcpy(meta, &e, sizeof(e));
  __builtin_memcpy(meta + ETH_HLEN, &ip, sizeof(ip));
  __builtin_memcpy(meta + ETH_HLEN + sizeof(struct iphdr), &udp, sizeof(udp));

  if (axdp_stamp_tx_replace(ctx, 0, FANOUT_HDR_LEN))
    return XDP_DROP;

  return XDP_TX;
}

#endif /* AXDP_INLINE */

/* Who this batch is for: every replica except whoever sent it.
 *
 * A broadcast goes to all the replicas the sender is not. The leader's PREPARE
 * therefore reaches the followers, and the client's request -- VRClient
 * ::SendRequest() sends every request with SendMessageToAll(), not just the
 * retries -- reaches all three, the leader included. Excluding the *leader*
 * instead would have been the obvious reading of Electrode's TC program, and
 * it silently drops every client request on the floor.
 *
 * @k runs 0 for the original and 1..count-1 for the copies; the sender's own
 * slot is skipped by shifting everything at or after it up by one.
 */
/* The k-th replica that is neither @skip1 nor @skip2, as an index.
 *
 * Two skips rather than one because a node that serves a replica of its own
 * takes that one with the original and leaves the rest to the copies: the
 * sender is skipped because a broadcast is not sent back to its author, and
 * the local replica because it is already served.
 */
static __always_inline int nth_other(const struct fanout_cfg *c, __u32 k,
                                     __s32 skip1, __s32 skip2) {
  __u32 seen = 0;

#pragma clang loop unroll(disable)
  for (int i = 0; i < FANOUT_MAX_PEERS; i++) {
    if ((__u32)i >= c->n_replicas)
      break;
    if (i == skip1 || i == skip2)
      continue;
    if (seen == k)
      return i;
    seen++;
  }
  return -1;
}

static __always_inline struct fanout_peer *peer_at(int idx) {
  __u32 key = idx;

  if (idx < 0)
    return 0;
  return bpf_map_lookup_elem(&replicas, &key);
}

/* The sender's replica index, or -1 if it is not a replica. The source address
 * is never rewritten -- a follower has to answer the leader, not this node --
 * so it is still there on every copy.
 */
static __always_inline __s32 sender_idx(struct iphdr *ip) {
  struct fanout_peer *p = bpf_map_lookup_elem(&peer_by_ip, &ip->saddr);

  return p ? p->idx : -1;
}

SEC("xdp")
int fanout(struct xdp_md *ctx) {
  void *data = (void *)(long)ctx->data;
  void *data_meta = (void *)(long)ctx->data_meta;
  struct fanout_peer *peer;
  struct fanout_cfg *c;
  struct hdrs h;
  __u32 zero = 0;

  c = bpf_map_lookup_elem(&cfg, &zero);
  if (!c)
    return XDP_ABORTED;

  /* A copy carries its 1-based index in the four bytes in front of the data.
   * Every exit of this block is a plain action: the clone action below has to
   * stay reachable only from the branch where that metadata is absent, or the
   * patched verifier turns the program down as a nested clone.
   */
  if (data_meta + AXDP_CLONE_META_SIZE <= data) {
    __u32 idx = *(__u32 *)data_meta;

    if (idx == 0 || idx >= c->n_replicas)
      return XDP_DROP;
    if (parse_ip(ctx, &h) || parse_udp(ctx, &h))
      return XDP_DROP;

    /* Copy k serves the k-th destination the original did not. Where this node
     * runs a replica, the original went to it, so the copies start one along.
     */
    peer = peer_at(nth_other(c, c->local_idx >= 0 ? idx - 1 : idx,
                             sender_idx(h.ip), c->local_idx));
    if (!peer)
      return XDP_DROP;

#ifndef AXDP_INLINE
    return send_to(ctx, &h, peer, c);
#else
    return send_to_inline(ctx, &h, peer, c, AXDP_CLONE_META_SIZE);
#endif
  }

  /* An original. Anything that is not IPv4 for a host this node routes for
   * goes up its own stack untouched -- ARP, ssh, whatever shares the link.
   */
  if (parse_ip(ctx, &h))
    return XDP_PASS;

  if (h.ip->daddr == c->fanout_ip && !parse_udp(ctx, &h) &&
      h.udp->dest == c->fanout_port) {
    /* The broadcast. One packet in, one per recipient out. */
    __s32 from = sender_idx(h.ip);
    __u32 count = c->n_replicas - (from >= 0 ? 1 : 0);
    int local_is_a_recipient = c->local_idx >= 0 && c->local_idx != from;

    if (count == 0)
      return XDP_DROP;

    if (local_is_a_recipient) {
      /* The original is this node's own copy: readdress it to the replica here
       * and let it up the stack, and the clones take the rest.
       *
       * This is the path that gives up the driver's shared page -- offered
       * only for XDP_CLONE_TX -- and keeps the WQE inline header, which every
       * copy still stamps for itself. XuDP is built the same way.
       */
      h.udp->dest = c->local_port;
      h.udp->check = 0;
      h.ip->daddr = c->local_ip;
      h.ip->check = ip_checksum(h.ip);

      if (count == 1)
        return XDP_PASS;

      return XDP_CLONE_PASS(count - 1);
    }

    peer = peer_at(nth_other(c, 0, from, c->local_idx));
    if (!peer)
      return XDP_DROP;

#ifndef AXDP_INLINE
    if (send_to(ctx, &h, peer, c) != XDP_TX)
      return XDP_DROP;
#else
    if (send_to_inline(ctx, &h, peer, c, 0) != XDP_TX)
      return XDP_DROP;
#endif

    /* A single recipient is a plain transmission: XDP_CLONE_TX(0) puts the
     * driver through the whole clone tail for no copy at all.
     */
    if (count == 1)
      return XDP_TX;

    return XDP_CLONE_TX(count - 1);
  }

  /* Addressed to the replica this node runs: up its own stack, not routed. */
  if (c->local_idx >= 0 && h.ip->daddr == c->local_ip)
    return XDP_PASS;

  /* Everything else in the cluster: route it on to its destination, so that
   * the baseline and the TC variant cross this node exactly like the two XDP
   * ones do.
   */
  peer = bpf_map_lookup_elem(&peer_by_ip, &h.ip->daddr);
  if (!peer)
    return XDP_PASS;

  __builtin_memcpy(h.eth->h_source, c->self_mac, ETH_ALEN);
  __builtin_memcpy(h.eth->h_dest, peer->eth, ETH_ALEN);
  return XDP_TX;
}

char LICENSE[] SEC("license") = "GPL";
