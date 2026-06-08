/*
 * MicroBlaze linker script for Arty A7 emulation test firmware.
 * BRAM: 0x00000000 - 0x0000FFFF (64 KB, microblaze_0_local_memory)
 * Stack at top of BRAM.
 */
MEMORY {
    bram : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS {
    .text : { *(.vectors) *(.text) *(.text.*) *(.rodata) *(.rodata.*) } > bram
    .data : { *(.data) *(.data.*) } > bram
    .bss  : { *(.bss) *(.bss.*) *(COMMON) } > bram
    _stack_end = ORIGIN(bram) + LENGTH(bram) - 4;
}

/* MicroBlaze entry vector at address 0 */
ENTRY(_start)
