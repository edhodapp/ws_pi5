ENTRY(_start)

SECTIONS
{
    /* 0x80000: Pi 4 firmware's default load address for AArch64 kernels
     * (arm_64bit=1). Linux/PiOS, Circle, and every other established
     * bare-metal Pi project links here. The "VC firmware agent owns
     * 0x80000" claim that drove an earlier 0x200000 layout was a
     * misdiagnosis: the symptom (silent UART) was a PL011/Bluetooth
     * routing issue cured by `dtoverlay=disable-bt` in config.txt,
     * not a memory conflict. With the overlay applied, kernel-at-
     * 0x80000 is the simplest, firmware-default-honored configuration
     * — no kernel_address override needed in config.txt. */
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
