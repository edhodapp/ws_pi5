/*
 * ip.S — IPv4 checksum and packet handler
 *
 * ip_checksum: ones' complement checksum (RFC 1071)
 * ip_handle:   IPv4 validation + protocol dispatch (added later)
 */

.include "net.inc"

.global ip_checksum

.section .text

/*
 * ip_checksum — Ones' complement checksum per RFC 1071
 *
 * x0: pointer to data
 * w1: length in bytes
 * Returns: w0 = 16-bit checksum (0 when verifying a valid header)
 * Clobbers: x0-x4
 *
 * Sums 16-bit LE halfwords — byte-order cancels per RFC 1071,
 * so no explicit swap is needed.
 */
ip_checksum:
    mov     w2, #0                  /* accumulator */

.Lcksum_loop:
    cmp     w1, #2
    b.lt    .Lcksum_odd
    ldrh    w3, [x0], #2            /* load LE halfword, advance */
    add     w2, w2, w3
    sub     w1, w1, #2
    b       .Lcksum_loop

.Lcksum_odd:
    cbz     w1, .Lcksum_fold
    ldrb    w3, [x0]                /* odd trailing byte as low byte */
    add     w2, w2, w3

.Lcksum_fold:
    /* Two-pass carry fold (32→16) */
    lsr     w3, w2, #16
    uxth    w2, w2
    add     w2, w2, w3
    lsr     w3, w2, #16
    add     w2, w2, w3

    /* Ones' complement */
    mvn     w0, w2
    uxth    w0, w0
    ret
