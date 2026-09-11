# The fan-out node. Two builds of the same source:
#
#   fanout.bpf.o         a page and a header rewrite per copy
#   fanout_inline.bpf.o  the descriptor stamped on the original, so the driver
#                        emits every frame from the one RX page and each copy's
#                        header reaches the NIC as the WQE inline header
#
# axdp_tx.h is the BPF side of that descriptor's ABI; the copy here is the one
# from mellanox-clone-xdp/examples/inline-clone, which documents it.

CLANG ?= clang
CC := gcc

LIBBPF_CFLAGS := $(shell pkg-config --cflags libbpf)
LIBBPF_LDFLAGS := $(shell pkg-config --libs libbpf)

BPF_CFLAGS := -g -O2 -target bpf -I. $(LIBBPF_CFLAGS) -Wall \
              -Wno-address-of-packed-member -Wno-compare-distinct-pointer-types

.PHONY: all clean

all: fanout fanout.bpf.o fanout_inline.bpf.o

fanout.bpf.o: fanout.bpf.c fanout_common.h axdp_tx.h
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

fanout_inline.bpf.o: fanout.bpf.c fanout_common.h axdp_tx.h
	$(CLANG) $(BPF_CFLAGS) -DAXDP_INLINE -c $< -o $@

fanout: fanout.c fanout_common.h
	$(CC) -g -O2 -Wall -I. $(LIBBPF_CFLAGS) -o $@ $< $(LIBBPF_LDFLAGS)

clean:
	rm -f fanout fanout.bpf.o fanout_inline.bpf.o
