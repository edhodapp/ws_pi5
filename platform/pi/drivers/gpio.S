/*
 * gpio.S — BCM2711 GPIO function select driver
 *
 * Generic pin function configuration using hardware divide
 * for GPFSEL register selection and variable-shift bit manipulation.
 * Takes GPIO base as parameter for dependency injection.
 */

.section .text

/* -----------------------------------------------------------------------
 * gpio_set_function — Set a GPIO pin's function select
 *
 * Input:  x0 = GPIO base address
 *         w1 = pin number (0-53)
 *         w2 = function (GPIO_FSEL_INPUT..GPIO_FSEL_ALT5)
 * Output: (none)
 * Leaf function — no stack frame.
 *
 * Computes GPFSEL register (pin/10) and bit position ((pin%10)*3)
 * using hardware integer divide, then read-modify-write.
 * ----------------------------------------------------------------------- */
.global gpio_set_function
gpio_set_function:
    /* Compute register index and bit position */
    mov     w4, #10
    udiv    w3, w1, w4              /* w3 = pin / 10 (GPFSEL index) */
    msub    w5, w3, w4, w1          /* w5 = pin % 10 */
    add     w5, w5, w5, lsl #1     /* w5 *= 3 (bit position) */

    /* Read GPFSEL[pin/10] */
    ldr     w6, [x0, x3, lsl #2]

    /* Clear old function (3-bit field) */
    mov     w7, #7
    lsl     w7, w7, w5
    bic     w6, w6, w7

    /* Set new function */
    and     w8, w2, #7              /* mask to 3 bits for safety */
    lsl     w8, w8, w5
    orr     w6, w6, w8

    /* Write back */
    str     w6, [x0, x3, lsl #2]
    ret
