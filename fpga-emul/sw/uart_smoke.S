/*
 * uart_smoke.S - bare-metal MicroBlaze UART smoke test
 * Streams 'U' forever from the reset vector with no stack or C runtime.
 */
    .section .vectors, "ax"
    .global _start

_start:
    /* Reset UART Lite TX/RX */
    imm     0x4060
    addik   r5, r0, 0x000c
    addik   r3, r0, 0x0003
    swi     r3, r5, 0

    imm     0x4060
    addik   r5, r0, 0x000c
    addik   r3, r0, 0x0000
    swi     r3, r5, 0

    /* Preload UART status/TX register addresses and test byte */
    imm     0x4060
    addik   r6, r0, 0x0008
    imm     0x4060
    addik   r7, r0, 0x0004
    addik   r3, r0, 0x0055

tx_wait:
    lwi     r4, r6, 0
    andi    r4, r4, 0x0008
    bnei    r4, tx_wait
    nop

    swi     r3, r7, 0
    bri     tx_wait
    nop
