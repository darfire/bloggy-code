#!/usr/bin/env bash
# builds cpython several ways, into build/<variant>/python:
#
#   base      plain -O3, no profile
#   pgo       --enable-optimizations: pgo trained on cpython's own test
#             suite, what you get from a distro or python.org
#   pgo-$TRAIN  same, trained on one of our workloads instead
#   base-switch, pgo-switch
#             base and pgo with --without-computed-gotos: the eval loop is
#             a plain switch, which bolt can follow (it can't the gotos)
#   and bolt binaries, profiled on $TRAIN, next to the ones they came
#   from: base/python.bolt-$TRAIN, pgo/python.bolt-$TRAIN, same for -switch
#
#   ./build.sh                    everything that isn't built yet
#   TRAIN=text ./build.sh         also train on another workload
#   LLVM_SUFFIX=-18 ./build.sh    debian/ubuntu suffixed llvm tools
#
# needs clang, llvm-profdata (same version), llvm-bolt (any), perf for the
# lbr bolt profile, and cpython's build deps (pkg-config, zlib, libffi,
# xz to unpack the source).
# deactivate conda first - its pkg-config/linker/libs leak into configure.
set -euo pipefail

cd "$(dirname "$0")"
HERE=$PWD

VERSION=3.15.1
# what python.org served when this was written
SHA256=673ae7232d84c894729882c8257d300ef2d26523911bfd3917ec8ce7f526f99b

TRAIN=${TRAIN:-numeric}
TRAIN_N=${TRAIN_N:-10}
JOBS=${JOBS:-$(nproc)}
LLVM_SUFFIX=${LLVM_SUFFIX:-}
CC=${CC:-clang$LLVM_SUFFIX}
export LLVM_PROFDATA=${LLVM_PROFDATA:-$(command -v "llvm-profdata$LLVM_SUFFIX" || true)}

# bolt only reads the finished binary, any version works: plain llvm-bolt,
# else the newest llvm-bolt-NN. real path, not the /usr/bin symlink, or it
# can't find its instrumentation runtime.
BOLT_NAME=${BOLT_NAME:-$(command -v "llvm-bolt$LLVM_SUFFIX" || { IFS=:; for d in $PATH; do ls "$d"/llvm-bolt-[0-9]* 2>/dev/null; done | sort -V | tail -n 1; })}
BOLT=$(realpath "$BOLT_NAME")
BOLT_OPTS="-reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions -split-all-cold -dyno-stats"

# lbr if perf can record branches here (bare metal intel, zen 4 + linux
# 6.1), otherwise bolt's own instrumentation. see ../pgo-dispatch.
if [ -z "${BOLT_PROFILE:-}" ]; then
    tmp=$(mktemp)
    if perf record -q -e cycles:u -j any,u -o "$tmp" -- true >/dev/null 2>&1; then
        BOLT_PROFILE=lbr
    else
        BOLT_PROFILE=instr
    fi
    rm -f "$tmp"
fi

# same flags for every variant, so they only differ by profile:
#   -fno-pie/-no-pie: bolt can't follow pie jump tables, skips those
#                     functions without complaining much
#   --emit-relocs:    lets bolt move functions, doesn't change the code
export CFLAGS="-fno-pie"
export LDFLAGS="-no-pie -Wl,--emit-relocs"
CONFIGURE_OPTS="--without-ensurepip --disable-test-modules"

SRC=$HERE/src/Python-$VERSION

fetch() {
    [ -d "$SRC" ] && return
    mkdir -p src
    local tarball=src/Python-$VERSION.tar.xz
    [ -f "$tarball" ] || wget -q -O "$tarball" "https://www.python.org/ftp/python/$VERSION/Python-$VERSION.tar.xz"
    echo "$SHA256  $tarball" | sha256sum -c --quiet
    tar -xJf "$tarball" -C src
}

# objects and the static lib aren't needed once python is linked, and four
# builds of them don't fit on a small disk
tidy() {
    find "$1" \( -name '*.o' -o -name '*.profraw' \) -delete
    rm -f "$1"/libpython*.a
}

build() {
    local name=$1; shift
    local dir=$HERE/build/$name
    if [ -x "$dir/python" ]; then
        echo "$name: already built"
        return
    fi
    echo "$name: building (log in build/$name.log)"
    rm -rf "$dir"
    mkdir -p "$dir"
    (
        cd "$dir"
        "$SRC/configure" CC="$CC" $CONFIGURE_OPTS "$@"
        make -j"$JOBS" ${PROFILE_TASK:+PROFILE_TASK="$PROFILE_TASK"}
    ) >"$HERE/build/$name.log" 2>&1 || { tail -30 "$HERE/build/$name.log"; exit 1; }
    tidy "$dir"
}

bolt() {
    local name=$1
    local dir=$HERE/build/$name
    local out=$dir/python.bolt-$TRAIN
    if [ -x "$out" ]; then
        echo "$name: bolt already done"
        return
    fi
    echo "$name: bolt ($BOLT_PROFILE profile, trained on $TRAIN)"
    local fdata=$dir/$TRAIN.fdata
    case $BOLT_PROFILE in
    lbr)
        perf record -q -e cycles:u -j any,u -o "$dir/$TRAIN.perf.data" -- \
            "$dir/python" "workloads/$TRAIN.py" "$TRAIN_N" >/dev/null
        "$BOLT" -aggregate-only -p "$dir/$TRAIN.perf.data" -o "$fdata" "$dir/python" >/dev/null
        rm -f "$dir/$TRAIN.perf.data"
        ;;
    instr)
        rm -f "$fdata"
        "$BOLT" "$dir/python" -instrument -instrumentation-file="$fdata" -o "$dir/python.binst" >/dev/null
        "$dir/python.binst" "workloads/$TRAIN.py" "$TRAIN_N" >/dev/null
        rm -f "$dir/python.binst"
        ;;
    *)
        echo "BOLT_PROFILE must be lbr or instr" >&2
        exit 1
        ;;
    esac
    # the bolted binary stays in the build dir: python finds its stdlib
    # relative to where the executable is
    "$BOLT" "$dir/python" -o "$out" -data="$fdata" $BOLT_OPTS >"$out.log" 2>&1 || { cat "$out.log"; exit 1; }
    # bolt (at least up to 21) can't follow the computed gotos in the eval
    # loop, so _PyEval_EvalFrameDefault - and sre's match functions - are
    # left exactly as the compiler laid them out. cpython's own
    # --enable-bolt skips them on purpose for the same reason. it only says
    # which ones with -v=2, the count is always there:
    grep 'could not be optimized' "$out.log" | sed "s|^|$name: |" >&2 || true
}

fetch
mkdir -p build
build base
build pgo --enable-optimizations
PROFILE_TASK="$HERE/workloads/$TRAIN.py $TRAIN_N" build "pgo-$TRAIN" --enable-optimizations
build base-switch --without-computed-gotos
build pgo-switch --enable-optimizations --without-computed-gotos
bolt base
bolt pgo
bolt base-switch
bolt pgo-switch
