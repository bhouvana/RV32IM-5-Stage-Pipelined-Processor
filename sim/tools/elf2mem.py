#!/usr/bin/env python3
"""
ELF -> this project's .mem format converter (docs/ROADMAP.md Phase 10 --
real compiled-C benchmarks, following up on the hand-written
sim/benchmarks/bench_*.s kernels). asm.py is this core's own custom
assembler, not a general RV32I toolchain consumer -- it has no notion of
ELF/object files at all, so a real GCC-compiled binary needs this instead.

This core is Harvard architecture (design/InstructionMemory.v and
design/DataMemoryBRAM.v are two independent, zero-based byte arrays, not a
single unified address space) -- see sim/benchmarks/c/link.ld's header
comment for how the linker script makes that work: .text/.text.init AND
.rodata/.data/.bss/stack all resolve to zero-based *execution* addresses
(VMA) -- the compiled code's own address computations need this to match
design/DataMemoryBRAM.v's real 0-indexed array, not just this tool's
output layout (a first attempt got this wrong: giving .data a distinct
nonzero *origin* to dodge a linker error meant the compiled code itself
computed nonzero addresses for every global, verified broken by an actual
run producing X-valued register reads, not caught by reasoning about the
linker script alone). .rodata/.data's distinct, non-overlapping *load*
addresses (LMA, via `AT()` in the linker script) are bookkeeping the
linker needs and this tool relies on for extraction (`objcopy -O binary`'s
default layout is LMA-based) -- never seen by the compiled code or by
DataMemoryBRAM.v, and needs no un-doing here. .bss needs no special
handling either, since it's just left as zero bytes in a pre-zeroed output
buffer (matching a freshly-reset DataMemoryBRAM.v exactly).

.rodata goes to DMEM, not IMEM, despite being read-only -- a second real
gotcha, also found by actually running a program (Dhrystone) and getting a
genuine infinite loop back, not reasoned out in advance. .rodata (string
literals, const arrays) is never instruction-fetched; C code reads it with
ordinary load instructions, which this core routes to DataMemoryBRAM.v
unconditionally. An earlier version of this tool/link.ld put .rodata in
IMEM instead -- invisible to smoke_test.c (no string literals) and
CoreMark's port (its ee_printf stub takes `(void)fmt` and never
dereferences the format string), but fatal to Dhrystone's
`strcpy(dst, "a string literal")`, which read back all-zero bytes for the
"literal" and sent a data-dependent loop into never terminating. Confirmed
via a debug testbench showing the DUT permanently redirecting within a
small, fixed address range.

Byte order needs care, and the two memories are NOT symmetric here -- a
real, genuine gotcha, found by actually running a compiled smoke test and
getting garbage back, not assumed. A real ELF's instruction/data bytes are
always little-endian (RISC-V's actual spec: byte at the lowest address is
the *least* significant byte of a multi-byte value). But design/asm.py --
this core's own hand-written-assembly path, entirely independent of a real
toolchain -- packs its OWN instruction words *big-endian*
(`(w>>24)&0xFF` first), matching design/InstructionMemory.v's own
`{insts[addr], insts[addr+1], ...}` MSB-first concatenation; that pairing
is self-consistent but is NOT standard RISC-V byte order. So: IMEM bytes
extracted from a real ELF need each 4-byte instruction word's byte order
*reversed* to match what InstructionMemory.v expects. DMEM does NOT --
design/DataMemoryBRAM.v's own `{mem[addr+3], mem[addr+2], ...}` load/store
logic already matches real RISC-V little-endian directly, so a real ELF's
.data bytes need no reordering at all.

Usage:
    python elf2mem.py program.elf --imem-out imem.mem --dmem-out dmem.mem \\
        --imem-size 32768 --dmem-size 32768 --objcopy riscv-none-elf-objcopy
"""
import argparse
import os
import subprocess
import sys
import tempfile


