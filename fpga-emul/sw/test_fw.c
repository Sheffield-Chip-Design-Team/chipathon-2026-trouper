/*
 * test_fw.c — minimal MicroBlaze standalone test firmware
 * Verifies: UART output, MMCM clock running, AXI DSP ctrl register read.
 */

#define UART_BASE   0x40600000U
#define DSP_BASE    0x00010000U

#define UART_RX_FIFO   (*(volatile unsigned int *)(UART_BASE + 0x00))
#define UART_TX_FIFO   (*(volatile unsigned int *)(UART_BASE + 0x04))
#define UART_STATUS    (*(volatile unsigned int *)(UART_BASE + 0x08))
#define UART_CTRL      (*(volatile unsigned int *)(UART_BASE + 0x0C))

/* DSP ctrl register offsets (from axi_dsp_ctrl.v register map) */
#define DSP_STATUS     (*(volatile unsigned int *)(DSP_BASE + 0x00))
#define DSP_CTRL       (*(volatile unsigned int *)(DSP_BASE + 0x04))

#define UART_STATUS_TXEMPTY (1U << 2)

static void uart_putc(char c) {
    while (!(UART_STATUS & UART_STATUS_TXEMPTY));
    UART_TX_FIFO = (unsigned int)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void uart_puthex(unsigned int v) {
    const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

int main(void) {
    /* Reset UART */
    UART_CTRL = 0x03;   /* RST_TX | RST_RX */
    UART_CTRL = 0x00;

    uart_puts("\r\n\n=== LoRa MIMO FPGA emulation boot ===\r\n");
    uart_puts("UART: OK\r\n");

    /* Read DSP status register */
    unsigned int dsp_stat = DSP_STATUS;
    uart_puts("DSP_STATUS: ");
    uart_puthex(dsp_stat);
    uart_puts("\r\n");

    /* Read DSP ctrl register */
    unsigned int dsp_ctrl_val = DSP_CTRL;
    uart_puts("DSP_CTRL:   ");
    uart_puthex(dsp_ctrl_val);
    uart_puts("\r\n");

    /* Write a known pattern and read back */
    DSP_CTRL = 0xDEAD0001U;
    unsigned int readback = DSP_CTRL;
    uart_puts("CTRL w/r:   ");
    uart_puthex(readback);
    uart_puts(readback == 0xDEAD0001U ? "  PASS\r\n" : "  FAIL\r\n");

    uart_puts("=== done ===\r\n");

    while (1);
    return 0;
}
