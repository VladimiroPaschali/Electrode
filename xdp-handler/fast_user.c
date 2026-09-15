/*
 *  Software Name : fast-paxos
 *  SPDX-FileCopyrightText: Copyright (c) 2022 Orange
 *  SPDX-License-Identifier: LGPL-2.1-only
 *
 *  This software is distributed under the
 *  GNU Lesser General Public License v2.1 only.
 *
 *  Author: asd123www <wzz@pku.edu.cn> et al.
 *
 *  XDP_CLONE: ported from the libbpf that shipped inside a kernel-5.8 source
 *  tree to the distribution's libbpf 1.x. What went away with 1.0 and what
 *  stands in for it:
 *
 *    bpf_object__find_program_by_title()  ->  ..._by_name(), so programs are
 *                                             looked up by function name
 *    bpf_object__load_xattr()             ->  bpf_object__load()
 *    bpf_program__pin_instance()          ->  bpf_program__pin()
 *    bpf_set_link_xdp_fd()                ->  bpf_xdp_attach()
 *    tc(8) called through system()        ->  bpf_tc_hook_create/bpf_tc_attach
 *
 *  The replica MAC addresses were hardcoded in this file; they now come from a
 *  text file, one per replica, in the order of config.txt.
 */

#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

#include <linux/if_link.h>
#include <linux/limits.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "fast_common.h"

/* Where the pinned maps go.
 *
 * Not /sys/fs/bpf: `ip netns exec` gives each namespace a mount namespace of
 * its own and remounts /sys inside it, which shadows the bpffs the root
 * namespace has there. The pin fails, and a replica in another namespace could
 * not have found it anyway. A bpffs mounted somewhere else is inherited by
 * every namespace, and each replica gets a directory of its own because they
 * all pin the same names.
 */
static const char *electrode_bpf_dir(void) {
	const char *env = getenv("ELECTRODE_BPF_DIR");

	if (env)
		return env;
	return access("/run/bpf", F_OK) == 0 ? "/run/bpf" : "/sys/fs/bpf";
}

static const char *electrode_pin(const char *name) {
	static char buf[4][256];
	static int n;
	char *b = buf[n++ & 3];

	snprintf(b, sizeof(buf[0]), "%s/%s", electrode_bpf_dir(), name);
	return b;
}

static const char *ifname;
static const char *config_path = "../config.txt";
static const char *macs_path = "../config.macs";
static int leader_idx = 0;
static int want_xdp = 0;   /* -x: attach the XDP offloads too */
static int want_tc = 1;    /* -T: leave the TC broadcast alone */

static int ifindex;
static struct bpf_object *obj;
static struct bpf_tc_hook tc_hook;
static struct bpf_tc_opts tc_opts;
static int tc_attached;

#ifdef ELECTRODE_XDP_OFFLOADS
static int xdp_attached;
static __u32 xdp_mode;
#endif

/* Same layout as the map value in fast_kern.c. */
struct paxos_ctr_state {
	enum ReplicaStatus state;
	int myIdx, leaderIdx, batchSize;
	__u64 view, lastOp;
};

static void usage(const char *argv0) {
	fprintf(stderr,
	        "usage: %s <ifname> [-c config.txt] [-m macs.txt] [-l leaderIdx]\n"
	        "\n"
	        "  -c  replica list, Electrode's own config.txt format\n"
	        "  -m  one MAC address per line, in the order of that file\n"
	        "  -l  index of the leader replica (default 0)\n",
	        argv0);
	exit(EXIT_FAILURE);
}

static void parse_cmdline(int argc, char *argv[]) {
	int opt;

	if (argc < 2 || argv[1][0] == '-')
		usage(argv[0]);
	ifname = argv[1];

	optind = 2;
	while ((opt = getopt(argc, argv, "c:m:l:xT")) != -1) {
		switch (opt) {
		case 'c': config_path = optarg; break;
		case 'm': macs_path = optarg; break;
		case 'l': leader_idx = atoi(optarg); break;
		case 'x': want_xdp = 1; break;
		case 'T': want_tc = 0; break;
		default: usage(argv[0]);
		}
	}

	ifindex = if_nametoindex(ifname);
	if (!ifindex) {
		fprintf(stderr, "Error: no interface %s\n", ifname);
		exit(EXIT_FAILURE);
	}
}

