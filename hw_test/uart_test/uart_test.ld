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

    /DISCARD/ : {
        *(.comment)
        *(.note*)
    }
}
