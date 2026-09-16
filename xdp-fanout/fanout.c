/* SPDX-License-Identifier: GPL-2.0 */
/* Loader for the Electrode fan-out node.
 *
 * One binary drives both builds of the object -- the copy path and the
 * shared-page inline one -- because everything it configures lives in maps
 * rather than in the program's global data.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <net/if_arp.h>
#include <linux/if_packet.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "fanout_common.h"

static const char *ifname;
static const char *objpath = "fanout.bpf.o";
static const char *config_path = "../config.txt";
static const char *macs_path = "../config.macs";
static char fanout_spec[64] = "";
static char local_spec[64] = "";   /* -L <ip>:<port>: the replica served here */
static int local_idx = -1;         /* -I <index>: which replica that is */

static int ifindex;
static struct bpf_object *obj;
static volatile int attached;

/* Peers that are not replicas -- the client, above all. The fan-out node is
 * the router for them too, so it needs their MAC.
 */
#define MAX_EXTRA 16
static struct {
  __u32 addr;
  __u8 eth[ETH_ALEN];
} extra[MAX_EXTRA];
static int n_extra;

static void usage(const char *argv0) {
  fprintf(stderr,
          "usage: %s <ifname> -f <ip>:<port> [-o object.o] [-c config.txt]\n"
          "               [-m macs.txt] [-e <ip>=<mac>]...\n"
          "\n"
          "  -f  the address the leader broadcasts to, which this node fans out\n"
          "  -o  BPF object: fanout.bpf.o (copy path) or fanout_inline.bpf.o\n"
          "  -c  replica list, Electrode's config.txt format\n"
          "  -m  one MAC per line, in the order of that file\n"
          "  -e  a further host this node routes for, e.g. the client\n"
          "  -L  address of a replica this node runs itself, <ip>:<port>\n"
          "  -I  that replica's index in the configuration\n"
          "\n"
          "With -L/-I a broadcast becomes XDP_CLONE_PASS: the original goes up\n"
          "this node's own stack to its replica and the copies are transmitted\n"
          "to the rest, so the duplication point need not be a machine of its\n"
          "own. It gives up the driver's shared page, which is offered only for\n"
          "XDP_CLONE_TX; the WQE inline header still applies to every copy.\n",
          argv0);
  exit(EXIT_FAILURE);
}

