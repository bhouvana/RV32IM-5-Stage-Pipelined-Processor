/*
 * Thin memory-mapped-register accessors for design/Uart.v's real Phase-R
 * ns16550a-compatible register map (docs/adr/0034) -- word offsets, not
 * this core's own byte offsets a real 16550A's byte-wide bus would use
 * (see Uart.v's own header comment for why: this core's bus is exclusively
 * full-word transactions).
 */
#ifndef UART_MMIO_H
#define UART_MMIO_H

#include <stdint.h>

#define UART_BASE 0x10000000UL
#define UART_REG(off) (*(volatile uint32_t *)(UART_BASE + (off)))

#define UART_THR_RBR 0x00UL
#define UART_IER     0x04UL
#define UART_IIR_FCR 0x08UL
#define UART_LCR     0x0CUL
#define UART_MCR     0x10UL
#define UART_LSR     0x14UL
#define UART_MSR     0x18UL
#define UART_SCR     0x1CUL

#define UART_LSR_DR   0x01U
#define UART_LSR_THRE 0x20U

static inline void uart_putchar(char c) {
    while (!(UART_REG(UART_LSR) & UART_LSR_THRE)) { }
    UART_REG(UART_THR_RBR) = (uint32_t)(uint8_t)c;
}

/* Non-blocking -- returns -1 if no byte is ready (real legacy SBI
 * CONSOLE_GETCHAR convention). */
static inline int uart_getchar(void) {
    if (!(UART_REG(UART_LSR) & UART_LSR_DR))
        return -1;
    return (int)(UART_REG(UART_THR_RBR) & 0xFFU);
}

#endif
