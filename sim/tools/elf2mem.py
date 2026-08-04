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

Byte order (docs/adr/0037-rvc-compressed-instructions-phase-u.md): IMEM and
DMEM are symmetric now. Both design/InstructionMemory.v and
design/DataMemoryBRAM.v read `{mem[addr+3], mem[addr+2], mem[addr+1],
mem[addr]}` (LSB-first) -- real ELF bytes (RISC-V spec: byte at the lowest
address is the *least* significant byte) work directly for both, no
reordering needed anywhere. This was NOT always true: through Phase T,
InstructionMemory.v read MSB-first instead, requiring a real per-4-byte-
word swap here (and a matching big-endian pack in design/asm.py's own
write_mem) -- RVC's own compressed (2-byte) instructions broke that,
since a fixed per-4-byte-aligned-word swap can't stay correct once a
compressed instruction shifts every later instruction off the 4-byte grid
(no static byte array satisfies "every possible unaligned 4-byte read
reconstructs the right value" simultaneously -- a real, worked proof, not
just a hunch). InstructionMemory.v's read order was changed to match
DataMemoryBRAM.v's own already-correct convention instead of inventing a
second one; swap_instruction_words below is kept only for any external
caller that might still reference it, but is no longer called by this
module's own pipeline.

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


def get_section_vma(objdump, elf_path, section):
    """Reads a section's own real VMA directly from the ELF's section
    headers (docs/adr/0035-minimal-sbi-firmware-phase-s.md) -- used to
    place IMEM sections independently, the same "extract by real VMA, not
    by naive concatenation" idiom get_symbol/extract_binary already use for
    .rodata/.data. Needed once a linker script has more than one
    non-contiguous code region (e.g. link_sbi.ld's own fixed-VMA
    .text.boot + .text.payload split) -- the original .text.init+.text
    default stays a single contiguous extraction (both sections start
    exactly where the old link.ld already placed them), so this is additive,
    not a behavior change for that existing caller."""
    r = subprocess.run([objdump, "-h", elf_path], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"objdump -h failed: {r.stderr.strip()}")
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1] == section:
            return int(parts[3], 16)
    return None  # section doesn't exist in this ELF (e.g. no .text.init at all)


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
    # docs/adr/0035-minimal-sbi-firmware-phase-s.md: generalized from a
    # single hardcoded [".text.init", ".text"] concatenation (correct only
    # when those two sections are contiguous, which sim/benchmarks/c/
    # link.ld's own layout always makes true) to independent-by-VMA
    # placement -- needed for link_sbi.ld's own non-contiguous
    # .text.boot + .text.payload split. Comma-separated, same default as
    # before (this flag is additive; every existing build_c_bench.py
    # invocation that doesn't pass it behaves bit-identically).
    ap.add_argument("--imem-sections", default=".text.init,.text",
                     help="comma-separated section names, each placed at its own real VMA "
                          "(default matches sim/benchmarks/c/link.ld's contiguous .text.init+.text)")
    args = ap.parse_args()

    nm = args.objcopy.replace("objcopy", "nm")
    objdump = args.objcopy.replace("objcopy", "objdump")
    imem = bytearray(args.imem_size)
    for section in args.imem_sections.split(","):
        raw = extract_raw(args.objcopy, args.elf, section)
        if not raw:
            continue
        vma = get_section_vma(objdump, args.elf, section)
        if vma is None:
            raise ValueError(f"section {section!r} has content but no VMA found in objdump -h output")
        if vma + len(raw) > args.imem_size:
            raise ValueError(f"{section} at VMA {vma:#x} + {len(raw)} bytes "
                              f"exceeds the {args.imem_size}-byte region -- grow --imem-size")
        imem[vma:vma + len(raw)] = raw
    imem = bytes(imem)

    # .rodata is data (read via load instructions, never instruction-fetched)
    # and lives in DMEM, not IMEM -- see link.ld's header comment for the
    # real infinite loop this caused (Dhrystone's strcpy() of a string
    # literal) before being found and fixed. .rodata and .data are
    # extracted independently and placed at their own real VMA offsets
    # (from link.ld's _rodata_start/_data_start symbols) rather than
    # extracted together by LMA -- see link.ld's header comment for the
    # two ways that went wrong first.
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
