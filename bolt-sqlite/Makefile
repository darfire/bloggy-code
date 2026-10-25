# sqlite's own benchmark (speedtest1) on sqlite, built plain, with pgo, and
# with bolt - each profile-guided one trained on one of speedtest1's test
# sets. same tools and gotchas as ../pgo-dispatch, see its Makefile.
#   make LLVM_SUFFIX=-18
LLVM_BIN ?=
LLVM_SUFFIX ?=
CC = $(LLVM_BIN)clang$(LLVM_SUFFIX)
PROFDATA = $(LLVM_BIN)llvm-profdata$(LLVM_SUFFIX)
BOLT_NAME ?= $(or $(shell command -v $(LLVM_BIN)llvm-bolt$(LLVM_SUFFIX)), \
	$(shell IFS=:; for d in $$PATH; do ls "$$d"/llvm-bolt-[0-9]* 2>/dev/null; done | sort -V | tail -n 1), \
	$(LLVM_BIN)llvm-bolt$(LLVM_SUFFIX))
BOLT := $(or $(realpath $(shell command -v $(BOLT_NAME))),$(BOLT_NAME))
PERF2BOLT = $(BOLT) -aggregate-only
PERF = perf

VERSION = 3540100
AMALG = src/sqlite-amalgamation-$(VERSION)

# sqlite's bytecode engine (sqlite3VdbeExec) is one big switch, so the same
# deal as the toy: no pie, or bolt can't follow its jump table
CFLAGS = -O2 -Wall -fno-pie -DSQLITE_THREADSAFE=0 -I$(AMALG)
LDFLAGS = -no-pie
LDLIBS = -lm
SRCS = src/speedtest1.c $(AMALG)/sqlite3.c

# test sets used for training, and how big a run of each one is
TRAIN = main cte
# and both of them, profiles merged
MERGED = main+cte
SIZE_main = 100
SIZE_orm = 300
SIZE_cte = 200
SIZE_fp = 100
# training only needs to see every path a few times
TRAIN_SCALE = 4
RUN = --memdb --testset $(1) --size $$(( $(SIZE_$(1)) / $(2) ))

# lbr: perf branch records, instr: bolt's own instrumentation. see
# ../pgo-dispatch/Makefile
BOLT_PROFILE ?= $(shell f=$$(mktemp); $(PERF) record -q -e cycles:u -j any,u -o $$f -- true >/dev/null 2>&1 && echo lbr || echo instr; rm -f $$f)
BOLT_OPTS = -reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions -split-all-cold -dyno-stats

.DEFAULT_GOAL := all

# sqlite 3.54.1. hashes are of what sqlite.org and github served when this
# was written
ZIP_SHA256 = 0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
SPEEDTEST_SHA256 = bcb4a3123b60db648e748837f5c46092e23a3b35d970f7da5e62c42809f18185

src/sqlite-amalgamation-$(VERSION).zip:
	mkdir -p src
	wget -q -O $@ https://www.sqlite.org/2026/sqlite-amalgamation-$(VERSION).zip
	echo "$(ZIP_SHA256)  $@" | sha256sum -c --quiet

src/speedtest1.c:
	mkdir -p src
	wget -q -O $@ https://raw.githubusercontent.com/sqlite/sqlite/version-3.54.1/test/speedtest1.c
	echo "$(SPEEDTEST_SHA256)  $@" | sha256sum -c --quiet

$(AMALG)/sqlite3.c: src/sqlite-amalgamation-$(VERSION).zip
	cd src && unzip -q -o sqlite-amalgamation-$(VERSION).zip
	touch $@

st_base: $(SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) -Wl,--emit-relocs -o $@ $(SRCS) $(LDLIBS)

st_instr: $(SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) -fprofile-generate -o $@ $(SRCS) $(LDLIBS)

%.profdata: st_instr
	rm -f $*.profraw
	LLVM_PROFILE_FILE=$*.profraw ./st_instr $(call RUN,$*,$(TRAIN_SCALE)) >/dev/null
	$(PROFDATA) merge -o $@ $*.profraw

main+cte.profdata: main.profdata cte.profdata
	$(PROFDATA) merge -o $@ $^

st_pgo_%: $(SRCS) %.profdata
	$(CC) $(CFLAGS) $(LDFLAGS) -fprofile-use=$*.profdata -o $@ $(SRCS) $(LDLIBS)

ifeq ($(BOLT_PROFILE),instr)
%.fdata: st_base
	rm -f $@
	$(BOLT) st_base -instrument -instrumentation-file=$(CURDIR)/$@ -o st_binst_$* >/dev/null
	./st_binst_$* $(call RUN,$*,$(TRAIN_SCALE)) >/dev/null
else ifeq ($(BOLT_PROFILE),lbr)
%.fdata: st_base
	$(PERF) record -q -e cycles:u -j any,u -o $*.perf.data -- ./st_base $(call RUN,$*,1) >/dev/null
	$(PERF2BOLT) -p $*.perf.data -o $@ st_base >/dev/null
else
$(error BOLT_PROFILE must be lbr or instr)
endif

st_bolt_%: st_base %.fdata
	$(BOLT) st_base -o $@ -data=$*.fdata $(BOLT_OPTS) >$@.log 2>&1 || { cat $@.log; exit 1; }
	@grep 'could not be optimized' $@.log || true

all: st_base $(TRAIN:%=st_pgo_%) st_pgo_$(MERGED) $(TRAIN:%=st_bolt_%)

clean:
	rm -f st_base st_instr st_pgo_* st_bolt_* st_binst_* \
		*.profraw *.profdata *.fdata *.perf.data *.perf.data.old

print-bolt-profile:
	@echo $(BOLT_PROFILE)

# for bench.sh: the speedtest1 arguments for one full-size run of a test set
print-run-%:
	@echo $(call RUN,$*,1)

.PHONY: all clean print-bolt-profile
.PRECIOUS: %.profdata %.fdata
