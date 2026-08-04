lui x1, 0x10000        # x1 = UART_BASE

# TX: send 0xA5 via THR, poll LSR.THRE (ready-for-more) until set.
addi x2, x0, 0xA5
sw x2, 0(x1)            # THR
tx_poll:
lw x3, 0x14(x1)         # LSR
andi x3, x3, 0x20       # bit5 = THRE
beq x3, x0, tx_poll

# RX: poll LSR.DR, then read the byte via RBR.
rx_poll:
lw x4, 0x14(x1)         # LSR
andi x5, x4, 1          # bit0 = DR
beq x5, x0, rx_poll

lw x6, 0(x1)            # RBR

self:
jal x0, self
