/*
 * Minimal startup code for compiled-C programs on this core (docs/ROADMAP.md
 * Phase 10). No libc/newlib startup is used at all (-nostartfiles
 * -nostdlib, see the build script) -- this is the *entire* runtime
 * environment before main() runs.
 */
    .section .text.init
    .globl _start
_start:
    la      sp, _stack_top

    /* Zero .bss. Belt-and-suspenders: sim/tools/elf2mem.py already emits
     * zero bytes for this region and DataMemoryBRAM.v resets to zero on
     * its own (docs/adr/0013), but doing this in crt0 too is the standard,
     * portable practice and costs only a few instructions. */
    la      t0, _bss_start
    la      t1, _bss_end
1:
    bge     t0, t1, 2f
    sw      x0, 0(t0)
    addi    t0, t0, 4
    jal     x0, 1b
2:

    jal     ra, main

    /* main() returned -- spin forever instead of running off the end of
     * instruction memory (docs/adr/0011: opcode 0000000 traps as illegal,
     * not a harmless implicit nop). Same convention every hand-written
     * sim/programs/*.s and sim/benchmarks/*.s test uses. */
halt:
    jal     x0, halt
