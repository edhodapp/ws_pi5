ENTRY(_start)

SECTIONS
{
    /* 0x80000 — Pi 4 firmware default kernel load address.
     * Per attempt 38 in debug_log_0x80000.md: SD-direct boot to 0x80000
     * works once `overlays/disable-bt.dtbo` is on the SD card. Downstream
     * issue (GENET init silent hang) is a separate problem under active
     * debug. Chainloader path expects bytes at 0x80000 too — chainloader
     * stages at 0x200000 then memcpy's to 0x80000 before jump (see
     * chainload/boot.S). */
    . = 0x80000;

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

        __bss_end = .;
    }

    /* Stack above BSS — grows downward from here (64 KB stack space) */
    _stack_top = ALIGN(__bss_end, 16) + 0x10000;
}
