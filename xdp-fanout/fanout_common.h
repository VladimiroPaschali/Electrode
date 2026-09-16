/* SPDX-License-Identifier: GPL-2.0 */
/* Shared between the fan-out BPF program and its loader. */
#ifndef __FANOUT_COMMON_H__
#define __FANOUT_COMMON_H__

#ifndef ETH_ALEN
#define ETH_ALEN 6
#endif

#define FANOUT_MAX_PEERS 32   /* 31 replicas is the largest odd cluster that fits here */

/* One cluster member, as the program needs it on the wire. */
struct fanout_peer {
  __u32 addr;           /* network order */
  __u16 port;           /* network order */
  __u8 eth[ETH_ALEN];
  __s32 idx;            /* its index among the replicas, or -1 if not one */
};

/* The scalars the program needs, in a map rather than in global data: one
 * loader then drives both builds of the object, with no skeleton per build,
 * and the lookup costs the same on either side of the comparison.
 */
struct fanout_cfg {
  __u32 n_replicas;   /* how many replicas the cluster has */
  /* The replica this node runs itself, if any.
   *
   * With one, a broadcast is XDP_CLONE_PASS: the original goes up this node's
   * own stack to its replica and the copies are transmitted to the rest. The
   * point is that the duplication point need not be a machine of its own --
   * the objection that XDP_CLONE costs an extra server is answered by the
   * server being a cluster member.
   *
   * What it gives up is the driver's shared-page path, which is gated on
   * XDP_CLONE_TX (en_rx.c:1831): the copies get a page and a byte copy each.
   * The WQE inline header still works, as it does in XuDP, which is built the
   * same way -- so the two builds still differ, by less.
   */
  __s32 local_idx;    /* replica index served here, or -1 */
  __u32 local_ip;     /* network order */
  __u16 local_port;   /* network order */
  __u32 fanout_ip;    /* network order: the address the leader sends to */
  __u16 fanout_port;  /* network order */
  __u8 self_mac[ETH_ALEN];
};

#endif /* __FANOUT_COMMON_H__ */
