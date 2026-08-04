/*
 * SBI ecall dispatch + machine-timer-interrupt forwarding
 * (docs/adr/0035-minimal-sbi-firmware-phase-s.md, extended
 * docs/adr/0036-linux-boot-attempt-phase-t.md). Called from trap_entry.S
 * with mcause and a pointer to the interrupted code's full saved register
 * file (regs[1..31] = x1..x31, a0..a7 = regs[10..17]).
 *
 * Phase S's own legacy-v0.1-only design (GET_SPEC_VERSION -> 0) is real
 * and kept (still answered below, still exercised by Phase S's own
 * S-mode test payload), but Phase T's research found a real gotcha: a
 * modern (post-2021) Linux kernel builds with `CONFIG_RISCV_SBI_V01=n` by
 * default, meaning the legacy EIDs are compiled OUT entirely -- a real
 * kernel needs GET_SPEC_VERSION to report >=0.2 and the real v0.2+
 * extension IDs (TIME/IPI/RFENCE, not the legacy 0-8 range) or its own
 * timer never works at all (no scheduling tick, hangs past early init).
 * Both v0.1 and v0.2+ are answered here, concurrently, real spec-legal
 * behavior mirroring what real OpenSBI itself does for backward compat --
 * SET_TIMER's underlying logic (write mtimecmp, clear mip.STIP) is
 * identical either way, factored into one shared helper. HSM is
 * deliberately NOT implemented -- confirmed via research: a single-hart
 * kernel falls back to RISCV_BOOT_SPINWAIT when HSM's own probe fails,
 * and with nothing to bring up, HSM's absence never blocks a genuinely
 * single-hart boot. Console (legacy EID 1/2, still real/working) also
 * isn't load-bearing for Phase T's own "reach first console output"
 * milestone -- `earlycon=uart8250,mmio,<UART_BASE>` on the kernel command
 * line drives the real ns16550a UART directly, bypassing SBI console
 * entirely (research-confirmed real technique).
 */
#include <stdint.h>
#include "sbi.h"
#include "uart_mmio.h"

#define REG_A0 10
#define REG_A1 11
#define REG_A2 12
#define REG_A6 16
#define REG_A7 17

#define SBI_SUCCESS       0L
#define SBI_ERR_NOT_SUPP (-2L)

#define SBI_EID_SET_TIMER          0x00
#define SBI_EID_CONSOLE_PUTCHAR    0x01
#define SBI_EID_CONSOLE_GETCHAR    0x02
#define SBI_EID_CLEAR_IPI          0x03
#define SBI_EID_SEND_IPI           0x04
#define SBI_EID_REMOTE_FENCE_I     0x05
#define SBI_EID_REMOTE_SFENCE_VMA  0x06
#define SBI_EID_REMOTE_SFENCE_ASID 0x07
#define SBI_EID_SHUTDOWN           0x08
#define SBI_EID_BASE               0x10

/* docs/adr/0036-linux-boot-attempt-phase-t.md. Real SBI v0.2+ extension
 * IDs (the literal 4-character ASCII codes the spec assigns, read as one
 * 32-bit value) -- what a modern kernel (CONFIG_RISCV_SBI_V01=n) actually
 * calls instead of the legacy 0-8 range above. */
#define SBI_EID_TIME    0x54494D45UL  /* "TIME" */
#define SBI_EID_IPI     0x00735049UL  /* "sPI"  */
#define SBI_EID_RFENCE  0x52464E43UL  /* "RFNC" */

#define SBI_TIME_SET_TIMER            0
#define SBI_IPI_SEND_IPI              0
#define SBI_RFENCE_REMOTE_FENCE_I     0
#define SBI_RFENCE_REMOTE_SFENCE_VMA  1
#define SBI_RFENCE_REMOTE_SFENCE_ASID 2

#define SBI_BASE_GET_SPEC_VERSION  0
#define SBI_BASE_GET_IMPL_ID       1
#define SBI_BASE_GET_IMPL_VERSION  2
#define SBI_BASE_PROBE_EXTENSION   3
#define SBI_BASE_GET_MVENDORID     4
#define SBI_BASE_GET_MARCHID       5
#define SBI_BASE_GET_MIMPID        6

/* docs/adr/0036: this firmware answers BOTH legacy v0.1 (GET_SPEC_VERSION
 * -> 0, Phase S's own design) and real v0.2+ (GET_SPEC_VERSION -> 2) --
 * which one a given boot sees is selected by SPEC_VERSION_TO_REPORT below,
 * a single build-time constant, not runtime-negotiated (the real spec
 * itself has no such negotiation -- a platform's firmware just reports
 * whatever it genuinely implements, once, and the kernel adapts). Phase
 * S's own existing S-mode test payload (tb_sbi_firmware_s7.v) exercises
 * the legacy path and must keep passing bit-for-bit; a real kernel needs
 * this flipped to 2 -- see build_sbi_firmware.py's own flag for how each
 * build selects it. */
