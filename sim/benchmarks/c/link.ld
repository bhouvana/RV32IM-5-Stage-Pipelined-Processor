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
 * checks neither section actually exceeds it. DMEM_LMA must stay
 * comfortably larger than IMEM_SIZE so the LMA check never genuinely
 * collides regardless of size changes -- it is bookkeeping only, never
 * seen by the compiled code or by design/DataMemoryBRAM.v.
 */

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    DMEM (rw)  : ORIGIN = 0x00000000, LENGTH = 32K
}

DMEM_LMA = 0x10000000;

SECTIONS
{
    .text : {
        *(.text.init)   /* crt0.S's _start goes first */
        *(.text*)
    } > IMEM

    .rodata : {
        *(.rodata*)
    } > IMEM

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
