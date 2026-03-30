ENTRY(_start)

SECTIONS
{
    /* Loaded at 0x4000000 (64 MB) via config.txt kernel_address=0x4000000.
     * Must be above the kernel's memory footprint (~34 MB for 128 TCP
     * connections with 256 KB send buffers each). The kernel occupies
     * 0x80000–0x21A4000; this address gives ~30 MB of headroom. */
    . = 0x4000000;

    .text : {
        *(.text._start)
        *(.text*)
    }

    .rodata : {
        *(.rodata*)
    }

    .data : {
        *(.data*)
    }

    .bss (NOLOAD) : ALIGN(8) {
        __bss_start = .;
        *(.bss*)
        __bss_end = .;
    }

    _stack_top = ALIGN(__bss_end, 16) + 0x4000;
}
