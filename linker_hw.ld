ENTRY(_start)

SECTIONS
{
    /* Link address comes from the Makefile via --defsym LINK_ADDR=...
     * Default 0x80000 — the BCM2711 firmware's default kernel load
     * address, and also the address the UART chainloader writes the
     * received HEX records to and jumps to. One value for both paths;
     * dev iteration via UART exercises the exact bytes that ship to
     * end users. Earlier two-address regime (0x200000 chainload vs
     * 0x80000 ship) lost its rationale once the cache invalidation
     * order/way-bit bug was fixed (991b84c). */
    . = LINK_ADDR;

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
        *(COMMON)

        /* MMU page tables — page-aligned, zeroed with BSS, filled by boot code */
        . = ALIGN(4096);
        __mmu_l1_table = .;
        . += 4096;
        __mmu_l2_table = .;
        . += 4096;

        /* The BSS-zero loop in boot.S writes 8 bytes per iteration and
         * exits with `cmp; b.ge __bss_end` — so __bss_end MUST be on
         * an 8-byte boundary, otherwise the loop spills 1-7 bytes past
         * the end. Today MMU tables above already make this 4 KB-aligned,
         * but stating the constraint locally keeps it from regressing
         * silently if those tables ever move out of .bss. */
        . = ALIGN(8);
        __bss_end = .;
    }

    /* Stack above BSS — grows downward from here (64 KB stack space) */
    _stack_top = ALIGN(__bss_end, 16) + 0x10000;
}
