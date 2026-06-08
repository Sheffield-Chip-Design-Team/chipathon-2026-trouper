/*
 * uart_smoke.c - minimal MicroBlaze UART smoke test
 * Emits 'U' forever with no stack or runtime dependencies beyond reset entry.
 */

#define UART_BASE 0x40600000U
#define UART_RX_FIFO (*(volatile unsigned int *)(UART_BASE + 0x00U))
#define UART_TX_FIFO (*(volatile unsigned int *)(UART_BASE + 0x04U))
#define UART_STATUS  (*(volatile unsigned int *)(UART_BASE + 0x08U))
#define UART_CTRL    (*(volatile unsigned int *)(UART_BASE + 0x0CU))

void _start(void) {
    UART_CTRL = 0x03U;
    UART_CTRL = 0x00U;

    for (;;) {
        UART_TX_FIFO = 0x55U;
        for (volatile unsigned int i = 0; i < 20000U; ++i) {
            /* Small delay so the TX FIFO has time to drain. */
        }
    }
}
