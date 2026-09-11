# XDP_CLONE: the upstream Makefile compiled against a kernel-5.8 source tree
# fetched by kernel-src-download.sh, and linked the libbpf built inside it.
# Nothing here needs either: clang can compile a BPF object against the
# distribution's headers, and the loader links the distribution's libbpf.
#
#   make                                    broadcast offload only
#   make EXTRA_CFLAGS=-DCLUSTER_SIZE=5      2f+1 = 5
#   make EXTRA_CFLAGS=-DELECTRODE_XDP_OFFLOADS   also the two XDP offloads

TARGET := fast
KERN_OBJ := $(TARGET)_kern.o

CLANG ?= clang
CC := gcc

LIBBPF_CFLAGS := $(shell pkg-config --cflags libbpf)
LIBBPF_LDFLAGS := $(shell pkg-config --libs libbpf)

ARCH := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')

BPF_CFLAGS := -g -O2 -target bpf -D__TARGET_ARCH_$(ARCH) -I. $(LIBBPF_CFLAGS) \
              -Wall -Wno-unused-value -Wno-pointer-sign \
              -Wno-compare-distinct-pointer-types -Wno-address-of-packed-member

CFLAGS := -g -O2 -Wall -I. $(LIBBPF_CFLAGS)
LDFLAGS := $(LIBBPF_LDFLAGS) -lelf -lz

.PHONY: all clean

all: $(TARGET) $(KERN_OBJ)

$(KERN_OBJ): $(TARGET)_kern.c fast_common.h
	$(CLANG) $(BPF_CFLAGS) $(EXTRA_CFLAGS) -c $< -o $@

$(TARGET): $(TARGET)_user.c fast_common.h
	$(CC) $(CFLAGS) $(EXTRA_CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET) $(KERN_OBJ)
