/* SPDX-License-Identifier: GPL-2.0 */
/* Shared between the fan-out BPF program and its loader. */
#ifndef __FANOUT_COMMON_H__
#define __FANOUT_COMMON_H__

#ifndef ETH_ALEN
#define ETH_ALEN 6
#endif

#define FANOUT_MAX_PEERS 64

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
  __u32 fanout_ip;    /* network order: the address the leader sends to */
  __u16 fanout_port;  /* network order */
  __u8 self_mac[ETH_ALEN];
};

#endif /* __FANOUT_COMMON_H__ */