#ifndef SPEC_VERSION_TO_REPORT
#define SPEC_VERSION_TO_REPORT 0
#endif

/* docs/adr/0034-uart-clint-register-compat-phase-r.md: real CLINT byte
 * offsets, msip always a plain 32-bit access, mtimecmp a genuine 64-bit
 * register at XLEN=64 (Timer.v's own XLEN>=64 single-write path). */
#define CLINT_BASE     0x10100000UL
#define CLINT_MSIP     (*(volatile uint32_t *)(CLINT_BASE + 0x0000UL))
#define CLINT_MTIMECMP (*(volatile uint64_t *)(CLINT_BASE + 0x4000UL))

/* mip bit positions (design/riscv_defs.vh) -- MIE_SSIE_BIT/MIE_STIE_BIT
 * name the *enable* bits, but mip's own pending bits share the identical
 * position per spec. */
#define MIP_SSIP_BIT 1
#define MIP_STIP_BIT 5

/* docs/adr/0011-csr-and-exceptions.md / docs/adr/0020: this core's own
 * mcause encoding -- confirmed by reading design/CSR.v directly, not
 * assumed spec-correct: `mcause <= {trap_is_interrupt, trap_cause[30:0]}`
 * is a 32-bit-wide RHS zero-extended into mcause's real XLEN-wide (64 at
 * RV64) register, so the interrupt bit lands at bit31 even at XLEN=64, NOT
 * real spec bit63. These constants match this core's actual behavior, not
 * the abstract RV64 spec (a real, documented deviation worth knowing if a
 * future phase ever chases spec-perfect RV64 mcause encoding). */
#define MCAUSE_ECALL_FROM_S        9UL
#define MCAUSE_INT_MACHINE_TIMER   0x80000007UL

static inline void mip_set(unsigned long mask) {
    __asm__ volatile("csrrs zero, mip, %0" : : "r"(mask));
}
static inline void mip_clear(unsigned long mask) {
    __asm__ volatile("csrrc zero, mip, %0" : : "r"(mask));
}

static void halt_forever(void) {
    for (;;) { }
}

/* Shared by legacy SET_TIMER (EID 0) and v0.2 TIME/SET_TIMER (EID "TIME",
 * FID 0) -- identical underlying action either way. */
static void set_timer(uint64_t target) {
    CLINT_MTIMECMP = target;
    mip_clear(1UL << MIP_STIP_BIT);
}

