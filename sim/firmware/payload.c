/*
 * S-mode test payload (docs/adr/0035-minimal-sbi-firmware-phase-s.md).
 * Exercises every SBI call path sbi.c implements, plus the real machine-
 * timer-interrupt-forwarding round trip (docs/adr/0035's own RTL fix:
 * riscvpipeline.v's new ssi_pending/sti_pending path). Every result is
 * written to a fixed, testbench-checkable memory address -- this is a
 * freestanding payload, not a program `check_reg`/`check_val` can inspect
 * via register numbers the compiler doesn't give us control over.
 */
#include <stdint.h>
#include "uart_mmio.h"

/* Fixed sentinel addresses (DMEM) -- chosen well clear of the linker-
 * placed .rodata/.data/.bss (tiny for this program) and the DTB blob
 * (link_sbi.ld's own DTB_ADDR=0x4000), with room to spare below
 * _stack_top. No `nm` lookup needed anywhere -- both this file and
 * tb_sbi_firmware_s7.v hardcode the same addresses directly. */
#define SENTINEL_BASE 0x6000UL
#define SENT_HART_ID       (*(volatile uint64_t *)(SENTINEL_BASE + 0x00))
#define SENT_DTB_ADDR      (*(volatile uint64_t *)(SENTINEL_BASE + 0x08))
#define SENT_DTB_MAGIC_OK  (*(volatile uint32_t *)(SENTINEL_BASE + 0x10))
#define SENT_SPEC_VERSION  (*(volatile uint32_t *)(SENTINEL_BASE + 0x14))
#define SENT_TIMER_OBSERVED (*(volatile uint32_t *)(SENTINEL_BASE + 0x18))
#define SENT_ALL_DONE      (*(volatile uint32_t *)(SENTINEL_BASE + 0x1C))

#define FDT_MAGIC 0xd00dfeedUL

#define SBI_EID_SET_TIMER       0x00UL
#define SBI_EID_CONSOLE_PUTCHAR 0x01UL
#define SBI_EID_BASE            0x10UL
#define SBI_BASE_GET_SPEC_VERSION 0UL

/* mie/sie bit position (design/riscv_defs.vh MIE_STIE_BIT). */
#define SIE_STIE_BIT 5
#define SSTATUS_SIE_BIT 1

static inline unsigned long sbi_ecall(unsigned long eid, unsigned long fid,
                                       unsigned long a0, unsigned long a1) {
    register unsigned long r_a0 __asm__("a0") = a0;
    register unsigned long r_a1 __asm__("a1") = a1;
    register unsigned long r_a6 __asm__("a6") = fid;
    register unsigned long r_a7 __asm__("a7") = eid;
    __asm__ volatile("ecall"
                      : "+r"(r_a0), "+r"(r_a1)
                      : "r"(r_a6), "r"(r_a7)
                      : "memory");
    return r_a0;
}

static uint32_t read_be32(const volatile uint8_t *p) {
    /* FDT wire format is always big-endian, independent of the target's
     * own byte order -- DataMemoryBRAM.v's own loads are real little-
     * endian (sim/tools/elf2mem.py's own documented finding), so a naive
     * uint32_t* dereference here would read the DTB's own magic number
     * byte-swapped. Manual byte reconstruction is correct regardless of
     * the host's own endianness, the same technique a real libfdt uses. */
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* S-mode's own trap handler -- GCC's RISC-V interrupt attribute generates
 * a correctly-scoped save/restore (only the registers this body actually
 * clobbers, pushed onto the CURRENT stack) and the real `sret` return,
 * verified directly against this exact compiler before relying on it
 * (docs/adr/0035's own build log). No argument-passing complexity needed
 * here (unlike the M-mode SBI trap, which must reliably forward arbitrary
 * ecall arguments -- trap_entry.S stays hand-written for that reason). */
__attribute__((interrupt("supervisor")))
void s_trap_handler(void) {
    unsigned long scause;
    __asm__ volatile("csrr %0, scause" : "=r"(scause));

    /* docs/adr/0035's own real mcause encoding note (design/CSR.v: the
     * interrupt bit lands at bit31 even at XLEN=64, zero-extended from a
     * 32-bit-wide RHS) -- scause is populated identically. */
    if (scause == 0x80000005UL) {  /* MCAUSE_INT_SUPERVISOR_TIMER, interrupt bit set */
        SENT_TIMER_OBSERVED = 1;
        /* Real SBI convention: SET_TIMER again is how S-mode acknowledges/
         * re-arms -- sbi.c's own SET_TIMER handler also clears mip.STIP as
         * part of this, so the interrupt doesn't immediately re-fire the
         * instant sret returns. A huge target means "don't fire again." */
        sbi_ecall(SBI_EID_SET_TIMER, 0, ~0UL, 0);
    }
}

void payload_main(unsigned long hart_id, unsigned long dtb_addr) {
    SENT_HART_ID = hart_id;
    SENT_DTB_ADDR = dtb_addr;

    uint32_t magic = read_be32((const volatile uint8_t *)dtb_addr);
    SENT_DTB_MAGIC_OK = (magic == FDT_MAGIC) ? 1 : 0;

    unsigned long spec_version = sbi_ecall(SBI_EID_BASE, SBI_BASE_GET_SPEC_VERSION, 0, 0);
    SENT_SPEC_VERSION = (uint32_t)spec_version;

    const char msg[] = "OK\n";
    for (int i = 0; msg[i]; i++)
        sbi_ecall(SBI_EID_CONSOLE_PUTCHAR, 0, (unsigned long)(unsigned char)msg[i], 0);

    /* Arm the S-mode trap vector, enable STIE + sstatus.SIE, then ask
     * firmware (via SET_TIMER) to arm a small, quickly-reachable target --
     * mtimecmp itself is M-mode-only CLINT state, this ecall is the only
     * path S-mode has to it. A real machine-timer interrupt should fire,
     * get forwarded by sbi_dispatch into a synthesized STIP, and
     * riscvpipeline.v's own new sti_pending path (docs/adr/0035) should
     * retrap directly into s_trap_handler above. */
    extern void s_trap_handler(void);
    unsigned long stvec_val = (unsigned long)&s_trap_handler;
    __asm__ volatile("csrw stvec, %0" : : "r"(stvec_val));
    __asm__ volatile("csrrs zero, sie, %0" : : "r"(1UL << SIE_STIE_BIT));
    __asm__ volatile("csrrs zero, sstatus, %0" : : "r"(1UL << SSTATUS_SIE_BIT));

    sbi_ecall(SBI_EID_SET_TIMER, 0, 200, 0);

    /* Busy-wait for the retrap -- a generous bound, not an infinite loop,
     * so a genuine failure (the RTL fix not actually working) shows up as
     * this loop exhausting rather than the whole simulation hanging
     * forever. */
    for (volatile long i = 0; i < 2000000L && !SENT_TIMER_OBSERVED; i++) { }

    SENT_ALL_DONE = 1;
    for (;;) { }
}
