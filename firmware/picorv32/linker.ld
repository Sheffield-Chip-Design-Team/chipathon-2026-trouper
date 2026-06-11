OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    sram (rwx) : ORIGIN = 0x00000000, LENGTH = 4K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.init))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > sram

    .data : ALIGN(4)
    {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    } > sram

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } > sram

    . = ALIGN(16);
    __stack_top = ORIGIN(sram) + LENGTH(sram);
    _end = .;

    /DISCARD/ :
    {
        *(.comment)
        *(.gnu*)
        *(.note*)
        *(.eh_frame*)
    }
}
