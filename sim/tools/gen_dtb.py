#!/usr/bin/env python3
"""
Minimal flattened-devicetree (FDT/DTB) binary emitter
(docs/adr/0035-minimal-sbi-firmware-phase-s.md). No `dtc` (device tree
compiler) is installed anywhere on this machine (confirmed by a real
filesystem search) -- this hand-rolls the real FDT wire format directly in
Python instead, matching this project's own established precedent of
hand-rolling binary-format tooling (asm.py, elf2mem.py) rather than adding
a new external dependency for a small, well-specified format.

Real spec facts this emitter implements (Devicetree Specification, the
"Flattened Devicetree" chapter): a 10-word big-endian header (magic
0xd00dfeed first), a memory-reservation block (a real, even if trivially
empty-terminated, entry list), a structure block built from
FDT_BEGIN_NODE/FDT_PROP/FDT_END_NODE/FDT_END tokens (4-byte-aligned,
big-endian), and a strings block deduplicating property names. All
multi-byte integers in the structure/header (property VALUES included,
per each property's own real type -- cells are uint32, `reg`/`interrupts-
extended` etc are cell arrays) are big-endian on the wire, independent of
the target CPU's own byte order.

Usage: python gen_dtb.py -o out.dtb
"""
import argparse
import struct

FDT_MAGIC = 0xd00dfeed
FDT_VERSION = 17
FDT_LAST_COMP_VERSION = 16

FDT_BEGIN_NODE = 0x1
FDT_END_NODE = 0x2
FDT_PROP = 0x3
FDT_END = 0x9


def _align4(data: bytes) -> bytes:
    pad = (-len(data)) % 4
    return data + b"\x00" * pad


class FdtBuilder:
    def __init__(self):
        self._struct = bytearray()
        self._strings = bytearray()
        self._string_offsets = {}

    def _string_off(self, name: str) -> int:
        if name not in self._string_offsets:
            self._string_offsets[name] = len(self._strings)
            self._strings += name.encode("ascii") + b"\x00"
        return self._string_offsets[name]

    def begin_node(self, name: str):
        self._struct += struct.pack(">I", FDT_BEGIN_NODE)
        self._struct += _align4(name.encode("ascii") + b"\x00")

    def end_node(self):
        self._struct += struct.pack(">I", FDT_END_NODE)

    def _prop_raw(self, name: str, value: bytes):
        off = self._string_off(name)
        self._struct += struct.pack(">I", FDT_PROP)
        self._struct += struct.pack(">II", len(value), off)
        self._struct += _align4(value)

    def prop_empty(self, name: str):
        self._prop_raw(name, b"")

    def prop_u32(self, name: str, val: int):
        self._prop_raw(name, struct.pack(">I", val & 0xFFFFFFFF))

    def prop_u64(self, name: str, val: int):
        self._prop_raw(name, struct.pack(">Q", val & 0xFFFFFFFFFFFFFFFF))

    def prop_cells(self, name: str, cells):
        self._prop_raw(name, b"".join(struct.pack(">I", c & 0xFFFFFFFF) for c in cells))

    def prop_str(self, name: str, val: str):
        self._prop_raw(name, val.encode("ascii") + b"\x00")

    def prop_strlist(self, name: str, vals):
        self._prop_raw(name, b"".join(v.encode("ascii") + b"\x00" for v in vals))

    def build(self) -> bytes:
        self._struct += struct.pack(">I", FDT_END)

        # Memory reservation block: a real, terminated (0,0) entry list --
        # this phase reserves nothing, but the block itself must still be
        # present and correctly terminated per spec.
        rsvmap = struct.pack(">QQ", 0, 0)

        off_mem_rsvmap = 40  # fixed header size (10 uint32 words)
        off_dt_struct = off_mem_rsvmap + len(rsvmap)
        off_dt_strings = off_dt_struct + len(self._struct)
        totalsize = off_dt_strings + len(self._strings)

        header = struct.pack(
            ">10I",
            FDT_MAGIC,
            totalsize,
            off_dt_struct,
            off_dt_strings,
            off_mem_rsvmap,
            FDT_VERSION,
            FDT_LAST_COMP_VERSION,
            0,  # boot_cpuid_phys -- hart 0
            len(self._strings),
            len(self._struct),
        )
        return header + rsvmap + bytes(self._struct) + bytes(self._strings)


