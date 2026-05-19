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

    /* === SIZE_LOCKED layout =============================================
     *
     * When the linker is invoked with --defsym SIZE_LOCKED=1 (set by
     * the Makefile for default `make PLATFORM=pi4` builds — i.e. when
     * CONTENT_MAX has NOT been overridden), the appliance slab is
     * placed at LINK_ADDR + 1 MiB and sized to exactly 255 MiB, making
     * the kernel image exactly 256 MiB total (power of 2, easy to
     * reason about, matches what the README's capacity table promises).
     *
     * The 1 MiB pre-slab reserve holds .text + .rodata + non-slab
     * .data globals — currently ~100 KiB combined, leaving ~10× growth
     * headroom. If code or initialized data ever overflows the
     * reserve, the first ASSERT below catches it loudly at link time
     * rather than producing a silently-misaligned slab.
     *
     * On dev/test builds where CONTENT_MAX is overridden (typically
     * the `appliance` target: 65536 B), SIZE_LOCKED is NOT defined
     * and the reserve/ASSERTs are skipped — the slab packs immediately
     * after .data so the image stays small for fast UART chainloader
     * transfers (~150 KiB kernel instead of ~1 MiB).
     * ===================================================================
     */
    /* Direct symbol comparison instead of DEFINED() — ld processes
     * --defsym after parsing the script, so DEFINED() sees the symbol
     * as undefined at script eval time. Makefile always passes
     * SIZE_LOCKED as 0 or 1 so the symbol is always present. */
    . = SIZE_LOCKED ? (LINK_ADDR + 0x100000) : .;

    .appliance_slab : ALIGN(16) {
        __appliance_slab_start = .;
        *(.appliance_slab)
        __appliance_slab_end = .;
    }

    /* SIZE_LOCKED invariant #1: slab starts at LINK_ADDR + 1 MiB.
     * If .text + .rodata + .data exceeded the 1 MiB reserve, the
     * location counter is past 0x100000 by the time we hit
     * `.appliance_slab` placement and the slab ends up displaced
     * higher, breaking the 256 MiB total. Catches code/data bloat
     * loudly at link time. */
    ASSERT(SIZE_LOCKED == 0 ||
           (__appliance_slab_start - LINK_ADDR == 0x100000),
           "SIZE_LOCKED build: .text + .rodata + non-slab .data overflowed 1 MiB code reserve — either shrink globals or expand reserve in linker_hw.ld + APPLIANCE_CONTENT_MAX in include/http.inc")

    /* SIZE_LOCKED invariant #2: image total = exactly 256 MiB.
     * Catches drift between APPLIANCE_CONTENT_MAX (slab size) and the
     * linker's reserve geometry. If APPLIANCE_CONTENT_MAX is changed
     * away from 255 MiB without a matching reserve adjustment here,
     * this fires and points the diff back at itself. */
    ASSERT(SIZE_LOCKED == 0 ||
           (__appliance_slab_end - LINK_ADDR == 0x10000000),
           "SIZE_LOCKED build: image total != 256 MiB — APPLIANCE_CONTENT_MAX in include/http.inc must be (255 * 1024 * 1024) to match the linker's 1 MiB reserve")

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
