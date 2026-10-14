#!/usr/bin/env python3
# generates ops.c/ops.h: NOPS distinct noinline float->float functions.
# each one needs a genuinely different body (not just a different name) or
# the compiler/linker will happily fold identical functions back together
# and the whole "lots of distinct code" premise goes away.

import sys

NOPS = int(sys.argv[1]) if len(sys.argv) > 1 else 96
LINES_PER_OP = 16  # bump this to make each function (and total code) bigger

with open("ops.h", "w") as f:
    f.write(f"#define NOPS {NOPS}\n")
    f.write("#define OP_LIST(X) " + " ".join(f"X({i})" for i in range(NOPS)) + "\n\n")
    for i in range(NOPS):
        f.write(f"float op{i}(float x);\n")

with open("ops.c", "w") as f:
    f.write('#include "ops.h"\n\n')
    for i in range(NOPS):
        f.write(f"__attribute__((noinline)) float op{i}(float x) {{\n")
        for k in range(LINES_PER_OP):
            c = (i * 37 + k * 13 + 1) % 97 + 1
            f.write(f"    x = x * 1.000{k % 9 + 1}f + {c}.0f;\n")
            f.write(f"    x = x - {c}.5f;\n")
        f.write("    return x;\n}\n\n")
