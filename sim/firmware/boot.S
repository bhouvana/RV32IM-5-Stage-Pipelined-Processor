/*
 * M-mode SBI firmware entry (docs/adr/0035-minimal-sbi-firmware-phase-s.md).
 * Linked at VMA 0 -- this core's real PC reset value (design/PC.v). Sets up
 * the trap vector, zeroes .bss, then constructs the real M->S mode switch
 * the RISC-V privileged spec defines (mstatus.MPP=S, mepc=payload entry,
 * satp=Bare, mret) -- confirmed via research against the real kernel boot
 * protocol (a0=hart id, a1=DTB physical address on entry, satp=0 required).
 */
    .section .text.boot
    .globl _start
_start:
    la      sp, _stack_top

    /* Zero .bss, 8 bytes at a time (RV64) -- mirrors sim/benchmarks/c/
     * crt0.S's own belt-and-suspenders zeroing (DataMemoryBRAM.v already
     * resets to zero, this is standard practice regardless). */
    la      t0, _bss_start
    la      t1, _bss_end
1:
    bge     t0, t1, 2f
    sd      x0, 0(t0)
    addi    t0, t0, 8
    jal     x0, 1b
2:

    /* mtvec <- trap_entry, direct mode (bits[1:0]=00, trap_entry's own
     * linked address is naturally 4-byte-aligned so this needs no masking). */
    la      t0, trap_entry
    csrw    mtvec, t0

    /* mscratch <- trap_scratch's own base address -- the real "swap one
     * register into a CSR to get a scratch pointer before anything else is
     * safe to touch" idiom trap_entry.S's own save/restore sequence needs
     * (standard M-mode trap-entry practice; a trap can occur with every GP
     * register live and no bank of its own to spill into). */
    la      t0, trap_scratch
    csrw    mscratch, t0

    /* mstatus.MPP <- PRIV_S (01) -- clear bits[12:11] then set bit11 only.
     * mstatus.MPIE <- 1 (bit7) too: mret's own real semantics restore
     * mstatus.MIE from MPIE (and set MPIE<-1) -- without this, MIE stays
     * the reset value (0) once in S-mode, and the REAL machine-timer
     * interrupt (mti_pending, gated on mstatus_mie) could never be
     * recognized at all regardless of mie.MTIE below. M-mode's own SBI
     * TIME-extension design needs mstatus.MIE=1 to hold *permanently*
     * once in S-mode (this firmware never touches it again) -- it's the
     * real machine-level interrupt source's own always-on posture, not
     * something S-mode's own sstatus.SIE has any bearing on. */
    li      t0, 0x1800
    csrc    mstatus, t0
    li      t0, 0x0880
    csrs    mstatus, t0

    /* mie.MTIE <- 1 (bit7) -- M-mode's own machine-timer-interrupt enable.
     * A real, necessary firmware step this phase's own debugging found
     * missing: without it, the REAL hardware timer interrupt (Timer.v's
     * own `pending`) never traps into M-mode at all, so sbi_dispatch's
     * own mask-and-forward-to-STIP logic (docs/adr/0035) never runs --
     * M-mode must always intercept the real source for its whole SBI
     * TIME-extension design to work, independent of whether S-mode has
     * enabled its own synthesized sie.STIE yet. */
    li      t0, 0x80
    csrs    mie, t0

    /* mepc <- target entry point. Defaults to PAYLOAD_BASE (Phase S's own
     * S-mode test payload); docs/adr/0036's own real-kernel-boot build
     * overrides via -DKERNEL_ENTRY=<addr> to jump into the real Linux
     * Image's own load address instead -- same firmware, different target,
     * not a second boot stub. */
#ifndef KERNEL_ENTRY
#define KERNEL_ENTRY 0x2000
#endif
    li      t0, KERNEL_ENTRY
    csrw    mepc, t0

    /* mideleg <- SSIE|STIE (bits 1,5) -- delegates the software-synthesized
     * supervisor software/timer interrupts (docs/adr/0035's own new
     * ssi_pending/sti_pending path in riscvpipeline.v) to S's own
     * stvec/scause. Real spec MTIE/MEIE (bits 7,11) deliberately NOT
     * delegated here -- this firmware's whole SBI TIME-extension design
     * relies on M-mode always intercepting the REAL machine timer first
     * and manually synthesizing STIP (sbi.c's own sbi_dispatch), not on
     * real hardware delegation. */
    li      t0, 0x22
    csrw    mideleg, t0

    /* satp <- 0 (Bare) -- real spec requirement for the target mode's own
     * entry (docs/adr/0035's own research: "the MMU, if present, must be
     * disabled" on kernel/payload entry). */
    csrw    satp, x0

    /* a0 <- hart id (0, this core is single-hart), a1 <- DTB physical
     * address (DMEM offset 0x4000, gen_dtb.py's own output, overlaid into
     * dmem.mem post-link by build_sbi_firmware.py -- see link_sbi.ld's
     * own DTB_ADDR). Real kernel/payload entry convention (docs/adr/0035's
     * research). */
#ifndef KERNEL_DTB_ADDR
#define KERNEL_DTB_ADDR 0x4000
#endif
    li      a0, 0
    li      a1, KERNEL_DTB_ADDR

    mret
