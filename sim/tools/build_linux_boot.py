#!/usr/bin/env python3
"""
Build the combined memory image for a real Linux kernel boot attempt
(docs/adr/0036-linux-boot-attempt-phase-t.md): M-mode SBI firmware (real
v0.2, spec-version=2, no S-mode test payload this time) + the real kernel
Image + the real initramfs + a real DTB describing them, placed into one
Verilator-ready imem.mem/dmem.mem pair.

ponytail: real, deliberate ceiling this build works around, not hides --
InstructionMemory.v/DataMemoryBRAM.v are genuinely Harvard (two disjoint
byte arrays, confirmed by reading both modules: neither one's fetch/data
path ever touches the other's array). A real Linux `Image` is a flat,
headerless-except-for-its-own-64-byte-header binary mixing code and
initialized data (.text/.rodata/.data) with no section table to split by
VMA the way elf2mem.py already does for this project's own ELF firmware --
so this build mirrors the kernel Image's raw bytes into BOTH imem.mem and
dmem.mem at the same address: data loads see initialized .data/.rodata
(from the DMEM copy), instruction fetches see .text (from the IMEM copy).
This does NOT cover genuine runtime self-modifying code (jump_label/
ftrace/alternatives patching, kernel module loading) -- a STORE only
updates the DMEM copy, a later FETCH from IMEM still sees the stale
pre-patch bytes. If the boot hangs/crashes with no other explanation, this
is the first thing to suspect. Upgrade path: unify the two memories at the
RTL level (a real architectural change, out of scope for this phase).

Also relies on a Verilator-specific default: gaps in dmem.mem beyond this
build's own content (real, general-purpose RAM the kernel's own memblock
allocator will touch during boot, never explicitly zeroed by RTL past
ZERO_INIT_LIMIT_OVERRIDE) come out to a real 0 only because Verilator
zero-initializes all state by default (no --x-assign passed) -- Icarus
does NOT do this for DataMemoryBRAM.v's own if/$readmemb-else/zero-loop
exclusivity (see that module's own comment), so this specific memory image
is not safe to replay under Icarus without also raising
ZERO_INIT_LIMIT_OVERRIDE to the full --mem-size.

Usage:
    python build_linux_boot.py --gcc <riscv-none-elf-gcc> --objcopy <riscv-none-elf-objcopy>
"""
import argparse
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FW_DIR = os.path.join(HERE, "..", "firmware")
KERNEL_DIR = os.path.join(FW_DIR, "kernel_boot")
BUILD_DIR = os.path.join(FW_DIR, "build_linux")

sys.path.insert(0, HERE)
from elf2mem import write_mem  # reuse the exact same .mem line format, not a second writer
# docs/adr/0037-rvc-compressed-instructions-phase-u.md: kernel_bytes need no
# byte-swap at all, into either memory -- design/InstructionMemory.v and
# design/DataMemoryBRAM.v both read LSB-first now (real ELF/Image little-
# endian bytes work directly), a real RTL fix that phase made after proving
# a fixed per-4-byte-aligned-word swap (an earlier version of this script's
# own attempt, mirroring elf2mem.py's then-existing convention) can't stay
# correct once a compressed instruction shifts later instructions off the
# 4-byte grid -- see InstructionMemory.v's own header comment for the proof.

MEM_SIZE_BYTES = 64 * 1024 * 1024   # Phase Q's own already-verified scale (docs/adr/0033), both IMEM/DMEM
FW_LINK_SIZE = 32768                 # firmware's own linker-script region size, unchanged from Phase S
KERNEL_LOAD_ADDR = 0x200000          # must match the real Image's own header text_offset
INITRD_ADDR = 0x1000000              # 16MB -- comfortably clear of kernel Image's own ~11.6MB end
DTB_ADDR_KERNEL = 0x1500000          # 21MB -- comfortably clear of initrd's own ~20.4MB end


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    if r.stdout.strip():
        print(r.stdout)
    return r


