# needs clang, llvm-profdata (same llvm version) and llvm-bolt. debian and
# ubuntu only put suffixed names on PATH (clang-18, ...):
#   make LLVM_SUFFIX=-18
# or point at a directory: make LLVM_BIN=/usr/lib/llvm-18/bin/
LLVM_BIN ?=
LLVM_SUFFIX ?=
CC = $(LLVM_BIN)clang$(LLVM_SUFFIX)
PROFDATA = $(LLVM_BIN)llvm-profdata$(LLVM_SUFFIX)
# bolt only reads the finished binary, so it doesn't have to match clang's
# version - if there's no llvm-bolt$(LLVM_SUFFIX), take the newest
# llvm-bolt-NN on PATH. or set it: make BOLT_NAME=llvm-bolt-18
BOLT_NAME ?= $(or $(shell command -v $(LLVM_BIN)llvm-bolt$(LLVM_SUFFIX)), \
	$(shell IFS=:; for d in $$PATH; do ls "$$d"/llvm-bolt-[0-9]* 2>/dev/null; done | sort -V | tail -n 1), \
	$(LLVM_BIN)llvm-bolt$(LLVM_SUFFIX))
# run through its symlink, llvm-bolt looks for its instrumentation runtime
# in ../lib from there (/usr/lib on debian) instead of where it really is
# (/usr/lib/llvm-18/lib), so use the real path
BOLT := $(or $(realpath $(shell command -v $(BOLT_NAME))),$(BOLT_NAME))
# perf2bolt is llvm-bolt, and picks what to do from the name it was run as -
# run as perf2bolt-18 it quietly acts as llvm-bolt and writes a binary
# where the profile should be. -aggregate-only does the same job under any
# name.
PERF2BOLT = $(BOLT) -aggregate-only
PERF = perf

# no pie: bolt can't follow the pc-relative jump table a pie build makes for
# the switch, and silently leaves the whole interpreter alone. same flags
# for every binary so they only differ by the profile.
CFLAGS = -O2 -Wall -fno-pie
LDFLAGS = -no-pie
LDLIBS = -lm

NOPS = 128
NSTAGES = 8
COLD_LINES = 6

# instrumented runs are slow, and only need to see every branch a few times
TRAIN_ITERS = 20
# sampling needs a longer run to collect enough samples
PERF_ITERS = 1000

# how bolt gets its profile:
#   lbr    perf with branch records (-j any) - the real thing, needs hw
#          support (intel lbr, amd zen 4 + linux 6.1). not inside most vms.
#   nolbr  plain perf cycle samples - where time goes, not which way each
#          branch went. works anywhere perf does, gets about half the gain
#   instr  bolt instruments the binary itself, like -fprofile-generate.
#          exact counts, no perf needed
# default: lbr if this machine can do it, instr otherwise
BOLT_PROFILE ?= $(shell f=$$(mktemp); $(PERF) record -q -e cycles:u -j any,u -o $$f -- true >/dev/null 2>&1 && echo lbr || echo instr; rm -f $$f)
BOLT_OPTS = -reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions -split-all-cold -dyno-stats

WORKLOADS = A B

.DEFAULT_GOAL := all

ops.inc: gen_ops.py
	python3 gen_ops.py $(NOPS) $(NSTAGES) $(COLD_LINES)
ops.h: ops.inc

# --emit-relocs doesn't change the code, it just leaves bolt enough
# information to move it around
vm_base: vm.c ops.inc ops.h
	$(CC) $(CFLAGS) $(LDFLAGS) -Wl,--emit-relocs -o $@ vm.c $(LDLIBS)

vm_instr: vm.c ops.inc ops.h
	$(CC) $(CFLAGS) $(LDFLAGS) -fprofile-generate -o $@ vm.c $(LDLIBS)

%.profdata: vm_instr
	rm -f $*.profraw
	LLVM_PROFILE_FILE=$*.profraw ./vm_instr $* $(TRAIN_ITERS) >/dev/null
	$(PROFDATA) merge -o $@ $*.profraw

# trained on both workloads at once
AB.profdata: A.profdata B.profdata
	$(PROFDATA) merge -o $@ $^

vm_pgo_%: vm.c ops.inc ops.h %.profdata
	$(CC) $(CFLAGS) $(LDFLAGS) -fprofile-use=$*.profdata -o $@ vm.c $(LDLIBS)

ifeq ($(BOLT_PROFILE),instr)
%.fdata: vm_base
	rm -f $@
	$(BOLT) vm_base -instrument -instrumentation-file=$(CURDIR)/$@ -o vm_binst_$* >/dev/null
	./vm_binst_$* $* $(TRAIN_ITERS) >/dev/null
else ifeq ($(BOLT_PROFILE),lbr)
%.fdata: vm_base
	$(PERF) record -q -e cycles:u -j any,u -o $*.perf.data -- ./vm_base $* $(PERF_ITERS) >/dev/null
	$(PERF2BOLT) -p $*.perf.data -o $@ vm_base >/dev/null
else ifeq ($(BOLT_PROFILE),nolbr)
%.fdata: vm_base
	$(PERF) record -q -F 20000 -e cycles:u -o $*.perf.data -- ./vm_base $* $(PERF_ITERS) >/dev/null
	$(PERF2BOLT) -nl -p $*.perf.data -o $@ vm_base >/dev/null
else
$(error BOLT_PROFILE must be lbr, nolbr or instr)
endif

# bolt's own before/after summary (taken branches etc) ends up in the .log
vm_bolt_%: vm_base %.fdata
	$(BOLT) vm_base -o $@ -data=$*.fdata $(BOLT_OPTS) >$@.log 2>&1 || { cat $@.log; exit 1; }

pgo: vm_base $(WORKLOADS:%=vm_pgo_%) vm_pgo_AB
bolt: vm_base $(WORKLOADS:%=vm_bolt_%)
all: pgo bolt

clean:
	rm -f vm_base vm_instr vm_pgo_* vm_bolt_* vm_binst_* ops.inc ops.h \
		*.profraw *.profdata *.fdata *.perf.data *.perf.data.old

print-bolt-profile:
	@echo $(BOLT_PROFILE)

.PHONY: pgo bolt all clean print-bolt-profile
.PRECIOUS: %.profdata %.fdata