static int parse_mac(const char *s, __u8 out[ETH_ALEN]) {
  unsigned int v[ETH_ALEN];

  if (sscanf(s, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6)
    return -1;
  for (int i = 0; i < ETH_ALEN; i++)
    out[i] = (__u8)v[i];
  return 0;
}

static void parse_cmdline(int argc, char *argv[]) {
  int opt;

  if (argc < 2 || argv[1][0] == '-')
    usage(argv[0]);
  ifname = argv[1];

  optind = 2;
  while ((opt = getopt(argc, argv, "f:o:c:m:e:L:I:")) != -1) {
    switch (opt) {
    case 'f':
      snprintf(fanout_spec, sizeof(fanout_spec), "%s", optarg);
      break;
    case 'o': objpath = optarg; break;
    case 'L': snprintf(local_spec, sizeof(local_spec), "%s", optarg); break;
    case 'I': local_idx = atoi(optarg); break;
    case 'c': config_path = optarg; break;
    case 'm': macs_path = optarg; break;
    case 'e': {
      char buf[64], *ip, *mac;

      if (n_extra == MAX_EXTRA) {
        fprintf(stderr, "Error: at most %d -e peers\n", MAX_EXTRA);
        exit(EXIT_FAILURE);
      }
      snprintf(buf, sizeof(buf), "%s", optarg);
      ip = strtok(buf, "=");
      mac = strtok(NULL, "=");
      if (!ip || !mac || inet_pton(AF_INET, ip, &extra[n_extra].addr) != 1 ||
          parse_mac(mac, extra[n_extra].eth)) {
        fprintf(stderr, "Error: -e wants <ip>=<mac>, got '%s'\n", optarg);
        exit(EXIT_FAILURE);
      }
      n_extra++;
      break;
    }
    default: usage(argv[0]);
    }
  }

  if (!fanout_spec[0])
    usage(argv[0]);

  ifindex = if_nametoindex(ifname);
  if (!ifindex) {
    fprintf(stderr, "Error: no interface %s\n", ifname);
    exit(EXIT_FAILURE);
  }
}

/* This node's own MAC: every frame it puts out is sourced from it, the way a
 * router would.
 */
static void read_self_mac(__u8 out[ETH_ALEN]) {
  struct ifreq ifr;
  int fd = socket(AF_INET, SOCK_DGRAM, 0);

  if (fd < 0) {
    perror("socket");
    exit(EXIT_FAILURE);
  }
  memset(&ifr, 0, sizeof(ifr));
  snprintf(ifr.ifr_name, IFNAMSIZ, "%s", ifname);
  if (ioctl(fd, SIOCGIFHWADDR, &ifr) < 0) {
    perror("SIOCGIFHWADDR");
    exit(EXIT_FAILURE);
  }
  close(fd);
  memcpy(out, ifr.ifr_hwaddr.sa_data, ETH_ALEN);
}

static void fill_maps(void) {
  int fd_replicas = bpf_object__find_map_fd_by_name(obj, "replicas");
  int fd_peers = bpf_object__find_map_fd_by_name(obj, "peer_by_ip");
  int fd_cfg = bpf_object__find_map_fd_by_name(obj, "cfg");
  struct fanout_cfg c;
  char buff[256], where[64], *ip, *port;
  __u32 key;
  FILE *fp, *fm;
  __u32 zero = 0;
  int f = 0, n;

  if (fd_replicas < 0 || fd_peers < 0 || fd_cfg < 0) {
    fprintf(stderr, "Error: the object is missing one of its maps\n");
    exit(EXIT_FAILURE);
  }

  fp = fopen(config_path, "r");
  fm = fopen(macs_path, "r");
  if (!fp || !fm) {
    fprintf(stderr, "Error: cannot open %s / %s: %s\n", config_path, macs_path,
            strerror(errno));
    exit(EXIT_FAILURE);
  }

  if (fscanf(fp, "%255s", buff) != 1 || strcmp(buff, "f") != 0 ||
      fscanf(fp, "%d", &f) != 1) {
    fprintf(stderr, "Error: %s does not start with 'f <n>'\n", config_path);
    exit(EXIT_FAILURE);
  }
  n = 2 * f + 1;
  if (n > FANOUT_MAX_PEERS) {
    fprintf(stderr, "Error: %d replicas, at most %d\n", n, FANOUT_MAX_PEERS);
    exit(EXIT_FAILURE);
  }
  for (int i = 0; i < n; ++i) {
    struct fanout_peer peer;
    struct in_addr in;

    if (fscanf(fp, "%255s", buff) != 1 || strcmp(buff, "replica") != 0 ||
        fscanf(fp, "%255s", buff) != 1) {
      fprintf(stderr, "Error: %s: replica %d is missing\n", config_path, i);
      exit(EXIT_FAILURE);
    }
    ip = strtok(buff, ":");
    port = strtok(NULL, ":");
    if (!ip || !port || inet_pton(AF_INET, ip, &in) != 1) {
      fprintf(stderr, "Error: %s: replica %d is not <ipv4>:<port>\n", config_path, i);
      exit(EXIT_FAILURE);
    }

    memset(&peer, 0, sizeof(peer));
    peer.addr = in.s_addr;
    peer.port = htons(atoi(port));
    peer.idx = i;

    /* Keep the text: the MAC is read into the same buffer next. */
    snprintf(where, sizeof(where), "%s:%s", ip, port);

    if (fscanf(fm, "%255s", buff) != 1 || parse_mac(buff, peer.eth)) {
      fprintf(stderr, "Error: %s: no MAC for replica %d\n", macs_path, i);
      exit(EXIT_FAILURE);
    }

    if (bpf_map_update_elem(fd_peers, &peer.addr, &peer, BPF_ANY)) {
      fprintf(stderr, "Error: peer_by_ip[%d]: %s\n", i, strerror(errno));
      exit(EXIT_FAILURE);
    }

    key = i;
    if (bpf_map_update_elem(fd_replicas, &key, &peer, BPF_ANY)) {
      fprintf(stderr, "Error: replicas[%d]: %s\n", i, strerror(errno));
      exit(EXIT_FAILURE);
    }
    printf("replica %d  %s\n", i, where);
  }
  fclose(fp);
  fclose(fm);

  for (int i = 0; i < n_extra; i++) {
    struct fanout_peer peer;

    memset(&peer, 0, sizeof(peer));
    peer.addr = extra[i].addr;
    peer.idx = -1; /* not a replica: a broadcast from here goes to them all */
    memcpy(peer.eth, extra[i].eth, ETH_ALEN);
    if (bpf_map_update_elem(fd_peers, &peer.addr, &peer, BPF_ANY)) {
      fprintf(stderr, "Error: peer_by_ip extra %d: %s\n", i, strerror(errno));
      exit(EXIT_FAILURE);
    }
  }

  memset(&c, 0, sizeof(c));
  c.n_replicas = n;
  c.local_idx = -1;
  if (local_spec[0]) {
    char buf[64], *lip, *lport;

    if (local_idx < 0 || local_idx >= n) {
      fprintf(stderr, "Error: -I wants an index in 0..%d\n", n - 1);
      exit(EXIT_FAILURE);
    }
    snprintf(buf, sizeof(buf), "%s", local_spec);
    lip = strtok(buf, ":");
    lport = strtok(NULL, ":");
    if (!lip || !lport || inet_pton(AF_INET, lip, &c.local_ip) != 1) {
      fprintf(stderr, "Error: -L wants <ipv4>:<port>\n");
      exit(EXIT_FAILURE);
    }
    c.local_port = htons(atoi(lport));
    c.local_idx = local_idx;
    printf("replica %d runs here, at %s:%s -- broadcasts are XDP_CLONE_PASS\n",
           local_idx, lip, lport);
  }
  ip = strtok(fanout_spec, ":");
  port = strtok(NULL, ":");
  if (!ip || !port || inet_pton(AF_INET, ip, &c.fanout_ip) != 1) {
    fprintf(stderr, "Error: -f wants <ipv4>:<port>\n");
    exit(EXIT_FAILURE);
  }
  c.fanout_port = htons(atoi(port));
  read_self_mac(c.self_mac);

  if (bpf_map_update_elem(fd_cfg, &zero, &c, BPF_ANY)) {
    fprintf(stderr, "Error: cfg: %s\n", strerror(errno));
    exit(EXIT_FAILURE);
  }

  printf("fan-out %s:%s -> every replica but the sender, %d of them, "
         "out of %s (%02x:%02x:%02x:%02x:%02x:%02x)\n",
         ip, port, n, ifname, c.self_mac[0], c.self_mac[1], c.self_mac[2],
         c.self_mac[3], c.self_mac[4], c.self_mac[5]);
}

static void on_signal(int sig) {
  (void)sig;
  if (attached)
    bpf_xdp_detach(ifindex, 0, NULL);
  printf("\ndetached\n");
  exit(0);
}

int main(int argc, char *argv[]) {
  struct rlimit r = {RLIM_INFINITY, RLIM_INFINITY};
  struct bpf_program *prog;
  int err;

  parse_cmdline(argc, argv);
  setrlimit(RLIMIT_MEMLOCK, &r);

  obj = bpf_object__open_file(objpath, NULL);
  if (!obj) {
    fprintf(stderr, "Error: cannot open %s: %s\n", objpath, strerror(errno));
    return 1;
  }
  if ((err = bpf_object__load(obj))) {
    fprintf(stderr, "Error: load %s failed: %s\n", objpath, strerror(-err));
    return 1;
  }

  prog = bpf_object__find_program_by_name(obj, "fanout");
  if (!prog) {
    fprintf(stderr, "Error: no program 'fanout' in %s\n", objpath);
    return 1;
  }

  fill_maps();

  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);

  if (bpf_xdp_attach(ifindex, bpf_program__fd(prog), 0, NULL)) {
    fprintf(stderr, "Error: XDP attach on %s: %s\n", ifname, strerror(errno));
    return 1;
  }
  attached = 1;
  /* The pid, so that whoever started this can stop exactly this process. A
   * pkill pattern would also match the shell that ran it.
   */
  printf("pid %d\nready\n", (int)getpid());
  fflush(stdout);

  pause();
  return 0;
}
