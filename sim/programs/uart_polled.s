lui x1, 0x10000        # x1 = UART_BASE

# TX: send 0xA5, poll STATUS.tx_busy until clear.
addi x2, x0, 0xA5
sw x2, 0(x1)            # TXDATA
tx_poll:
lw x3, 8(x1)            # STATUS
andi x3, x3, 1          # bit0 = tx_busy
bne x3, x0, tx_poll

# RX: poll STATUS.rx_ready, then read the byte.
rx_poll:
lw x4, 8(x1)            # STATUS
andi x5, x4, 2          # bit1 = rx_ready
beq x5, x0, rx_poll

lw x6, 4(x1)            # RXDATA

self:
jal x0, self
