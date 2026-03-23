ENTRY(_start)

SECTIONS
{
    /* Loaded at 0x200000 via config.txt kernel_address=0x200000
     * so it doesn't overlap the 0x80000 target where kernels are received */
    . = 0x200000;

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

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss*)

        . = ALIGN(4096);
        __mmu_l1_table = .;
        . += 4096;
        __mmu_l2_table = .;
        . += 4096;

        __bss_end = .;
    }

    _stack_top = ALIGN(__bss_end, 16) + 0x4000;
}
