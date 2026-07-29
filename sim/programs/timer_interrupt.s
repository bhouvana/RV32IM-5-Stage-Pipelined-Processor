# docs/adr/0020-soc-integration.md (Phase D9). Directed test: a machine-
# timer interrupt fires mid-loop. Verified indirectly rather than pinned to
# an exact cycle: every loop iteration increments x10 by exactly 1, so the
# final count is deterministic regardless of which iteration the interrupt
# actually lands on -- the interrupt neither skips nor duplicates a loop
# instruction (mepc = the ID-stage instruction squashed this cycle, resumed
# unmodified by mret -- unlike ecall's own mepc-points-at-the-trapping-
# instruction convention, tb_mret_return.v, an interrupt's mepc needs NO +4
# adjustment). The testbench separately range-checks mepc against the loop's
# own address bounds. The handler reprograms MTIMECMP to a huge value before
# mret -- mip.MTIP is level-pending, not edge-triggered, so a handler that
# doesn't defer/clear its own source would see the same interrupt re-taken
# the instant mstatus.MIE is restored, before a single real instruction gets
# to run (a real hardware/driver concern, not specific to this core).
# Layout: loop = [36, 104], self = 108, handler = 112
lui   x2, 0x10000  # 0: x2 = MMIO_BASE
addi  x2, x2, 16  # 4: x2 = TIMER_BASE (UART_SIZE=16)
addi  x5, x0, 112  # 8: x5 = handler address (112)
csrrw x0, mtvec, x5  # 12
addi  x6, x0, 128  # 16: 0x80 = MIE_MTIE_BIT
csrrw x0, mie, x6  # 20: mie.MTIE <- 1
addi  x7, x0, 25  # 24: MTIMECMP target -- comfortably mid-loop, see header comment
sw    x7, 4(x2)  # 28: TIMER.MTIMECMP <- 25
csrrsi x0, mstatus, 8  # 32: mstatus.MIE <- 1 (armed last, after mtvec/mie/mtimecmp)
addi  x10, x10, 1  # 36
addi  x10, x10, 1  # 40
addi  x10, x10, 1  # 44
addi  x10, x10, 1  # 48
addi  x10, x10, 1  # 52
addi  x10, x10, 1  # 56
addi  x10, x10, 1  # 60
addi  x10, x10, 1  # 64
addi  x10, x10, 1  # 68
addi  x10, x10, 1  # 72
addi  x10, x10, 1  # 76
addi  x10, x10, 1  # 80
addi  x10, x10, 1  # 84
addi  x10, x10, 1  # 88
addi  x10, x10, 1  # 92
addi  x10, x10, 1  # 96
addi  x10, x10, 1  # 100
addi  x10, x10, 1  # 104
self:
jal   x0, self  # 108: spin once the loop completes
handler:
addi  x11, x0, 999  # 112: proves the handler ran
lui   x12, 0xFFFFF  # 116: x12 = 0xFFFFF000 -- far beyond any mtime this test reaches
sw    x12, 4(x2)  # 120: TIMER.MTIMECMP <- huge: clears/defers `pending` so mret doesn't
mret  # 124: immediately re-trigger the same still-level-pending source
