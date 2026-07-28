#!/usr/bin/env python3
"""
Reads specific values out of a state.out dump produced by
sim/tb/c_bench_template.v (docs/ROADMAP.md Phase 10 -- CoreMark/Dhrystone
verification). state.out is 32 register lines followed by one line per
data-memory byte (sim/tools/build_c_bench.py's --keep option preserves
it); this reads byte ranges out of the memory portion by address, since
that's what `nm` on the compiled ELF gives you for a fixed global (a
stack-local like CoreMark's `core_results results[]` has no such fixed
address -- see sim/benchmarks/c/coremark_port/core_portme.c for how that
one is handled instead).

Usage:
    python read_dump.py state.out --u32 0x27fc --u16 0x1000 --i8 0x27f5
    python read_dump.py state.out --u32 0x0 --count 50   # Arr_1_Glob[0..49]
"""
import argparse
import sys


def load_mem(path):
    with open(path) as f:
        vals = [int(line.strip()) & 0xFF for line in f if line.strip()]
    return vals[32:]  # skip the 32 register lines


def read_le(mem, addr, size, signed):
    b = mem[addr:addr + size]
    v = 0
    for i, byte in enumerate(b):
        v |= byte << (8 * i)
    if signed and (v & (1 << (size * 8 - 1))):
        v -= 1 << (size * 8)
    return v


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("state_out")
    ap.add_argument("--u8", type=lambda x: int(x, 0), action="append", default=[])
    ap.add_argument("--i8", type=lambda x: int(x, 0), action="append", default=[])
    ap.add_argument("--u16", type=lambda x: int(x, 0), action="append", default=[])
    ap.add_argument("--u32", type=lambda x: int(x, 0), action="append", default=[])
    ap.add_argument("--count", type=int, default=1, help="repeat the last-given address's size N times, incrementing by size")
    args = ap.parse_args()

    mem = load_mem(args.state_out)
    for size, signed, addrs in [(1, False, args.u8), (1, True, args.i8),
                                 (2, False, args.u16), (4, False, args.u32)]:
        for addr in addrs:
            for i in range(args.count):
                a = addr + i * size
                v = read_le(mem, a, size, signed)
                print(f"[{a:#x}] = {v} ({v:#x})")


if __name__ == "__main__":
    main()
