/*
 * Linker script for compiled-C programs targeting this core (docs/ROADMAP.md
 * Phase 10 -- real CoreMark/Dhrystone, following up on the hand-written
 * sim/benchmarks/bench_*.s kernels).
 *
 * This core is Harvard architecture, not the unified address space a
 * standard RISC-V linker script assumes: design/InstructionMemory.v (PC
 * fetches) and design/DataMemoryBRAM.v (load/store addresses) are two
 * completely independent, zero-based byte arrays -- there is no single
 * "0x0" that means the same physical memory for both instruction fetch and
 * data access, the way there is on a real von Neumann RISC-V target.
 *
 * IMEM and DMEM are both zero-based (ORIGIN = 0x0) -- deliberately, and
 * this is the second attempt at getting that right, not the first. The
 * *code* the compiler generates (la/lw/sw immediates, auipc+addi pairs)
 * bakes in whatever absolute address the linker assigns each symbol, and
 * that address is exactly what design/DataMemoryBRAM.v will be asked to
 * index with at runtime -- it MUST be a small, zero-based value matching
 * the real array bounds, or every data access silently indexes outside
 * `data_memory[0:SIZE_BYTES-1]` (verified directly: a first attempt gave
 * .data a distinct nonzero *origin*, `1000xxxx`, to dodge a linker error,
 * and the compiled code then computed addresses like 0x10000020 for a
 * global variable -- garbage/X-valued reads and writes at simulation time,
 * caught by an actual run producing an X in the register dump, not by
 * reasoning about the linker script).
 *
 * `ld` refuses to place two *load* addresses (LMAs) at the same value
 * ("section .data LMA overlaps section .text LMA") even though the two
 * sections are headed for physically separate memories it has no concept
 * of -- but LMA and VMA (execution address, what the code actually
 * computes) are independently settable. `AT(DMEM_LMA)` below gives .data a
 * distinct, non-overlapping LMA purely to satisfy that check, while its
 * VMA (via `> DMEM`, ORIGIN 0x0) stays exactly what the compiled code
 * needs. sim/tools/elf2mem.py extracts by LMA (`objcopy -O binary`'s
 * default), which conveniently starts at 0 within the .data-only slice
 * regardless of DMEM_LMA's actual value -- no address translation of our
 * own needed there at all.
 *
 * IMEM_SIZE/DMEM_SIZE must match whatever MEM_SIZE_BYTES the RTL
 * testbench instantiates PIPELINED with (docs/adr/0012, 0015) -- both
 * memories share that single parameter in the current design, so both
 * regions here use the same size for simplicity; sim/tools/elf2mem.py
 * checks neither section actually exceeds it. DMEM_LMA/RODATA_LMA must
 * stay comfortably larger than IMEM_SIZE, and distinct from each other,
 * so the LMA checks never genuinely collide regardless of size changes --
 * it is bookkeeping only, never seen by the compiled code or by
 * design/DataMemoryBRAM.v.
 *
 * .rodata lives in DMEM, not IMEM -- found by actually running Dhrystone
 * and hitting a real infinite loop, not reasoned out in advance. .rodata
 * (string literals, const arrays) is never instruction-fetched; it's read
 * with ordinary load instructions, which this core routes to
 * design/DataMemoryBRAM.v, never design/InstructionMemory.v. Placing it
 * in IMEM (this file's first version) meant every load from a string
 * literal or const array silently read zeroed DMEM instead of the real
 * bytes -- invisible to smoke_test.c and CoreMark's port (neither reads
 * a string literal via a load; CoreMark's ee_printf stub never
 * dereferences its format-string argument), but fatal to Dhrystone's
 * strcpy() of its string-literal test data, which produced empty strings
 * and sent Func_2's `while (Int_Loc <= 2) if (...) Int_Loc += 1;` loop
 * into a genuine infinite loop on the corrupted comparison. Verified via
 * a debug testbench showing the DUT permanently stuck redirecting into
 * the same tiny address range.
 */

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    DMEM (rw)  : ORIGIN = 0x00000000, LENGTH = 32K
}

RODATA_LMA = 0x10000000;
DMEM_LMA   = 0x10002000;

SECTIONS
{
    .text : {
        *(.text.init)   /* crt0.S's _start goes first */
        *(.text*)
    } > IMEM

    /* .rodata and .data each get their own LMA, both distinct from .text's
     * and from each other -- sim/tools/elf2mem.py extracts each of them
     * as an independent, single-section objcopy call (each returning just
     * that section's own bytes, at whatever size it actually is) and
     * places them into the output image at their real *VMA* offsets
     * (read from the _rodata_start/_data_start symbols below via `nm`),
     * not by relying on objcopy's combined-multi-section-by-LMA layout.
     * An earlier version gave .data no explicit AT() at all, expecting it
     * to inherit a contiguous LMA right after .rodata -- that broke for
     * any program with an *empty* .rodata (section skipped entirely, so
     * .data fell back to LMA==VMA==0 and collided with .text). A version
     * before that gave both sections real but far-apart LMAs and asked
     * objcopy to extract both *together* -- since `-O binary` lays out a
     * multi-section extraction by absolute LMA, two far-apart LMAs made
     * the "combined" output span the entire gap between them, zero-padded
     * (a 32KB region briefly became ~256MB). Extracting each section on
     * its own sidesteps both failure modes -- the LMA values here only
     * need to avoid colliding with .text's or each other's, nothing more. */
    .rodata : AT(RODATA_LMA) {
        _rodata_start = .;
        *(.rodata*)
        _rodata_end = .;
    } > DMEM

    .data : AT(DMEM_LMA) {
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

    . = ALIGN(4);
    _heap_start = .;
    _stack_top = ORIGIN(DMEM) + LENGTH(DMEM);

    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
