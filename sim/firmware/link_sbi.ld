/*
 * Linker script for Phase S's M-mode SBI firmware + its own S-mode test
 * payload (docs/adr/0035-minimal-sbi-firmware-phase-s.md). Same Harvard
 * IMEM/DMEM shape sim/benchmarks/c/link.ld already proved out for ordinary
 * userspace C programs (see that file's own header comment for the real
 * gotchas found by running: zero-based VMAs, .rodata-must-live-in-DMEM,
 * LMA-only bookkeeping for extraction) -- this phase adds a SECOND fixed
 * .text region inside IMEM, since firmware and the S-mode payload are two
 * logically separate programs sharing one linked ELF (this core has no ELF
 * loader; both need to already be real, fetchable bytes in one combined
 * InstructionMemory.v image, not two).
 *
 * boot.S's own _start (M-mode firmware entry) MUST land at VMA 0 -- this
 * core's real PC reset value (design/PC.v: `pc_o <= {XLEN{1'b0}}` on
 * reset), not a convention this script invents.
 */

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    DMEM (rw)  : ORIGIN = 0x00000000, LENGTH = 32K
}

PAYLOAD_BASE = 0x2000;  /* comfortably clear of firmware's own .text.boot */
DTB_ADDR     = 0x4000;  /* DMEM offset -- gen_dtb.py's output is overlaid here post-link, not linker-placed */

RODATA_LMA = 0x10000000;
DATA_LMA   = 0x10002000;

SECTIONS
{
    /* Firmware code region: the hand-written asm's own named sections, plus
     * sbi.c's compiler-generated code, selected by object-file name (a real
     * GNU ld feature -- not by generic *(.text*), which would also match
     * payload.c's own compiled code and place it here by accident). */
    .text.boot : {
        *(.text.boot)
        *(.text.trap)
        *sbi.o(.text*)
    } > IMEM

    /* An explicit address after the section name (not a plain `. = ...;`
     * assignment) is the correct way to force an exact VMA under memory-
     * region placement -- a `. = PAYLOAD_BASE;` between two `> IMEM`
     * sections does NOT reposition IMEM's own region cursor (confirmed by
     * building and reading the actual section headers: a first attempt
     * this way put .text.payload right after .text.boot ended, ignoring
     * PAYLOAD_BASE entirely). `> IMEM` is kept for its own real value
     * (bounds/overflow checking against the region), even though the
     * explicit address is what actually places it. */
    .text.payload PAYLOAD_BASE : {
        *(.text.payload)   /* payload_start.S's own _payload_start goes first, must be the region's first byte */
        *payload.o(.text*)
    } > IMEM

    .rodata : AT(RODATA_LMA) {
        _rodata_start = .;
        *(.rodata*)
        _rodata_end = .;
    } > DMEM

    .data : AT(DATA_LMA) {
        _data_start = .;
        *(.data*)
        _data_end = .;
    } > DMEM

    .bss : {
        _bss_start = .;
        *(.bss*)
        *(COMMON)
        _bss_end = .;
    } > DMEM

    /* Two separate stacks, not one shared top: a trap can occur while the
     * payload has live stack frames below _stack_top, and trap_entry.S's
     * own sbi_dispatch() C call needs stack space of its own -- sharing
     * one top would let the trap handler's growth stomp on the payload's
     * own still-live frames the instant it resumes. _stack_top (boot.S's
     * initial M-mode setup, then the S-mode payload's own C stack) and
     * _trap_stack_top (trap_entry.S's own, dedicated) are fully disjoint. */
    . = ALIGN(8);
    _stack_top = ORIGIN(DMEM) + LENGTH(DMEM) - 0x400;
    _trap_stack_top = ORIGIN(DMEM) + LENGTH(DMEM);

    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
