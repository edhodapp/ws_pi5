.section .text._start

.global _start

_start:
.ifdef PLATFORM_PI4
    /* Debug: print '0' — UART already configured by firmware/chainloader */
    movz    x9, #0xFE20, lsl #16
    movk    x9, #0x1000
    mov     w10, #'0'
7:  ldr     w11, [x9, #0x18]
    tst     w11, #0x20
    b.ne    7b
    str     w10, [x9]
.endif

    /* Only let core 0 proceed, park other cores */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    /* Drop from EL2 to EL1 if needed (Pi 4 boots at EL2) */
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    .Lel1_ready

    /* Configure EL2: allow EL1 to access physical timer and FP/SIMD */
    mrs     x0, HCR_EL2
    orr     x0, x0, #(1 << 31)     /* RW: EL1 is AArch64 */
    msr     HCR_EL2, x0

    /* Enable physical counter access from EL1 */
    mov     x0, #3
    msr     CNTHCTL_EL2, x0        /* EL1PCTEN + EL1PCEN */
    msr     CNTVOFF_EL2, xzr       /* No virtual offset */

    /* Disable coprocessor traps */
    mov     x0, #0x33FF
    msr     CPTR_EL2, x0

    /* Return to EL1h: set SPSR_EL2 */
    mov     x0, #0x3C5             /* DAIF masked, EL1h (SPSel=1) */
    msr     SPSR_EL2, x0

    /* Set return address to .Lel1_ready */
    adr     x0, .Lel1_ready
    msr     ELR_EL2, x0
    eret

.Lel1_ready:
    /* Set up stack */
    ldr     x0, =_stack_top
    mov     sp, x0

.ifdef PLATFORM_PI4
    /* Debug: print '1' (EL1 reached) and '2' (stack ready) */
    movz    x9, #0xFE20, lsl #16
    movk    x9, #0x1000
    mov     w10, #'1'
8:  ldr     w11, [x9, #0x18]
    tst     w11, #0x20
    b.ne    8b
    str     w10, [x9]
    mov     w10, #'2'
9:  ldr     w11, [x9, #0x18]
    tst     w11, #0x20
    b.ne    9b
    str     w10, [x9]
.endif

    /* Zero BSS */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.ge    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    /* --- MMU setup: identity map, Normal RAM + Device peripherals --- */

    /* MAIR: attr0 = Normal WB (0xFF), attr1 = Device-nGnRnE (0x00) */
    mov     x0, #0xFF
    msr     MAIR_EL1, x0

    /* TCR: T0SZ=32 (4 GB VA), 4KB granule, inner shareable, WB cache */
    ldr     x0, =0x80803520
    msr     TCR_EL1, x0

    /* Level 1 table setup */
    ldr     x0, =__mmu_l1_table
    ldr     x1, =__mmu_l2_table
    orr     x1, x1, #0x3           /* table descriptor */

.ifdef PLATFORM_PI4
    /* Pi 4: 4 GB mapping. L1 entries 0-2 = 1 GB Normal blocks, entry 3 → L2 */
    mov     x2, #0x701             /* Normal 1GB block: AF | SH=inner | AttrIdx=0 | block */
    str     x2, [x0, #0]          /* 0x00000000 - 0x3FFFFFFF */
    mov     x3, #0x40000000
    orr     x3, x3, x2
    str     x3, [x0, #8]          /* 0x40000000 - 0x7FFFFFFF */
    mov     x3, #0x80000000
    orr     x3, x3, x2
    str     x3, [x0, #16]         /* 0x80000000 - 0xBFFFFFFF */
    str     x1, [x0, #24]         /* 0xC0000000 - 0xFFFFFFFF → L2 table */

    /* Fill L2 for GB 3: entries 0-479 Normal, 480-511 Device
     * Device starts at 0xFC000000 (extended peripherals: GENET, PCIe, etc.)
     * 480 = (0xFC000000 - 0xC0000000) / 2MB */
    ldr     x0, =__mmu_l2_table
    mov     x1, #0xC0000000        /* base PA for GB 3 */
    mov     x2, #0x701             /* Normal block */
    mov     x3, #0x405             /* Device block */
    mov     w4, #0

.Lfill_normal:
    orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #480               /* 480 = (0xFC000000 - 0xC0000000) / 2MB */
    b.lt    .Lfill_normal

.Lfill_device:
    orr     x5, x1, x3
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #512
    b.lt    .Lfill_device

.else
    /* Pi 3: 1 GB mapping. L1 entry 0 → L2 table */
    str     x1, [x0]

    /* Fill L2: entries 0-503 Normal, 504-511 Device */
    ldr     x0, =__mmu_l2_table
    mov     x1, #0
    mov     x2, #0x701
    mov     x3, #0x405
    mov     w4, #0

.Lfill_normal:
    orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #504               /* 504 = 0x3F000000 / 2MB */
    b.lt    .Lfill_normal

.Lfill_device:
    orr     x5, x1, x3
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #512
    b.lt    .Lfill_device

.endif

    /* Set translation table base */
    ldr     x0, =__mmu_l1_table
    msr     TTBR0_EL1, x0

    /* Invalidate TLB and D-cache before enabling MMU.
     * Critical when chainloaded — the chainloader's D-cache may
     * contain stale lines (from prefetching during HEX transfer)
     * that would shadow the BSS zero we just wrote to RAM. */
    tlbi    vmalle1

    /* Invalidate entire D-cache by set/way (L1: 32KB, 2-way, 64B) */
    mov     x0, #0                     /* set/way value */
    mov     x1, #256                   /* 256 sets (32KB / 2 ways / 64B) */
.Linv_l1:
    dc      isw, x0                    /* invalidate set, way 0 */
    orr     x2, x0, #(1 << 30)        /* way 1 (bit 30 for L1 on A72) */
    dc      isw, x2
    add     x0, x0, #(1 << 6)         /* next set (bit 6 = set field) */
    subs    x1, x1, #1
    b.ne    .Linv_l1

    dsb     sy
    isb

    /* Install exception vector table */
    ldr     x0, =_vectors
    msr     VBAR_EL1, x0
    isb

    /* Enable MMU + data cache + instruction cache */
    mrs     x0, SCTLR_EL1
    orr     x0, x0, #(1 << 0)     /* M: MMU enable */
    orr     x0, x0, #(1 << 2)     /* C: data cache */
    orr     x0, x0, #(1 << 12)    /* I: instruction cache */
    msr     SCTLR_EL1, x0
    isb

    bl      main
    cbz     w0, .Lnet_loop

.Lpark:
    wfe
    b       .Lpark

.Lnet_loop:
    bl      net_loop
    b       .Lpark

/* ================================================================
 * Exception vector table — catches faults and prints diagnostics.
 * Each entry is 128 bytes (0x80). 16 entries total = 2048 bytes.
 * ================================================================ */
.balign 2048
_vectors:
    /* --- Current EL, SP_EL0 --- */
    b       _exc_sync       /* Synchronous */
    .balign 0x80
    b       _exc_irq        /* IRQ */
    .balign 0x80
    b       _exc_fiq        /* FIQ */
    .balign 0x80
    b       _exc_serror     /* SError */
    .balign 0x80

    /* --- Current EL, SP_ELx --- */
    b       _exc_sync       /* Synchronous */
    .balign 0x80
    b       _exc_irq        /* IRQ */
    .balign 0x80
    b       _exc_fiq        /* FIQ */
    .balign 0x80
    b       _exc_serror     /* SError */
    .balign 0x80

    /* --- Lower EL, AArch64 --- */
    b       _exc_sync
    .balign 0x80
    b       _exc_irq
    .balign 0x80
    b       _exc_fiq
    .balign 0x80
    b       _exc_serror
    .balign 0x80

    /* --- Lower EL, AArch32 --- */
    b       _exc_sync
    .balign 0x80
    b       _exc_irq
    .balign 0x80
    b       _exc_fiq
    .balign 0x80
    b       _exc_serror
    .balign 0x80

/* Minimal exception handler: print fault info via UART polling */
_exc_sync:
    /* Use UART directly — we can't trust the stack or bl */
.ifdef PLATFORM_PI4
    movz    x9, #0xFE20, lsl #16
    movk    x9, #0x1000
.else
    movz    x9, #0x3F20, lsl #16
    movk    x9, #0x1000
.endif
    /* Print "\r\nEXC:" */
    mov     w10, #'\r'
    bl      _exc_putc
    mov     w10, #'\n'
    bl      _exc_putc
    mov     w10, #'E'
    bl      _exc_putc
    mov     w10, #'X'
    bl      _exc_putc
    mov     w10, #'C'
    bl      _exc_putc
    mov     w10, #':'
    bl      _exc_putc

    /* Print ESR_EL1 (exception syndrome).
     * Save x30 in x16 across _exc_hex64 calls (they clobber x30). */
    mov     x16, x30
    mrs     x11, ESR_EL1
    bl      _exc_hex64

    /* Print " ELR:" */
    mov     w10, #' '
    bl      _exc_putc
    mov     w10, #'E'
    bl      _exc_putc
    mov     w10, #'L'
    bl      _exc_putc
    mov     w10, #'R'
    bl      _exc_putc
    mov     w10, #':'
    bl      _exc_putc

    /* Print ELR_EL1 (faulting address) */
    mrs     x11, ELR_EL1
    bl      _exc_hex64

    /* Print " FAR:" */
    mov     w10, #' '
    bl      _exc_putc
    mov     w10, #'F'
    bl      _exc_putc
    mov     w10, #'A'
    bl      _exc_putc
    mov     w10, #'R'
    bl      _exc_putc
    mov     w10, #':'
    bl      _exc_putc

    /* Print FAR_EL1 (fault address register) */
    mrs     x11, FAR_EL1
    bl      _exc_hex64

    mov     w10, #'\r'
    bl      _exc_putc
    mov     w10, #'\n'
    bl      _exc_putc

    b       .Lpark

_exc_irq:
_exc_fiq:
_exc_serror:
    b       .Lpark

/* _exc_putc: print w10 via UART polling (x9 = UART base) */
_exc_putc:
1:  ldr     w12, [x9, #0x18]       /* UARTFR */
    tst     w12, #0x20              /* TXFF */
    b.ne    1b
    str     w10, [x9]
    ret

/* _exc_hex64: print x11 as 16 hex chars via UART
 * Saves x30 in x15 since we call _exc_putc via bl. */
_exc_hex64:
    mov     x15, x30               /* save LR */
    mov     x13, #60               /* shift start (60 = 15*4) */
2:  lsr     x14, x11, x13
    and     w14, w14, #0xF
    cmp     w14, #10
    b.lt    3f
    add     w10, w14, #('A' - 10)
    b       4f
3:  add     w10, w14, #'0'
4:  bl      _exc_putc
    subs    x13, x13, #4
    b.ge    2b
    mov     x30, x15               /* restore LR */
    ret