/* config.txt is Electrode's own:
 *
 *     f <number of failures tolerated>
 *     replica <host>:<port>
 *     ...
 *
 * and the MAC file carries one address per line in the same order. Both are
 * read here so that the eBPF side agrees with the replicas on who is who.
 */
static void read_config(void) {
	int map_fd = bpf_object__find_map_fd_by_name(obj, "map_configure");
	FILE *fp, *fm = NULL;
	char buff[256];
	int f = 0, n;

	if (map_fd < 0) {
		fprintf(stderr, "Error: no map_configure in the object\n");
		exit(EXIT_FAILURE);
	}

	fp = fopen(config_path, "r");
	if (!fp) {
		fprintf(stderr, "Error: cannot open %s: %s\n", config_path, strerror(errno));
		exit(EXIT_FAILURE);
	}
	fm = fopen(macs_path, "r");
	if (!fm) {
		fprintf(stderr, "Error: cannot open %s: %s\n", macs_path, strerror(errno));
		exit(EXIT_FAILURE);
	}

	if (fscanf(fp, "%255s", buff) != 1 || strcmp(buff, "f") != 0 ||
	    fscanf(fp, "%d", &f) != 1) {
		fprintf(stderr, "Error: %s does not start with 'f <n>'\n", config_path);
		exit(EXIT_FAILURE);
	}

	n = 2 * f + 1;
	if (n > FAST_REPLICA_MAX) {
		fprintf(stderr, "Error: %d replicas, at most %d\n", n, FAST_REPLICA_MAX);
		exit(EXIT_FAILURE);
	}
	if (n != CLUSTER_SIZE) {
		fprintf(stderr,
		        "Error: %s describes %d replicas but this object was built with "
		        "CLUSTER_SIZE=%d. Rebuild with EXTRA_CFLAGS=-DCLUSTER_SIZE=%d.\n",
		        config_path, n, CLUSTER_SIZE, n);
		exit(EXIT_FAILURE);
	}

	for (int i = 0; i < n; ++i) {
		struct paxos_configure conf;
		struct sockaddr_in sa;
		unsigned int eth[ETH_ALEN];
		char *ipv4, *port;

		if (fscanf(fp, "%255s", buff) != 1 || strcmp(buff, "replica") != 0 ||
		    fscanf(fp, "%255s", buff) != 1) {
			fprintf(stderr, "Error: %s: replica %d is missing\n", config_path, i);
			exit(EXIT_FAILURE);
		}
		ipv4 = strtok(buff, ":");
		port = strtok(NULL, ":");
		if (!ipv4 || !port) {
			fprintf(stderr, "Error: %s: replica %d is not host:port\n", config_path, i);
			exit(EXIT_FAILURE);
		}
		if (inet_pton(AF_INET, ipv4, &sa.sin_addr) != 1) {
			fprintf(stderr, "Error: %s: replica %d has no IPv4 address (%s)\n",
			        config_path, i, ipv4);
			exit(EXIT_FAILURE);
		}

		if (fscanf(fm, "%x:%x:%x:%x:%x:%x", &eth[0], &eth[1], &eth[2], &eth[3],
		           &eth[4], &eth[5]) != 6) {
			fprintf(stderr, "Error: %s: no MAC for replica %d\n", macs_path, i);
			exit(EXIT_FAILURE);
		}

		memset(&conf, 0, sizeof(conf));
		conf.addr = sa.sin_addr.s_addr;
		conf.port = htons(atoi(port));
		for (int j = 0; j < ETH_ALEN; ++j)
			conf.eth[j] = (char)eth[j];

		if (bpf_map_update_elem(map_fd, &i, &conf, 0)) {
			fprintf(stderr, "Error: map_configure[%d]: %s\n", i, strerror(errno));
			exit(EXIT_FAILURE);
		}
		printf("replica %d  %s:%s  %02x:%02x:%02x:%02x:%02x:%02x%s\n", i, ipv4, port,
		       eth[0], eth[1], eth[2], eth[3], eth[4], eth[5],
		       i == leader_idx ? "  (leader)" : "");
	}

	fclose(fp);
	fclose(fm);
}

