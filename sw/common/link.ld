/* g3core bare-metal memory map (1 MiB RAM at 0, MMIO at 0xF0000000). */
OUTPUT_FORMAT("elf32-powerpc")
ENTRY(_reset)

SECTIONS
{
    /* Exception vector area starts at 0; the image is a flat binary from address 0. */
    . = 0;
    .vectors : { LONG(0) . = 0x100; *(.reset) }

    . = 0x4000;
    .text   : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.* .sdata2 .sdata2.*) }
    .data   : { *(.data .data.* .sdata .sdata.* .got2) }
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    }

    __stack_top = 0x100000;

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.gnu.attributes) }
}