def read_mem(path, size):
    """Inverse of elf2mem.py's write_mem -- decodes its 8-bit-binary-string-
    per-line format back into a bytearray of the given length."""
    buf = bytearray(size)
    with open(path) as f:
        for i, line in enumerate(f):
            line = line.strip()
            if line:
                buf[i] = int(line, 2)
    return buf


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gcc", default="riscv-none-elf-gcc")
    ap.add_argument("--objcopy", default="riscv-none-elf-objcopy")
    ap.add_argument("--kernel-image", default=os.path.join(KERNEL_DIR, "Image"))
    ap.add_argument("--initramfs", default=os.path.join(KERNEL_DIR, "initramfs.cpio.gz"))
    ap.add_argument("--mem-size", type=int, default=MEM_SIZE_BYTES)
    ap.add_argument("--imem-out", default=os.path.join(BUILD_DIR, "imem.mem"))
    ap.add_argument("--dmem-out", default=os.path.join(BUILD_DIR, "dmem.mem"))
    args = ap.parse_args()

    os.makedirs(BUILD_DIR, exist_ok=True)

    with open(args.kernel_image, "rb") as f:
        kernel_bytes = f.read()
    with open(args.initramfs, "rb") as f:
        initramfs_bytes = f.read()

    # Real header check, not assumed -- a genuine RISC-V Image's own
    # text_offset (offset 0x08, little-endian u64) must match
    # KERNEL_LOAD_ADDR or this build's whole placement scheme is wrong for
    # whatever file was actually handed to it.
    text_offset = struct.unpack_from("<Q", kernel_bytes, 0x08)[0]
    magic = kernel_bytes[0x30:0x38]
    if magic != b"RISCV\x00\x00\x00":
        raise ValueError(f"not a real RISC-V Image (magic={magic!r})")
    if text_offset != KERNEL_LOAD_ADDR:
        raise ValueError(f"Image's own text_offset {text_offset:#x} != KERNEL_LOAD_ADDR {KERNEL_LOAD_ADDR:#x}")
    if INITRD_ADDR < KERNEL_LOAD_ADDR + len(kernel_bytes):
        raise ValueError("INITRD_ADDR overlaps kernel Image -- grow INITRD_ADDR")
    if DTB_ADDR_KERNEL < INITRD_ADDR + len(initramfs_bytes):
        raise ValueError("DTB_ADDR_KERNEL overlaps initramfs -- grow DTB_ADDR_KERNEL")

    # --- 1. Firmware: M-mode boot + trap handler + real v0.2 SBI, no
    # S-mode test payload this time -- boot.S's own KERNEL_ENTRY/
    # KERNEL_DTB_ADDR macros retarget mepc/a1 at the real kernel instead of
    # Phase S's PAYLOAD_BASE/DTB_ADDR defaults.
    cflags = [
        "-march=rv64imafd_zicsr", "-mabi=lp64",
        "-nostdlib", "-nostartfiles", "-ffreestanding",
        "-msmall-data-limit=0", "-O1",
        "-DSPEC_VERSION_TO_REPORT=2",
        f"-DKERNEL_ENTRY={KERNEL_LOAD_ADDR:#x}",
        f"-DKERNEL_DTB_ADDR={DTB_ADDR_KERNEL:#x}",
        "-Wl,-T," + os.path.join(FW_DIR, "link_sbi.ld"),
        "-I", FW_DIR,
    ]
    sources = [
        os.path.join(FW_DIR, "boot.S"),
        os.path.join(FW_DIR, "trap_entry.S"),
        os.path.join(FW_DIR, "sbi.c"),
    ]
    objects = []
    for src in sources:
        obj = os.path.join(BUILD_DIR, os.path.splitext(os.path.basename(src))[0] + ".o")
        run([args.gcc] + cflags + ["-c", src, "-o", obj])
        objects.append(obj)
    fw_elf = os.path.join(BUILD_DIR, "fw.elf")
    run([args.gcc] + cflags + objects + ["-o", fw_elf])

    fw_imem_path = os.path.join(BUILD_DIR, "fw_imem.mem")
    fw_dmem_path = os.path.join(BUILD_DIR, "fw_dmem.mem")
    run([sys.executable, os.path.join(HERE, "elf2mem.py"), fw_elf,
         "--imem-out", fw_imem_path, "--dmem-out", fw_dmem_path,
         "--imem-size", str(FW_LINK_SIZE), "--dmem-size", str(FW_LINK_SIZE),
         "--imem-sections", ".text.boot",
         "--objcopy", args.objcopy])
    fw_imem = read_mem(fw_imem_path, FW_LINK_SIZE)
    fw_dmem = read_mem(fw_dmem_path, FW_LINK_SIZE)

    # --- 2. Real DTB: real mem-size, real initrd location, earlycon
    # bootargs (bypasses SBI console entirely for first output -- this
    # core's UART is already real ns16550a-compatible, Phase R/docs/adr/0034).
    bootargs = "earlycon=uart8250,mmio,0x10000000,1000000n8 console=ttyS0 rdinit=/init"
    dtb_path = os.path.join(BUILD_DIR, "kernel.dtb")
    run([sys.executable, os.path.join(HERE, "gen_dtb.py"), "-o", dtb_path,
         "--mem-size", str(args.mem_size),
         "--bootargs", bootargs,
         "--initrd-start", str(INITRD_ADDR),
         "--initrd-end", str(INITRD_ADDR + len(initramfs_bytes))])
    with open(dtb_path, "rb") as f:
        dtb_bytes = f.read()
    if DTB_ADDR_KERNEL + len(dtb_bytes) > args.mem_size:
        raise ValueError("DTB placement exceeds --mem-size -- grow it")

    # --- 3. Combine into one flat image per memory (mirroring the kernel
    # Image into both, per the module docstring's own Harvard-split
    # caveat) -- initramfs/DTB are pure data, only need the DMEM copy.
    # Sized to this build's own real content high-water mark, not the full
    # --mem-size -- keeps the .mem files (and Verilator's own $readmemb
    # parse of them) proportional to actual content; the rest of each
    # array comes out to a real 0 via Verilator's own default state
    # (see module docstring).
    content_end = DTB_ADDR_KERNEL + len(dtb_bytes)
    zero_init_limit = ((content_end + 4095) // 4096) * 4096

    combined_imem = bytearray(zero_init_limit)
    combined_imem[0:len(fw_imem)] = fw_imem
    combined_imem[KERNEL_LOAD_ADDR:KERNEL_LOAD_ADDR + len(kernel_bytes)] = kernel_bytes

    combined_dmem = bytearray(zero_init_limit)
    combined_dmem[0:len(fw_dmem)] = fw_dmem
    combined_dmem[KERNEL_LOAD_ADDR:KERNEL_LOAD_ADDR + len(kernel_bytes)] = kernel_bytes
    combined_dmem[INITRD_ADDR:INITRD_ADDR + len(initramfs_bytes)] = initramfs_bytes
    combined_dmem[DTB_ADDR_KERNEL:DTB_ADDR_KERNEL + len(dtb_bytes)] = dtb_bytes

    write_mem(combined_imem, args.imem_out)
    write_mem(combined_dmem, args.dmem_out)
    print(f"done: {args.imem_out}, {args.dmem_out}")
    print(f"kernel@{KERNEL_LOAD_ADDR:#x} ({len(kernel_bytes)} bytes), "
          f"initrd@{INITRD_ADDR:#x} ({len(initramfs_bytes)} bytes), "
          f"dtb@{DTB_ADDR_KERNEL:#x} ({len(dtb_bytes)} bytes)")
    print(f"zero_init_limit={zero_init_limit:#x} -- pass this as "
          f"-GZERO_INIT_LIMIT_OVERRIDE to build_kernel_boot.py's own verilate step")


if __name__ == "__main__":
    main()
