ENTRY(_start)

SECTIONS
{
    . = 0x80000;

    .text : {
        *(.text._start)
        *(.text*)
    }

    .rodata : {
        *(.rodata*)
    }

    .bss (NOLOAD) : ALIGN(8) {
        __bss_start = .;
        *(.bss*)

        . = ALIGN(4096);
        __mmu_l1_table = .;
        . += 4096;
        __mmu_l2_table = .;
        . += 4096;

        __bss_end = .;
    }

    _stack_top = ALIGN(__bss_end, 16) + 0x10000;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
    }
}
