# docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R). Directed
# test: a machine-software interrupt (mip.MSIP, driven by the new CLINT
# `msip` register) fires mid-loop -- mirrors timer_interrupt.s's own shape
# and reasoning exactly, just with a new source. Unlike Timer.v's mtimecmp
# (which starts at 0 and is already "expired," needing an explicit defuse
# before arming), msip resets to 0 (not pending) -- no defuse step needed
# before the deliberate write below. The handler clears msip back to 0
# before mret, the real CLINT convention for acknowledging a software
# interrupt (mip.MSIP has no other software clear path, exactly mirroring
# mip.MTIP's own "no clear except reprogramming the source" shape).
# Layout: loop = [32, 68], self = 72, handler = 76
lui   x2, 0x10100  # 0: x2 = TIMER_BASE (CLINT_OFF_MSIP == 0, so this IS the msip address)
addi  x5, x0, 76  # 4: x5 = handler address (76)
csrrw x0, mtvec, x5  # 8
addi  x6, x0, 8  # 12: 0x8 = MIE_MSIE_BIT
csrrw x0, mie, x6  # 16: mie.MSIE <- 1
addi  x7, x0, 1  # 20
sw    x7, 0(x2)  # 24: CLINT.msip <- 1 -- mip.MSIP becomes pending immediately
csrrsi x0, mstatus, 8  # 28: mstatus.MIE <- 1 (armed last, after mtvec/mie/msip)
addi  x10, x10, 1  # 32
addi  x10, x10, 1  # 36
addi  x10, x10, 1  # 40
addi  x10, x10, 1  # 44
addi  x10, x10, 1  # 48
addi  x10, x10, 1  # 52
addi  x10, x10, 1  # 56
addi  x10, x10, 1  # 60
addi  x10, x10, 1  # 64
addi  x10, x10, 1  # 68
self:
jal   x0, self  # 72: spin once the loop completes
handler:
addi  x11, x0, 777  # 76: proves the handler ran
sw    x0, 0(x2)  # 80: CLINT.msip <- 0 -- clears the pending source, no other software clear path
mret  # 84
