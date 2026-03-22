/*
 * boot.S — BeaglePlay (AM625) bare-metal boot stub
 *
 * AM625 Cortex-A53 boot:
 *   - TI ROM → SPL/R5 loads A53 image to 0x80000
 *   - A53 starts at EL1 (SPL drops from EL3)
 *   - Single-core initially (SMP bringup via PSCI if needed)
 *
 * Stub — to be completed during BeaglePlay bringup.
 */

.section .text._start

.global _start

_start:
    /* Only let core 0 proceed, park other cores */
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbnz    x0, .Lpark

    /* AM625 A53 enters at EL1 after SPL — no EL drop needed */

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