def build_this_core_dtb(mem_size_bytes: int, timebase_freq: int, uart_clock_freq: int,
                         bootargs: str = "console=ttyS0 earlycon",
                         initrd_start: int = None, initrd_end: int = None) -> bytes:
    """Generic device tree for this core's own real hardware (docs/adr/0034's
    UART/CLINT register maps) -- not tied to any one kernel's own
    assumptions, per the phase's own confirmed scope. docs/adr/0036 adds the
    optional real-kernel-boot /chosen properties (bootargs override,
    linux,initrd-start/end) on top of that same generic tree, not a second
    builder -- everything else about this hardware's own description stays
    identical whether or not a real kernel's initrd is in play."""
    fdt = FdtBuilder()

    fdt.begin_node("")
    fdt.prop_u32("#address-cells", 2)
    fdt.prop_u32("#size-cells", 2)
    fdt.prop_str("compatible", "5-stage-pipelined-processor")
    fdt.prop_str("model", "5-stage-pipelined-processor,rv64")

    fdt.begin_node("cpus")
    fdt.prop_u32("#address-cells", 1)
    fdt.prop_u32("#size-cells", 0)
    fdt.prop_u32("timebase-frequency", timebase_freq)

    fdt.begin_node("cpu@0")
    fdt.prop_u32("phandle", 1)
    fdt.prop_str("device_type", "cpu")
    fdt.prop_u32("reg", 0)
    fdt.prop_str("status", "okay")
    fdt.prop_str("compatible", "riscv")
    fdt.prop_str("riscv,isa", "rv64imafd")
    fdt.prop_str("mmu-type", "riscv,sv39")

    fdt.begin_node("interrupt-controller")
    fdt.prop_u32("#interrupt-cells", 1)
    fdt.prop_empty("interrupt-controller")
    fdt.prop_str("compatible", "riscv,cpu-intc")
    fdt.prop_u32("phandle", 2)
    fdt.end_node()  # interrupt-controller

    fdt.end_node()  # cpu@0
    fdt.end_node()  # cpus

    fdt.begin_node("memory@0")
    fdt.prop_str("device_type", "memory")
    fdt.prop_cells("reg", [0, 0, 0, mem_size_bytes])
    fdt.end_node()

    fdt.begin_node("soc")
    fdt.prop_u32("#address-cells", 2)
    fdt.prop_u32("#size-cells", 2)
    fdt.prop_str("compatible", "simple-bus")
    fdt.prop_empty("ranges")

    # docs/adr/0034: real ns16550a-compatible map, word-addressed (this
    # core's bus is exclusively full-word transactions) -- reg-shift=2/
    # reg-io-width=4 tells the 8250 driver each register is a 4-byte-wide
    # word, 4 bytes apart, not the literal byte-adjacent layout a
    # byte-wide bus would use.
    fdt.begin_node("uart@10000000")
    fdt.prop_str("compatible", "ns16550a")
    fdt.prop_cells("reg", [0, 0x10000000, 0, 0x20])
    fdt.prop_u32("clock-frequency", uart_clock_freq)
    fdt.prop_u32("reg-shift", 2)
    fdt.prop_u32("reg-io-width", 4)
    fdt.end_node()

    # docs/adr/0034: real CLINT-compatible map (msip/mtimecmp/mtime at the
    # exact byte offsets Linux's own timer-clint.c hardcodes).
    fdt.begin_node("clint@10100000")
    fdt.prop_str("compatible", "riscv,clint0")
    fdt.prop_cells("reg", [0, 0x10100000, 0, 0x10000])
    fdt.prop_cells("interrupts-extended", [2, 3, 2, 7])  # phandle 2 (intc) -- cause 3 (MSI), cause 7 (MTI)
    fdt.end_node()

    fdt.end_node()  # soc

    fdt.begin_node("chosen")
    fdt.prop_str("bootargs", bootargs)
    fdt.prop_str("stdout-path", "/soc/uart@10000000")
    if initrd_start is not None and initrd_end is not None:
        # Real property names/types the kernel's own init/initramfs.c
        # binding expects: two cells each (#address-cells=2 at the root),
        # physical addresses, end is exclusive (one past the last byte).
        fdt.prop_cells("linux,initrd-start", [initrd_start >> 32, initrd_start & 0xFFFFFFFF])
        fdt.prop_cells("linux,initrd-end", [initrd_end >> 32, initrd_end & 0xFFFFFFFF])
    fdt.end_node()

    fdt.end_node()  # root

    return fdt.build()


