ENTRY(_start)

SECTIONS
{
    /* Linked at 0x4000000, but the IMAGE is loaded by firmware at
     * 0x80000 (the default kernel address — no kernel_address= override
     * in config.txt). The chainloader's first action is to copy itself
     * from 0x80000 to 0x4000000 and branch into the relocated copy.
     *
     * Why: firmware completes its own 0x80000 work BEFORE releasing
     * the ARM cores (same quiescence guarantee SD-direct boot enjoys).
     * After the self-relocate we run from 0x4000000 — far above any
     * lingering firmware activity — and the kernel's HEX writes that
     * land at 0x80000 race nothing.
     *
     * The relocate stub uses only PC-relative addressing (adr) and
     * PC-relative literal-pool reads (`ldr =sym`) to get linked
     * absolute addresses; the literal pool is part of the .text image
     * and so is present at 0x80000+offset (our live copy) when the
     * stub runs. Once we br into 0x4000000, normal `ldr =sym` works
     * because the relocated bytes match what the linker planned. */
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

    /* Self-relocate parameters consumed by the stub at the top of
     * _start. _chainload_dest = link base = 0x4000000. _chainload_size
     * is the total loaded-image size (text + rodata + data); BSS is
     * NOLOAD so it doesn't need copying. Rounded up to 16 bytes so the
     * `ldp / stp` 16-byte loop can run without partial-word handling. */
    _chainload_dest = 0x4000000;
    _chainload_size = ALIGN(__bss_start, 16) - _chainload_dest;
}
