/*
 * crt0.S — minimal MicroBlaze C runtime startup
 * Sets up stack and calls main(). No BSS zeroing needed for this test.
 */
    .section .vectors, "ax"
    .global _start
_start:
    /* Load stack pointer (R1) to top of BRAM */
    ori     r1, r0, 0xFFFC

    /* Clear small-data anchors */
    addik   r13, r0, 0
    addik   r2,  r0, 0

    /* Jump to main */
    brlid   r15, main
    nop

    /* Spin forever on return */
_halt:
    bri     _halt
