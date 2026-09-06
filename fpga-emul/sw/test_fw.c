/*
 * test_fw.c -- minimal MicroBlaze standalone test firmware
 * Verifies: UART output, MMCM clock running, and the host-SPI link to
 * trouper_top's reg_bank (axi_quad_spi_1) by reading CHIP_ID (expect 0xA7).
 *
 * Bare-metal (no BSP/libxil): pokes the AXI Quad SPI (axi_quad_spi_1) LogiCORE
 * registers directly per Xilinx PG153. Addresses below confirmed from the
 * Vivado address map (get_bd_addr_segs on vivado_proj/arty_dsp_emul.xpr):
 *   axi_uartlite_0  -> 0x40600000
 *   axi_quad_spi_1  -> 0x44A10000
 */

#define UART_BASE   0x40600000U
#define SPI1_BASE   0x44A10000U   /* axi_quad_spi_1 */

#define UART_RX_FIFO   (*(volatile unsigned int *)(UART_BASE + 0x00))
#define UART_TX_FIFO   (*(volatile unsigned int *)(UART_BASE + 0x04))
#define UART_STATUS    (*(volatile unsigned int *)(UART_BASE + 0x08))
#define UART_CTRL      (*(volatile unsigned int *)(UART_BASE + 0x0C))

/* AXI Quad SPI standard registers (Xilinx PG153) */
#define SPI_SRR        (*(volatile unsigned int *)(SPI1_BASE + 0x40)) /* Software Reset */
#define SPI_SPICR      (*(volatile unsigned int *)(SPI1_BASE + 0x60)) /* Control */
#define SPI_SPISR      (*(volatile unsigned int *)(SPI1_BASE + 0x64)) /* Status */
#define SPI_SPIDTR     (*(volatile unsigned int *)(SPI1_BASE + 0x68)) /* Data Transmit FIFO */
#define SPI_SPIDRR     (*(volatile unsigned int *)(SPI1_BASE + 0x6C)) /* Data Receive FIFO */
#define SPI_SPISSR     (*(volatile unsigned int *)(SPI1_BASE + 0x70)) /* Slave Select */

#define SPICR_SPE               (1U << 1)  /* SPI system enable */
#define SPICR_MASTER            (1U << 2)
#define SPICR_TX_FIFO_RESET     (1U << 5)
#define SPICR_RX_FIFO_RESET     (1U << 6)
#define SPICR_MANUAL_SS         (1U << 7)
#define SPICR_MASTER_INHIBIT    (1U << 8)

#define SPISR_RX_EMPTY          (1U << 0)
#define SPISR_TX_EMPTY          (1U << 2)

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

/* Single 2-byte SPI transfer: send tx[0..1], return the 2 received bytes
 * packed as (rx0<<8)|rx1. HOST_CS (SPISSR) is held low for both bytes. */
static unsigned int spi_xfer2(unsigned int tx0, unsigned int tx1) {
    unsigned int rx0, rx1;

    SPI_SPISSR = 0x0;  /* assert the single slave select (active low) */

    SPI_SPIDTR = tx0;
    SPI_SPIDTR = tx1;
    SPI_SPICR &= ~SPICR_MASTER_INHIBIT;  /* start the transaction */

    while (SPI_SPISR & SPISR_RX_EMPTY);
    rx0 = SPI_SPIDRR & 0xFFu;
    while (SPI_SPISR & SPISR_RX_EMPTY);
    rx1 = SPI_SPIDRR & 0xFFu;

    SPI_SPICR |= SPICR_MASTER_INHIBIT;
    SPI_SPISSR = 0x1;  /* deassert */

    return (rx0 << 8) | rx1;
}

int main(void) {
    /* Reset UART */
    UART_CTRL = 0x03;   /* RST_TX | RST_RX */
    UART_CTRL = 0x00;

    uart_puts("\r\n\n=== LoRa MIMO FPGA emulation boot ===\r\n");
    uart_puts("UART: OK\r\n");

    /* Bring up axi_quad_spi_1 as SPI master, manual slave select, mode 0 */
    SPI_SRR = 0x0000000A;   /* software reset */
    SPI_SPICR = SPICR_MASTER | SPICR_MANUAL_SS | SPICR_MASTER_INHIBIT
              | SPICR_TX_FIFO_RESET | SPICR_RX_FIFO_RESET;
    SPI_SPICR |= SPICR_SPE;
    SPI_SPISSR = 0x1;  /* deasserted */

    /* Read CHIP_ID (reg_bank 0x00, expect 0xA7): command byte {R#,addr}=0x80,
     * dummy byte 0x00 shifts the data byte back on the second transfer. */
    unsigned int rx = spi_xfer2(0x80, 0x00);
    unsigned int chip_id = rx & 0xFF;

    uart_puts("CHIP_ID:    ");
    uart_puthex(chip_id);
    uart_puts(chip_id == 0xA7 ? "  PASS\r\n" : "  FAIL\r\n");

    /* Transport-integrity sweep of the 16-byte W shadow window (0x30-0x3f).
     * These are plain R/W bytes while W_VALID=0 after reset, so unlike status
     * or W1P control registers, this test has no packet-engine side effects. */
    {
        unsigned int addr, expected, readback, errors = 0;
        for (addr = 0x30; addr <= 0x3F; ++addr) {
            expected = 0xA5U ^ addr;
            (void)spi_xfer2(addr, expected);
        }
        for (addr = 0x30; addr <= 0x3F; ++addr) {
            expected = 0xA5U ^ addr;
            readback = spi_xfer2(0x80U | addr, 0x00U) & 0xFFU;
            if (readback != expected) {
                ++errors;
                uart_puts("SPI mismatch @ ");
                uart_puthex(addr);
                uart_puts(": got ");
                uart_puthex(readback);
                uart_puts(" expected ");
                uart_puthex(expected);
                uart_puts("\r\n");
            }
        }
        uart_puts("W_SHADOW[0x30..0x3F]: ");
        uart_puts(errors == 0 ? "PASS\r\n" : "FAIL\r\n");
    }

    uart_puts("=== done ===\r\n");

    while (1);
    return 0;
}
