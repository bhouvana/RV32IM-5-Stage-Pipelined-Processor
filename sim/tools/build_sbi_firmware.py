#!/usr/bin/env python3
"""
Build Phase S's M-mode SBI firmware + S-mode test payload
(docs/adr/0035-minimal-sbi-firmware-phase-s.md). Unlike build_c_bench.py
(a general "build any userspace C program" driver, reused as a library
here only for its own proven ELF->`.mem` conversion step), this is a
one-shot, privileged-mode-specific pipeline: compile+link the whole
sim/firmware/ tree against link_sbi.ld, convert via elf2mem.py (real,
XLEN-agnostic, no changes needed), generate the DTB via gen_dtb.py, and
overlay its bytes into the already-written dmem.mem at link_sbi.ld's own
fixed DTB_ADDR (0x4000) -- static content, not linker-symbol-derived, so
no extension to elf2mem.py's own VMA-lookup machinery is needed for it.

Usage:
    python build_sbi_firmware.py --gcc <path-to-riscv-none-elf-gcc> \\
        --objcopy <path-to-riscv-none-elf-objcopy>
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FW_DIR = os.path.join(HERE, "..", "firmware")
BUILD_DIR = os.path.join(FW_DIR, "build")

MEM_SIZE = 32768   # bytes -- must match link_sbi.ld's IMEM/DMEM LENGTH (32K)
DTB_ADDR = 0x4000  # must match link_sbi.ld's own DTB_ADDR


def run(cmd):
    print("+", " ".join(str(c) for c in cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    if r.stdout.strip():
        print(r.stdout)
    return r


def overlay_dtb_into_dmem(dmem_mem_path, dtb_path, dtb_addr):
    """Overlays the DTB's raw bytes into an already-written elf2mem.py-
    format .mem file (one 8-bit binary string per line) at a fixed byte
    offset -- static content, not linker-placed, so this is simpler than
    teaching elf2mem.py a third input source."""
    with open(dtb_path, "rb") as f:
        dtb_bytes = f.read()
    with open(dmem_mem_path) as f:
        lines = f.read().splitlines()
    if dtb_addr + len(dtb_bytes) > len(lines):
        raise ValueError(f"DTB ({len(dtb_bytes)} bytes) at {dtb_addr:#x} exceeds dmem.mem's own "
                          f"{len(lines)}-byte size -- grow MEM_SIZE")
    for i, b in enumerate(dtb_bytes):
        lines[dtb_addr + i] = f"{b:08b}"
    with open(dmem_mem_path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gcc", default="riscv-none-elf-gcc")
    ap.add_argument("--objcopy", default="riscv-none-elf-objcopy")
    # docs/adr/0036-linux-boot-attempt-phase-t.md: selects which SBI spec
    # version sbi.c's own GET_SPEC_VERSION reports -- 0 (default, Phase
    # S's own legacy-v0.1 design, what tb_sbi_firmware_s7.v exercises) or
    # 2 (real v0.2+, needed for a modern Linux kernel's own timer to work
    # at all, since CONFIG_RISCV_SBI_V01=n by default in recent kernels).
    ap.add_argument("--spec-version", type=int, default=0, choices=[0, 2])
    args = ap.parse_args()

    os.makedirs(BUILD_DIR, exist_ok=True)
    elf_path = os.path.join(BUILD_DIR, "sbi_firmware.elf")

    cflags = [
        # rv64imafd (this core's own RV64IMAF ISA subset) + zicsr (boot.S/
        # trap_entry.S's own CSR instructions need this explicitly on
        # newer binutils, which no longer bundle it into the base "i").
        "-march=rv64imafd_zicsr", "-mabi=lp64",
        "-nostdlib", "-nostartfiles", "-ffreestanding",
        "-msmall-data-limit=0",  # sim/benchmarks/c/build_c_bench.py's own established gotcha-avoidance
        "-O1",
        f"-DSPEC_VERSION_TO_REPORT={args.spec_version}",
        "-Wl,-T," + os.path.join(FW_DIR, "link_sbi.ld"),
        "-I", FW_DIR,
    ]
    # Compiled to explicitly-named objects first, then linked together --
    # link_sbi.ld's own `*sbi.o(.text*)`/`*payload.o(.text*)` input-file-
    # name selectors (routing each C file's compiler-generated code into
    # the right fixed-VMA region, boot.S/PAYLOAD_BASE respectively) rely on
    # the object actually being named that; compiling multiple sources in
    # one `gcc ... -o elf` invocation goes through GCC's own unnamed temp
    # objects instead, silently breaking that match (confirmed by running:
    # a first attempt this way put _payload_start at 0x1b0, not the real
    # PAYLOAD_BASE 0x2000 -- the whole reason this phase's own linker
    # script needs named-object selectors at all).
    sources = [
        os.path.join(FW_DIR, "boot.S"),
        os.path.join(FW_DIR, "trap_entry.S"),
        os.path.join(FW_DIR, "sbi.c"),
        os.path.join(FW_DIR, "payload_start.S"),
        os.path.join(FW_DIR, "payload.c"),
    ]
    objects = []
    for src in sources:
        obj = os.path.join(BUILD_DIR, os.path.splitext(os.path.basename(src))[0] + ".o")
        run([args.gcc] + cflags + ["-c", src, "-o", obj])
        objects.append(obj)
    run([args.gcc] + cflags + objects + ["-o", elf_path])

    imem_mem = os.path.join(BUILD_DIR, "imem.mem")
    dmem_mem = os.path.join(BUILD_DIR, "dmem.mem")
    # link_sbi.ld's own non-contiguous .text.boot/.text.payload split needs
    # elf2mem.py's own real per-section VMA placement (docs/adr/0035's own
    # generalization of what used to be a single hardcoded
    # .text.init+.text concatenation) -- NOT the default.
    run([sys.executable, os.path.join(HERE, "elf2mem.py"), elf_path,
         "--imem-out", imem_mem, "--dmem-out", dmem_mem,
         "--imem-size", str(MEM_SIZE), "--dmem-size", str(MEM_SIZE),
         "--imem-sections", ".text.boot,.text.payload",
         "--objcopy", args.objcopy])

    dtb_path = os.path.join(BUILD_DIR, "firmware.dtb")
    run([sys.executable, os.path.join(HERE, "gen_dtb.py"), "-o", dtb_path,
         "--mem-size", str(MEM_SIZE)])

    overlay_dtb_into_dmem(dmem_mem, dtb_path, DTB_ADDR)
    print(f"DTB overlaid into {dmem_mem} at {DTB_ADDR:#x}")
    print(f"done: {imem_mem}, {dmem_mem}")


if __name__ == "__main__":
    main()
