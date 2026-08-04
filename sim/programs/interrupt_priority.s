# docs/adr/0020-soc-integration.md (Phase D9). Directed test: spec-mandated
# machine-external-over-machine-timer priority when both sources are
# pending and enabled simultaneously. Both mie.MTIE and mie.MEIE are
# enabled; MTIMECMP is set small so mip.MTIP is pending almost immediately;
# the testbench drives a UART byte in early enough (plus a run of spacer
# NOPs here) that mip.MEIP is also already pending by the time
# mstatus.MIE is finally armed. The interrupt actually taken must be the
# external one (mcause's low bits = 11, not 7) -- interrupt_taken's own
# mei_pending-checked-first ternary in riscvpipeline.v is what this test
# exercises.
# Layout: self = 92, handler = 96
lui   x1, 0x10000  # 0: x1 = UART_BASE = MMIO_BASE
lui   x2, 0x10104  # 4: x2 = TIMER_BASE + CLINT_OFF_MTIMECMP = 0x1010_4000 (MTIMECMP low, Phase R)
addi  x5, x0, 96  # 8: x5 = handler address (96)
csrrw x0, mtvec, x5  # 12
addi  x6, x0, -1920  # 16: 0xFFFFF880 after sign-ext -> mie_masked keeps bits 7/11 only -> MTIE|MEIE
csrrw x0, mie, x6  # 20: mie = MTIE|MEIE <- both enabled
addi  x8, x0, 1  # 24
sw    x8, 4(x1)  # 28: UART.IER.ERBFI <- 1
addi  x7, x0, 5  # 32: MTIMECMP target -- small, mip.MTIP pending almost immediately
sw    x7, 0(x2)  # 36: TIMER.MTIMECMP(low) <- 5
addi  x0, x0, 0  # 40: spacer -- gives the testbench's driven UART byte time to fully arrive (mip.MEIP pending) before mstatus.MIE is armed below, so both sources are genuinely simultaneously pending at that point
addi  x0, x0, 0  # 44
addi  x0, x0, 0  # 48
addi  x0, x0, 0  # 52
addi  x0, x0, 0  # 56
addi  x0, x0, 0  # 60
addi  x0, x0, 0  # 64
addi  x0, x0, 0  # 68
addi  x0, x0, 0  # 72
addi  x0, x0, 0  # 76
addi  x0, x0, 0  # 80
addi  x0, x0, 0  # 84
csrrsi x0, mstatus, 8  # 88: mstatus.MIE <- 1 -- both MTIP and MEIP already pending here
self:
jal   x0, self  # 92: spin -- likely never even completes one iteration before the interrupt lands
handler:
addi  x11, x0, 555  # 96: proves a handler ran; mcause (checked separately) proves WHICH source won priority
mret  # 100