def parse_and_validate(blob: bytes):
    """Round-trip self-check -- no dtc to cross-check against, so this
    parses the emitted blob back with fresh, independent logic (not just
    re-running the same builder) and confirms real structural invariants:
    header fields agree with the blob's own actual layout, the structure
    block's BEGIN_NODE/END_NODE tokens balance, every PROP's declared
    length/nameoff lands inside the blob, and a real FDT_END token
    terminates the structure block. Raises AssertionError with a specific
    message on any mismatch -- this project's own "verify by running, not
    by construction alone" bar for a binary format."""
    magic, totalsize, off_struct, off_strings, off_rsvmap, version, last_comp, boot_cpuid, size_strings, size_struct = \
        struct.unpack(">10I", blob[:40])
    assert magic == FDT_MAGIC, f"bad magic: {magic:#x}"
    assert totalsize == len(blob), f"totalsize {totalsize} != actual blob length {len(blob)}"
    assert off_rsvmap == 40, f"off_mem_rsvmap {off_rsvmap} != 40 (fixed header size)"
    assert off_struct == off_rsvmap + 16, "off_dt_struct doesn't immediately follow the (one-entry) rsvmap"
    assert off_strings == off_struct + size_struct, "off_dt_strings doesn't immediately follow the struct block"
    assert off_strings + size_strings == totalsize, "strings block doesn't end exactly at totalsize"

    rsvmap_addr, rsvmap_size = struct.unpack(">QQ", blob[off_rsvmap:off_rsvmap + 16])
    assert rsvmap_addr == 0 and rsvmap_size == 0, "rsvmap not terminated by a (0,0) entry"

    struct_bytes = blob[off_struct:off_struct + size_struct]
    strings_bytes = blob[off_strings:off_strings + size_strings]

    depth = 0
    max_depth = 0
    i = 0
    prop_count = 0
    saw_end = False
    while i < len(struct_bytes):
        (tok,) = struct.unpack(">I", struct_bytes[i:i + 4])
        i += 4
        if tok == FDT_BEGIN_NODE:
            depth += 1
            max_depth = max(max_depth, depth)
            end = struct_bytes.index(b"\x00", i)
            name_len = end - i + 1
            i += (name_len + 3) & ~3
        elif tok == FDT_END_NODE:
            depth -= 1
            assert depth >= 0, "END_NODE with no matching BEGIN_NODE"
        elif tok == FDT_PROP:
            prop_count += 1
            (plen, nameoff) = struct.unpack(">II", struct_bytes[i:i + 8])
            i += 8
            assert nameoff < len(strings_bytes), f"prop nameoff {nameoff} outside strings block"
            i += (plen + 3) & ~3
        elif tok == FDT_END:
            saw_end = True
            break
        else:
            raise AssertionError(f"unknown structure token {tok:#x} at struct-block offset {i-4}")
    assert depth == 0, f"unbalanced BEGIN_NODE/END_NODE, final depth {depth}"
    assert saw_end, "structure block never reached FDT_END"
    assert max_depth >= 2, f"suspiciously shallow tree (max_depth={max_depth}) -- did node emission actually run?"
    assert prop_count > 0, "zero properties emitted"
    return {"max_depth": max_depth, "prop_count": prop_count, "totalsize": totalsize}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--mem-size", type=int, default=0x2000000, help="bytes, /memory@0's own reg size")
    ap.add_argument("--timebase-freq", type=int, default=1000000)
    ap.add_argument("--uart-clock-freq", type=int, default=1843200)
    ap.add_argument("--bootargs", default="console=ttyS0 earlycon")
    ap.add_argument("--initrd-start", type=lambda s: int(s, 0), default=None)
    ap.add_argument("--initrd-end", type=lambda s: int(s, 0), default=None)
    args = ap.parse_args()

    blob = build_this_core_dtb(args.mem_size, args.timebase_freq, args.uart_clock_freq,
                                args.bootargs, args.initrd_start, args.initrd_end)
    info = parse_and_validate(blob)
    with open(args.out, "wb") as f:
        f.write(blob)
    print(f"{args.out}: {len(blob)} bytes, self-check passed ({info})")


if __name__ == "__main__":
    main()