/* FastBroadCast reads leaderIdx out of this map to know which replica to skip.
 * Upstream it is written by the replica's ModifyKernelState(), which only runs
 * with FAST_REPLY / FAST_QUORUM_PRUNE / FAST_BATCH compiled in. With the
 * broadcast offload alone nothing would ever write it, so it is seeded here.
 */
static void seed_ctr_state(void) {
	int map_fd = bpf_object__find_map_fd_by_name(obj, "map_ctr_state");
	struct paxos_ctr_state st;
	__u32 key = 0;

	if (map_fd < 0) {
		fprintf(stderr, "Error: no map_ctr_state in the object\n");
		exit(EXIT_FAILURE);
	}

	memset(&st, 0, sizeof(st));
	st.state = STATUS_NORMAL;
	st.leaderIdx = leader_idx;
	st.myIdx = leader_idx;

	if (bpf_map_update_elem(map_fd, &key, &st, 0)) {
		fprintf(stderr, "Error: map_ctr_state: %s\n", strerror(errno));
		exit(EXIT_FAILURE);
	}
}

static void detach(void) {
	if (tc_attached) {
		tc_opts.flags = tc_opts.prog_fd = tc_opts.prog_id = 0;
		bpf_tc_detach(&tc_hook, &tc_opts);
		/* Leave the clsact qdisc alone if something else put it there. */
		bpf_tc_hook_destroy(&tc_hook);
		tc_attached = 0;
	}
#ifdef ELECTRODE_XDP_OFFLOADS
	if (xdp_attached) {
		bpf_xdp_detach(ifindex, xdp_mode, NULL);
		xdp_attached = 0;
	}
#endif
}

static void on_signal(int sig) {
	(void)sig;
	detach();
	printf("\ndetached, quitting safely\n");
	exit(0);
}

