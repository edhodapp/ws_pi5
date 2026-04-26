ENTRY(_start)

SECTIONS
{
    /* Link address controlled by Makefile via --defsym LINK_ADDR=...
     *   - Default 0x200000: paired with the UART chainloader, which
     *     writes HEX records directly there and jumps. Inner-loop dev
     *     path; works on every Pi. (Direct chainloader writes to
     *     0x80000 are corrupted by firmware DMA — see attempt 16 in
     *     debug_log_0x80000.md; staging is overkill for a dev tool.)
     *   - 0x80000 (`make ... SHIP=1`): firmware default kernel address,
     *     used by the SD-direct ship path (scripts/mk_sd.sh). End
     *     users plug in an SD card and the firmware lands the kernel
     *     where linker_hw.ld targets. */
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

        __bss_end = .;
    }

    /* Stack above BSS — grows downward from here (64 KB stack space) */
    _stack_top = ALIGN(__bss_end, 16) + 0x10000;
}
