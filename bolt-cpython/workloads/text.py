# log-processing style: regex tokenizing, str methods, f-strings, json in
# and out. hits the string, regex and json parts of the interpreter (and
# their C code) instead of the arithmetic.
import json
import re
import sys
import time

WORDS = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
         "GET", "POST", "error", "warning", "timeout", "user", "session", "cache"]

LINE_RE = re.compile(r"(\d+)-(\d+)-(\d+) (\w+) \[(\w+)\] (.*)")
TOKEN_RE = re.compile(r"[A-Za-z]+|\d+|\S")


def make_lines(count):
    # deterministic, no random module so every build sees the same input
    lines = []
    x = 12345
    for i in range(count):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        words = " ".join(WORDS[(x >> k) % len(WORDS)] for k in range(0, 24, 3))
        level = ("INFO", "WARN", "ERROR")[x % 3]
        lines.append(f"2026-{x % 12 + 1:02d}-{x % 28 + 1:02d} host{x % 7} [{level}] {words} id={x % 10000}")
    return lines


def process(lines):
    counts = {}
    records = []
    for line in lines:
        m = LINE_RE.match(line)
        if not m:
            continue
        _, month, day, host, level, msg = m.groups()
        tokens = TOKEN_RE.findall(msg.lower())
        for t in tokens:
            counts[t] = counts.get(t, 0) + 1
        records.append({"month": int(month), "day": int(day), "host": host,
                        "level": level, "n": len(tokens), "head": msg[:16].upper()})
    blob = json.dumps(records)
    back = json.loads(blob)
    return counts, sum(r["n"] for r in back) + len(blob)


def main(n):
    lines = make_lines(20000)
    total = 0
    t0 = time.perf_counter()
    for _ in range(n):
        counts, s = process(lines)
        total += s + len(counts)
    t1 = time.perf_counter()
    print(f"workload=text n={n} time={t1 - t0:.4f}s checksum={total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 10)
