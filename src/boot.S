.section .text._start

.global _start

_start:
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

    /* Zero BSS */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.ge    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    bl      main
    cbz     w0, .Lnet_loop

.Lpark:
    wfe
    b       .Lpark

.Lnet_loop:
    bl      net_loop
    b       .Lpark
