# docs/adr/00NN-mmu-sv32.md (Phase F1). Raw CSR addresses throughout (not
# added to asm.py's CSR_ADDR table), matching the fflags/frm/fcsr and
# mie/mip precedent for CSRs this project doesn't give assembler mnemonics
# to. Exercises: mstatus's new SIE/SPIE/SPP/MPP fields, sstatus as a
# restricted view onto them (a write through sstatus must never touch
# MIE/MPIE/MPP), mie/sie and mip/sip's same restricted-view relationship,
# and plain round-trip storage for a representative sample of the other
# new registers (stvec/sepc/satp -- sscratch/scause/stval/mtval share the
# exact same unmasked `reg <= new_val` code shape in CSR.v, verified by
# inspection rather than each getting its own redundant directed check;
# sim/run_tests.sh's 32-instruction/128-byte ceiling is the reason this
# test picks a representative sample instead of testing all nine).
#
# This test deliberately sets mstatus.MIE/mie.MTIE (real bits since
# docs/adr/0020) as part of exercising the new bits alongside them --
# Timer.v resets with `pending` already true (mtime=0 >= mtimecmp=0,
# docs/adr/0020's own tb_timer_unit.v finding), so a real machine-timer
# interrupt would otherwise fire mid-test once those two bits are set,
# corrupting every check after it (redirecting to mtvec=0, its own reset
# value). Disable it first by reprogramming MTIMECMP far out of reach,
# mirroring sim/programs/timer_interrupt.s's own handler doing exactly
# this for the identical reason. x1/x2 here are pure setup scratch, fully
# overwritten below -- neither is ever check_reg'd.
lui x1, 0x10000       # x1 = MMIO_BASE (0x10000000)
addi x1, x1, 16        # x1 = TIMER_BASE (UART_SIZE=16)
lui x2, 0xFFFFF        # x2 = 0xFFFFF000 -- far beyond any mtime this short test reaches
sw x2, 4(x1)           # TIMER.MTIMECMP <- huge: pending stays false for the rest of this test

addi x1, x0, -1      # x1 = 0xFFFFFFFF (all bits set)

# mstatus: writing all-1s sets every real bit (MIE/MPIE/SIE/SPIE/SPP/MPP).
csrrw x2, mstatus, x1   # x2 = old mstatus (0)
csrrs x3, mstatus, x0   # x3 = mstatus readback (all real bits set)

# sstatus is a restricted view: writing 0 through it must clear ONLY
# SIE/SPIE/SPP, leaving MIE/MPIE/MPP (set above) untouched.
csrrw x4, 0x100, x0     # x4 = old sstatus view (SIE/SPIE/SPP, before clearing)
csrrs x5, mstatus, x0   # x5 = mstatus readback (MIE/MPIE/MPP still set, SIE/SPIE/SPP now 0)
csrrs x6, 0x100, x0     # x6 = sstatus readback (0 -- confirms the clear took)

# mie: writing all-1s sets every real bit (MTIE/MEIE/SSIE/STIE/SEIE).
csrrw x7, mie, x1       # x7 = old mie (0)
csrrs x8, mie, x0       # x8 = mie readback (all real bits set)

# sie is the same restricted-view relationship as sstatus/mstatus.
csrrw x9, 0x104, x0      # x9 = old sie view (SSIE/STIE/SEIE, before clearing)
csrrs x10, mie, x0       # x10 = mie readback (MTIE/MEIE still set, SSIE/STIE/SEIE now 0)
csrrs x11, 0x104, x0     # x11 = sie readback (0)

# sip/mip share the same underlying software-writable bits (SSIP/STIP/SEIP)
# -- a write through sip must be visible through mip (with MTIP ORed on
# top, live-pending from Timer.v since reset) and vice versa.
csrrw x12, 0x144, x1     # x12 = old sip view (0 -- mip_sw starts at reset value 0)
csrrs x13, mip, x0       # x13 = mip readback (SSIP/STIP/SEIP from sip's write, ORed with live MTIP)
csrrs x14, 0x144, x0     # x14 = sip readback (SSIP/STIP/SEIP only, MTIP not in this view)

# Plain, unmasked round-trip storage -- representative sample (see header).
csrrw x15, 0x105, x1    # stvec
csrrs x16, 0x105, x0
csrrw x17, 0x141, x1    # sepc
csrrs x18, 0x141, x0
csrrw x19, 0x180, x1    # satp
csrrs x20, 0x180, x0

# mideleg/medeleg: only this core's own real cause bits survive a write.
# Both "old value" captures are skipped (always 0, first touch, already
# well-established elsewhere) -- discarded into x0 (always safe, x0 writes
# never actually commit) to free registers for both masked readbacks.
csrrw x0, 0x303, x1     # mideleg (old value discarded)
csrrs x21, 0x303, x0
csrrw x0, 0x302, x1     # medeleg (old value discarded)
csrrs x22, 0x302, x0

fence
halt:
jal x0, halt