static void sbi_dispatch_ecall(unsigned long *regs) {
    unsigned long eid = regs[REG_A7];
    unsigned long fid = regs[REG_A6];
    unsigned long a0 = regs[REG_A0];
    unsigned long a1 = regs[REG_A1];

    long err = SBI_SUCCESS;
    unsigned long val = 0;

    switch (eid) {
    case SBI_EID_BASE:
        switch (fid) {
        case SBI_BASE_GET_SPEC_VERSION:
            /* docs/adr/0036: SPEC_VERSION_TO_REPORT selects legacy-v0.1
             * (0, Phase S's own default, still what tb_sbi_firmware_s7.v
             * exercises) or real v0.2 (2, encoded per spec as
             * major<<24|minor with major=0) -- a build-time constant, not
             * runtime-negotiated (real firmware just reports what it
             * genuinely implements, once). */
            val = SPEC_VERSION_TO_REPORT;
            break;
        case SBI_BASE_GET_IMPL_ID:
            val = 0x5350355253ULL;  /* arbitrary, non-colliding "hand-rolled Phase S" id */
            break;
        case SBI_BASE_GET_IMPL_VERSION:
            val = 1;
            break;
        case SBI_BASE_PROBE_EXTENSION: {
            /* Legacy EIDs (0-8) are only meaningful to probe under the
             * legacy signal -- a real v0.2+ kernel never calls probe with
             * them (it wires the new EIDs directly instead), but
             * reporting them present is still correct either way, since
             * this firmware genuinely answers both. TIME/IPI/RFENCE are
             * the real v0.2+ extensions docs/adr/0036 added; HSM
             * deliberately absent (0) -- confirmed via research not
             * needed for single-hart boot. */
            unsigned long probe_eid = a0;
            if (probe_eid <= SBI_EID_SHUTDOWN || probe_eid == SBI_EID_BASE ||
                probe_eid == SBI_EID_TIME || probe_eid == SBI_EID_IPI || probe_eid == SBI_EID_RFENCE)
                val = 1;
            else
                val = 0;
            break;
        }
        case SBI_BASE_GET_MVENDORID:
        case SBI_BASE_GET_MARCHID:
        case SBI_BASE_GET_MIMPID:
            val = 0;
            break;
        default:
            err = SBI_ERR_NOT_SUPP;
            break;
        }
        break;

    case SBI_EID_SET_TIMER:
        /* Legacy EID 0: arg0 is the target mtime value directly. */
        set_timer((uint64_t)a0);
        break;

    case SBI_EID_TIME:
        switch (fid) {
        case SBI_TIME_SET_TIMER:
            /* v0.2 TIME/FID0: same single 64-bit arg0, real spec
             * convention -- identical action to the legacy path. */
            set_timer((uint64_t)a0);
            break;
        default:
            err = SBI_ERR_NOT_SUPP;
            break;
        }
        break;

    case SBI_EID_CONSOLE_PUTCHAR:
        uart_putchar((char)a0);
        break;

    case SBI_EID_CONSOLE_GETCHAR:
        val = (unsigned long)(long)uart_getchar();
        break;

    case SBI_EID_CLEAR_IPI:
        mip_clear(1UL << MIP_SSIP_BIT);
        break;

    case SBI_EID_SEND_IPI: {
        /* Legacy convention: arg0 is a pointer to a hart-mask bitvector in
         * memory, not the mask itself. Single-hart (hart 0) only --
         * genuinely unreachable in this phase's own S-mode test (nothing
         * ever sends itself an IPI), kept real/spec-shaped regardless. */
        const volatile uint64_t *mask_ptr = (const volatile uint64_t *)a0;
        if (*mask_ptr & 1UL)
            mip_set(1UL << MIP_SSIP_BIT);
        break;
    }

    case SBI_EID_IPI:
        switch (fid) {
        case SBI_IPI_SEND_IPI:
            /* v0.2 IPI/FID0: hart_mask is a VALUE in a0 (not a pointer --
             * a real convention difference from the legacy SEND_IPI
             * above, so >64-hart systems can pass hart_mask_base in a1 to
             * select which 64-hart window a0's bits address). Single hart
             * (hart 0): bit0 of a0, with a1==0, is the only meaningful
             * case. */
            if ((a0 & 1UL) && a1 == 0)
                mip_set(1UL << MIP_SSIP_BIT);
            break;
        default:
            err = SBI_ERR_NOT_SUPP;
            break;
        }
        break;

    case SBI_EID_REMOTE_FENCE_I:
    case SBI_EID_REMOTE_SFENCE_VMA:
    case SBI_EID_REMOTE_SFENCE_ASID:
        /* No other hart's TLB/I$ to remotely flush -- real spec-legal
         * no-op for a genuinely single-hart system. */
        break;

    case SBI_EID_RFENCE:
        switch (fid) {
        case SBI_RFENCE_REMOTE_FENCE_I:
        case SBI_RFENCE_REMOTE_SFENCE_VMA:
        case SBI_RFENCE_REMOTE_SFENCE_ASID:
            /* Same real no-op reasoning as the legacy EIDs above. */
            break;
        default:
            err = SBI_ERR_NOT_SUPP;
            break;
        }
        break;

    case SBI_EID_SHUTDOWN:
        halt_forever();
        break;

    default:
        err = SBI_ERR_NOT_SUPP;
        break;
    }

    regs[REG_A0] = (unsigned long)err;
    regs[REG_A1] = val;
}

void sbi_dispatch(unsigned long mcause, unsigned long *regs) {
    if (mcause == MCAUSE_ECALL_FROM_S) {
        sbi_dispatch_ecall(regs);
        return;
    }

    if (mcause == MCAUSE_INT_MACHINE_TIMER) {
        /* docs/adr/0035's own real design point: a machine-timer
         * interrupt cannot be delegated to S the way a synchronous
         * exception can (mtimecmp is M-mode-only CLINT state) -- mask the
         * source (prevents an immediate re-fire the instant this mret's),
         * set mip.STIP (real, software-writable storage in CSR.v's
         * mip_sw, no RTL change needed), and return. S-mode then takes
         * its OWN trap on the synthesized pending STIP/STIE, exactly the
         * shape a real supervisor timer interrupt has. */
        CLINT_MTIMECMP = ~0ULL;
        mip_set(1UL << MIP_STIP_BIT);
        return;
    }

    /* Anything else (illegal instruction, misaligned access, page fault,
     * machine-software/-external interrupt) is not expected from this
     * phase's own S-mode test payload -- halt with a distinct, debuggable
     * signature rather than silently returning into who-knows-what state. */
    halt_forever();
}