def extract_raw(objcopy, elf_path, section):
    """Runs objcopy -O binary keeping only `section`, returns its exact
    bytes with no padding (zero-length if the section doesn't exist/is
    empty -- e.g. a program with no string literals or const data has no
    .rodata at all)."""
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        cmd = [objcopy, "-O", "binary", "--only-section", section, elf_path, tmp_path]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"objcopy failed: {r.stderr.strip()}")
        with open(tmp_path, "rb") as f:
            return f.read()
    finally:
        os.unlink(tmp_path)


def extract_binary(objcopy, elf_path, sections, size):
    """extract_raw for a single section (or multiple *contiguous-VMA*
    sections, e.g. .text.init+.text -- both always present, always at VMA
    0, in that order), zero-padded/size-checked to exactly `size` bytes."""
    data = b"".join(extract_raw(objcopy, elf_path, s) for s in sections)
    if len(data) > size:
        raise ValueError(f"extracted {len(data)} bytes for sections {sections}, "
                          f"exceeds the {size}-byte region -- shrink the program "
                          f"or grow --imem-size/--dmem-size")
    return data + b"\x00" * (size - len(data))


def get_symbol(nm, elf_path, name):
    """Reads one symbol's address out of the ELF via `nm` -- used to place
    .rodata/.data at their real linker-computed VMA offsets (see this
    module's docstring and link.ld's header comment for why this can't
    just be inferred from section sizes/order in Python instead)."""
    r = subprocess.run([nm, elf_path], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"nm failed: {r.stderr.strip()}")
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[-1] == name:
            return int(parts[0], 16)
    raise ValueError(f"symbol {name!r} not found in {elf_path} (nm output had no matching line)")


def swap_instruction_words(data):
    """Reverses byte order within every 4-byte group: a real ELF's
    little-endian instruction encoding -> design/InstructionMemory.v's
    big-endian byte layout (see this module's docstring)."""
    assert len(data) % 4 == 0
    out = bytearray(len(data))
    for i in range(0, len(data), 4):
        out[i:i + 4] = data[i:i + 4][::-1]
    return bytes(out)


def write_mem(data, path):
    with open(path, "w", newline="\n") as f:
        for b in data:
            f.write(f"{b:08b}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf")
    ap.add_argument("--imem-out", required=True)
    ap.add_argument("--dmem-out", required=True)
    ap.add_argument("--imem-size", type=int, required=True)
    ap.add_argument("--dmem-size", type=int, required=True)
    ap.add_argument("--objcopy", default="riscv-none-elf-objcopy")
    args = ap.parse_args()

    imem = extract_binary(args.objcopy, args.elf, [".text.init", ".text"], args.imem_size)
    imem = swap_instruction_words(imem)

    # .rodata is data (read via load instructions, never instruction-fetched)
    # and lives in DMEM, not IMEM -- see link.ld's header comment for the
    # real infinite loop this caused (Dhrystone's strcpy() of a string
    # literal) before being found and fixed. .rodata and .data are
    # extracted independently and placed at their own real VMA offsets
    # (from link.ld's _rodata_start/_data_start symbols) rather than
    # extracted together by LMA -- see link.ld's header comment for the
    # two ways that went wrong first.
    nm = args.objcopy.replace("objcopy", "nm")
    rodata_raw = extract_raw(args.objcopy, args.elf, ".rodata")
    data_raw = extract_raw(args.objcopy, args.elf, ".data")
    rodata_off = get_symbol(nm, args.elf, "_rodata_start") if rodata_raw else 0
    data_off = get_symbol(nm, args.elf, "_data_start") if data_raw else 0

    dmem = bytearray(args.dmem_size)
    for off, blob, name in [(rodata_off, rodata_raw, ".rodata"), (data_off, data_raw, ".data")]:
        if off + len(blob) > args.dmem_size:
            raise ValueError(f"{name} at VMA {off} + {len(blob)} bytes "
                              f"exceeds the {args.dmem_size}-byte region -- grow --dmem-size")
        dmem[off:off + len(blob)] = blob
    dmem = bytes(dmem)

    write_mem(imem, args.imem_out)
    write_mem(dmem, args.dmem_out)
    print(f"{args.elf}: {args.imem_out} ({args.imem_size}B), {args.dmem_out} ({args.dmem_size}B)")


if __name__ == "__main__":
    main()