int main(int argc, char *argv[]) {
	struct rlimit r = {RLIM_INFINITY, RLIM_INFINITY};
	struct bpf_program *tc_prog;
	char objname[PATH_MAX];
	int err;

	parse_cmdline(argc, argv);
	setrlimit(RLIMIT_MEMLOCK, &r);

	snprintf(objname, sizeof(objname), "%s_kern.o", argv[0]);
	obj = bpf_object__open(objname);
	if (!obj) {
		fprintf(stderr, "Error: cannot open %s: %s\n", objname, strerror(errno));
		return 1;
	}

	/* SEC("FastBroadCast") is not a name libbpf knows, so the type has to be
	 * set by hand before the load -- as it was upstream.
	 */
	tc_prog = bpf_object__find_program_by_name(obj, "FastBroadCast_main");
	if (!tc_prog) {
		fprintf(stderr, "Error: no FastBroadCast_main in %s\n", objname);
		return 1;
	}
	bpf_program__set_type(tc_prog, BPF_PROG_TYPE_SCHED_CLS);

#ifdef ELECTRODE_XDP_OFFLOADS
	/* Only what this build actually contains: HandleRequest belongs to the
	 * batching offload and WriteBuffer/PrepareFastReply to the fast reply.
	 */
	static const char *xdp_names[] = {
	    "fastPaxos_main", "HandlePrepare_main", "HandlePrepareOK_main",
#ifdef FAST_BATCH
	    "HandleRequest_main",
#endif
#ifdef FAST_REPLY
	    "WriteBuffer_main", "PrepareFastReply_main",
#endif
	};
	struct bpf_program *xdp_progs[sizeof(xdp_names) / sizeof(xdp_names[0])];

	for (size_t i = 0; i < sizeof(xdp_names) / sizeof(xdp_names[0]); i++) {
		xdp_progs[i] = bpf_object__find_program_by_name(obj, xdp_names[i]);
		if (!xdp_progs[i]) {
			fprintf(stderr, "Error: no %s in %s\n", xdp_names[i], objname);
			return 1;
		}
		bpf_program__set_type(xdp_progs[i], BPF_PROG_TYPE_XDP);
	}
#endif

	if ((err = bpf_object__load(obj))) {
		fprintf(stderr, "Error: load failed: %s\n", strerror(-err));
		return 1;
	}

	read_config();
	seed_ctr_state();

#ifdef ELECTRODE_XDP_OFFLOADS
	if (want_xdp) {
		int map_xdp = bpf_object__find_map_fd_by_name(obj, "map_progs_xdp");
		static const int idx[] = {-1, FAST_PROG_XDP_HANDLE_PREPARE,
		                          FAST_PROG_XDP_HANDLE_PREPAREOK,
#ifdef FAST_BATCH
		                          FAST_PROG_XDP_HANDLE_REQUEST,
#endif
#ifdef FAST_REPLY
		                          FAST_PROG_XDP_WRITE_BUFFER,
		                          FAST_PROG_XDP_PREPARE_REPLY,
#endif
		};

		for (size_t i = 1; i < sizeof(idx) / sizeof(idx[0]); i++) {
			int fd = bpf_program__fd(xdp_progs[i]);
			__u32 k = idx[i];

			if (bpf_map_update_elem(map_xdp, &k, &fd, 0)) {
				fprintf(stderr, "Error: map_progs_xdp[%u]: %s\n", k, strerror(errno));
				return 1;
			}
		}

#ifdef FAST_REPLY
		assert(bpf_obj_pin(bpf_object__find_map_fd_by_name(obj, "map_prepare_buffer"),
		                   electrode_pin("paxos_prepare_buffer")) == 0);
#endif
#ifdef FAST_BATCH
		assert(bpf_obj_pin(bpf_object__find_map_fd_by_name(obj, "map_request_buffer"),
		                   electrode_pin("paxos_request_buffer")) == 0);
#endif
		/* The replica reads leaderIdx and the quorum state from here. */
		assert(bpf_obj_pin(bpf_object__find_map_fd_by_name(obj, "map_ctr_state"),
		                   electrode_pin("paxos_ctr_state")) == 0);

		/* Native first, then generic. Upstream only ever asked for native,
		 * which a macvlan cannot do -- and a macvlan is what a replica has
		 * when the cluster is a set of network namespaces on one machine.
		 * Generic XDP runs after the skb is built, so it does not save the
		 * allocation; it still takes the datagram before the socket queue,
		 * the recvfrom and the protobuf parse, which is what this offload is
		 * for.
		 */
		xdp_mode = XDP_FLAGS_DRV_MODE;
		if (bpf_xdp_attach(ifindex, bpf_program__fd(xdp_progs[0]), xdp_mode, NULL)) {
			xdp_mode = XDP_FLAGS_SKB_MODE;
			if (bpf_xdp_attach(ifindex, bpf_program__fd(xdp_progs[0]), xdp_mode, NULL)) {
				fprintf(stderr, "Error: XDP attach on %s: %s\n", ifname,
				        strerror(errno));
				return 1;
			}
		}
		xdp_attached = 1;
		printf("XDP attached to %s (%s mode)\n", ifname,
		       xdp_mode == XDP_FLAGS_DRV_MODE ? "native" : "generic");
	}
#endif

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	if (!want_tc) {
		printf("pid %d\nready\n", (int)getpid());
		fflush(stdout);
		pause();
		detach();
		return 0;
	}

	memset(&tc_hook, 0, sizeof(tc_hook));
	tc_hook.sz = sizeof(tc_hook);
	tc_hook.ifindex = ifindex;
	tc_hook.attach_point = BPF_TC_EGRESS;

	err = bpf_tc_hook_create(&tc_hook);
	if (err && err != -EEXIST) {
		fprintf(stderr, "Error: clsact on %s: %s\n", ifname, strerror(-err));
		return 1;
	}

	memset(&tc_opts, 0, sizeof(tc_opts));
	tc_opts.sz = sizeof(tc_opts);
	tc_opts.prog_fd = bpf_program__fd(tc_prog);
	if ((err = bpf_tc_attach(&tc_hook, &tc_opts))) {
		fprintf(stderr, "Error: TC egress attach on %s: %s\n", ifname, strerror(-err));
		return 1;
	}
	tc_attached = 1;
	printf("FastBroadCast attached to TC egress on %s\n", ifname);
	printf("ready\n");
	fflush(stdout);

	pause();
	detach();
	return 0;
}
