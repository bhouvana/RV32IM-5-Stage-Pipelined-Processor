/*
 * M-mode trap vector (docs/adr/0035-minimal-sbi-firmware-phase-s.md).
 * Direct mode (mtvec bits[1:0]=00, boot.S's own setup) -- every trap
 * (ecall, exception, interrupt) enters here. Conservatively saves/restores
 * every general-purpose register (not just what sbi_dispatch's own C
 * calling convention clobbers) -- this handler must not assume anything
 * about what's live in the code it interrupted, the same discipline a real
 * M-mode firmware needs (this is the payload's own trap path today, a real
 * kernel's tomorrow).
 *
 * mscratch holds trap_scratch's own base address (boot.S's own setup) --
 * the standard "swap a register into a CSR to get a scratch pointer before
 * anything else is safe to touch" M-mode trap-entry idiom, since a trap can
 * occur with every GP register live and this handler has no register of
 * its own to spill into otherwise.
 */
    .section .text.trap
    .align 4
    .globl trap_entry
trap_entry:
    csrrw   x5, mscratch, x5      /* x5 <- trap_scratch base; mscratch <- interrupted code's own x5 */
    sd      x1,  1*8(x5)
    sd      x2,  2*8(x5)
    sd      x3,  3*8(x5)
    sd      x4,  4*8(x5)
    sd      x6,  6*8(x5)
    sd      x7,  7*8(x5)
    sd      x8,  8*8(x5)
    sd      x9,  9*8(x5)
    sd      x10, 10*8(x5)
    sd      x11, 11*8(x5)
    sd      x12, 12*8(x5)
    sd      x13, 13*8(x5)
    sd      x14, 14*8(x5)
    sd      x15, 15*8(x5)
    sd      x16, 16*8(x5)
    sd      x17, 17*8(x5)
    sd      x18, 18*8(x5)
    sd      x19, 19*8(x5)
    sd      x20, 20*8(x5)
    sd      x21, 21*8(x5)
    sd      x22, 22*8(x5)
    sd      x23, 23*8(x5)
    sd      x24, 24*8(x5)
    sd      x25, 25*8(x5)
    sd      x26, 26*8(x5)
    sd      x27, 27*8(x5)
    sd      x28, 28*8(x5)
    sd      x29, 29*8(x5)
    sd      x30, 30*8(x5)
    sd      x31, 31*8(x5)
    csrr    x6, mscratch           /* x6 <- interrupted code's original x5 (stashed there by the swap above) */
    sd      x6,  5*8(x5)
    csrw    mscratch, x5           /* re-arm mscratch for the NEXT trap, now that x5 itself is safely saved */

    /* Firmware's own private, dedicated stack for the C call below -- the
     * interrupted code's real sp is already saved (slot 2, x2) and will be
     * restored verbatim before mret, so repointing the physical sp
     * register here is safe. _trap_stack_top, NOT _stack_top -- the
     * payload may have live frames below _stack_top at trap time (see
     * link_sbi.ld's own comment on why these are two disjoint regions). */
    la      sp, _trap_stack_top

    /* x5 (t0) is this handler's OWN scratch-base pointer, still needed
     * AFTER sbi_dispatch() returns (every load in the restore sequence
     * below uses it) -- but t0 is CALLER-SAVED under the standard RISC-V
     * ABI, and sbi_dispatch is an ordinary C function free to clobber it
     * internally as its own temporary. A real bug found by running, not
     * anticipated: the first ecall (GET_SPEC_VERSION) appeared to work,
     * but its own restore sequence was already silently using a
     * clobbered x5, corrupting every register the "restore" claimed to
     * restore -- invisible until the SECOND ecall retrapped from a
     * corrupted return address instead of ever reaching straight-line
     * code after the first one. Pushed onto this handler's own private
     * stack (_trap_stack_top, not the interrupted code's stack) across
     * the call, the same as any other caller-saved value a function call
     * needs preserved past it. */
    addi    sp, sp, -16
    sd      x5, 0(sp)

    /* sbi_dispatch(mcause, regs_base) -- C reads a0..a7 (regs[10..17]) and
     * writes the SBI return values back into regs[10]/regs[11] in place,
     * avoiding any ABI struct-return complexity. */
    csrr    a0, mcause
    mv      a1, x5
    call    sbi_dispatch

    ld      x5, 0(sp)
    addi    sp, sp, 16

    /* Only a synchronous ecall-from-S (mcause==9, the exception cause, not
     * an interrupt -- bit63 clear) skips past the ecall instruction itself
     * on return (the universal ecall convention this project's own
     * tb_mret_return.v/tb_ecall_trap.v already established). Every other
     * cause (including the machine-timer-interrupt forward path
     * sbi_dispatch itself handles) resumes at the exact interrupted
     * instruction -- real interrupt semantics, no adjustment.
     *
     * t1/t2 (x6/x7), NOT t0 (x5) -- a real bug found by running, not
     * anticipated: t0 IS x5, this handler's own scratch-base pointer for
     * the restore sequence right below. Using t0 here (the "obvious"
     * scratch choice, before realizing the collision) clobbered it right
     * before every restore load below used it as a base address, making
     * every single register restore -- not just this handler's own
     * bookkeeping -- silently wrong from the very first ecall onward,
     * invisible until a SECOND ecall retrapped from a corrupted return
     * address instead of ever reaching straight-line code after the
     * first one. */
    csrr    t1, mcause
    li      t2, 9
    bne     t1, t2, 1f
    csrr    t1, mepc
    addi    t1, t1, 4
    csrw    mepc, t1
1:

    ld      x1,  1*8(x5)
    ld      x2,  2*8(x5)
    ld      x3,  3*8(x5)
    ld      x4,  4*8(x5)
    ld      x6,  6*8(x5)
    ld      x7,  7*8(x5)
    ld      x8,  8*8(x5)
    ld      x9,  9*8(x5)
    ld      x10, 10*8(x5)
    ld      x11, 11*8(x5)
    ld      x12, 12*8(x5)
    ld      x13, 13*8(x5)
    ld      x14, 14*8(x5)
    ld      x15, 15*8(x5)
    ld      x16, 16*8(x5)
    ld      x17, 17*8(x5)
    ld      x18, 18*8(x5)
    ld      x19, 19*8(x5)
    ld      x20, 20*8(x5)
    ld      x21, 21*8(x5)
    ld      x22, 22*8(x5)
    ld      x23, 23*8(x5)
    ld      x24, 24*8(x5)
    ld      x25, 25*8(x5)
    ld      x26, 26*8(x5)
    ld      x27, 27*8(x5)
    ld      x28, 28*8(x5)
    ld      x29, 29*8(x5)
    ld      x30, 30*8(x5)
    ld      x31, 31*8(x5)
    ld      x5,  5*8(x5)            /* must be last -- x5 itself is the base pointer every load above used */

    mret

    .section .bss
    .align 3
    .globl trap_scratch
trap_scratch:
    .space 32*8   /* slots 1..31 used (x1-x31); slot 0 unused (x0 is hardwired zero) */
