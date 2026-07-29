# docs/adr/0020-soc-integration.md (Phase D9). Directed test: a UART RX
# interrupt fires while a loop runs, driven in by the testbench (an
# external transmitter, same role tb_uart_unit.v/tb_mip_live.v's
# drive_rx_byte plays). Deliberately does not pin down exactly which cycle
# the byte arrives relative to the loop -- the interrupt may land mid-loop
# or after the loop's already spinning in `self`; both are valid, and the
# testbench's mepc check accepts the whole [loop_start, self] range rather
# than a single exact value, mirroring timer_interrupt.s's own reasoning.
# Unlike the timer source, RXDATA's own read naturally clears rx_ready (an
# edge-ish per-byte event, not a level compare against a re-armable
# register), so the handler doesn't need a timer_interrupt.s-style
# reprogram-to-a-huge-value step to avoid an immediate re-trigger.
# Layout: loop = [32, 92], self = 96, handler = 100
lui   x1, 0x10000  # 0: x1 = UART_BASE = MMIO_BASE
addi  x5, x0, 100  # 4: x5 = handler address (100)
csrrw x0, mtvec, x5  # 8
addi  x6, x0, -2048  # 12: 0xFFFFF800 after sign-ext -- CSR.v's mie_masked only reads bits 7/11, so only bit11 (MEIE) survives regardless of the sign-extended upper bits (same harmless-masking gotcha as andi, mip_live.s)
csrrw x0, mie, x6  # 16: mie.MEIE <- 1
addi  x8, x0, 1  # 20
sw    x8, 12(x1)  # 24: UART.CONTROL.rx_irq_enable <- 1
csrrsi x0, mstatus, 8  # 28: mstatus.MIE <- 1 (armed last)
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
addi  x10, x10, 1  # 72
addi  x10, x10, 1  # 76
addi  x10, x10, 1  # 80
addi  x10, x10, 1  # 84
addi  x10, x10, 1  # 88
addi  x10, x10, 1  # 92
self:
jal   x0, self  # 96: spin once the loop completes (or once interrupted after it)
handler:
addi  x11, x0, 888  # 100: proves the UART interrupt handler ran
lw    x13, 4(x1)  # 104: RXDATA -- reading it clears rx_ready, defusing the (edge, not level) source
mret  # 108
