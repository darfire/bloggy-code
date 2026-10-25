#!/usr/bin/env python3
# generates ops.h/ops.inc: the case bodies for the interpreter's switch.
#
# every op is NSTAGES small steps, and after each step a check on one bit
# of the operand that, when set, runs a bigger "rare case" fragment - the
# way real interpreter code is hot fast paths interleaved with type checks,
# overflow checks, error handling. all ops have different constants and
# registers, so the compiler can't merge them.
#
# which ops are hot, and how often those bits are set, is decided entirely
# by the program being run. the compiler can't see that: every check looks
# 50/50 to it, so it lays the rare fragments out inline, right in between
# the hot steps.

import sys

NOPS = int(sys.argv[1]) if len(sys.argv) > 1 else 128
NSTAGES = int(sys.argv[2]) if len(sys.argv) > 2 else 8
COLD_LINES = int(sys.argv[3]) if len(sys.argv) > 3 else 6  # bump to make the rare fragments bigger
NREGS = 8


def const(i, k):
    # odd 64-bit multipliers, different for every (op, line)
    return ((i + 1) * 0x9E3779B97F4A7C15 + (k + 1) * 0xBF58476D1CE4E5B9) % (1 << 64) | 1


with open("ops.h", "w") as f:
    f.write(f"#define NOPS {NOPS}\n")
    f.write(f"#define NSTAGES {NSTAGES}\n")
    f.write(f"#define NREGS {NREGS}\n")

with open("ops.inc", "w") as f:
    for i in range(NOPS):
        s0, s1, d = i % NREGS, (i * 3 + 1) % NREGS, (i * 5 + 2) % NREGS
        f.write(f"case {i}: {{\n")
        f.write(f"    uint64_t a = r[{s0}], b = r[{s1}];\n")
        for k in range(NSTAGES):
            f.write(f"    a = (a ^ 0x{const(i, k):x}ull) + (b >> {k + 1}) + ins.imm;\n")
            f.write(f"    if (ins.flags & {1 << k}) {{\n")
            for j in range(COLD_LINES):
                c = 100 + k * COLD_LINES + j
                f.write(f"        b = (b ^ (a >> {(i + c) % 29 + 3})) * 0x{const(i, c):x}ull;\n")
            f.write("        a += b;\n")
            f.write("    }\n")
        f.write(f"    r[{d}] = a ^ b;\n")
        f.write("    break;\n")
        f.write("}\n")
