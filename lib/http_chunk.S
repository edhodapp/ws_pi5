/*
 * http_chunk.S — Chunked transfer encoding for HTTP/1.1
 *
 * RFC 9112 §7.1: each chunk is "hex-size\r\ndata\r\n", terminated
 * by "0\r\n\r\n". Used for dynamic responses where Content-Length
 * is not known in advance.
 */

.include "net.inc"
.include "tcp.inc"
.include "http.inc"

.global http_chunk_encode
.global http_chunk_terminate

.section .text

/*
 * http_chunk_encode — Wrap data in a chunked-transfer chunk
 *
 * Writes into output buffer: "<hex-size>\r\n<data>\r\n"
 *
 * x0: output buffer (must hold len + 20 bytes overhead)
 * x1: data pointer
 * w2: data length (1-65535)
 *
 * Returns: w0 = total bytes written to output buffer
 * Clobbers: x0-x5
 */
http_chunk_encode:
    mov     x3, x0                 /* x3 = output start */
    mov     x4, x1                 /* x4 = data src */
    mov     w5, w2                 /* w5 = data len */

    cbz     w5, .Lce_zero          /* 0-length not valid for data chunks */

    /* Write hex size digits (skip leading zeros).
     * Inline hex char conversion: nibble → '0'-'9' or 'a'-'f'. */

    /* Macro-like: convert nibble in w2 to hex char */
.macro hexnibble reg
    cmp     \reg, #10
    b.lt    7778f
    add     \reg, \reg, #('a' - 10)
    b       7779f
7778:
    add     \reg, \reg, #'0'
7779:
.endm

    cmp     w5, #0x1000
    b.lo    .Lce_skip4
    lsr     w2, w5, #12
    and     w2, w2, #0xF
    hexnibble w2
    strb    w2, [x0], #1
.Lce_skip4:
    cmp     w5, #0x100
    b.lo    .Lce_skip3
    lsr     w2, w5, #8
    and     w2, w2, #0xF
    hexnibble w2
    strb    w2, [x0], #1
.Lce_skip3:
    cmp     w5, #0x10
    b.lo    .Lce_skip2
    lsr     w2, w5, #4
    and     w2, w2, #0xF
    hexnibble w2
    strb    w2, [x0], #1
.Lce_skip2:
    and     w2, w5, #0xF
    hexnibble w2
    strb    w2, [x0], #1

    /* \r\n after size */
    mov     w2, #0x0D
    strb    w2, [x0], #1
    mov     w2, #0x0A
    strb    w2, [x0], #1

    /* Copy data */
    mov     w1, w5
.Lce_copy:
    cbz     w1, .Lce_copy_done
    ldrb    w2, [x4], #1
    strb    w2, [x0], #1
    sub     w1, w1, #1
    b       .Lce_copy
.Lce_copy_done:

    /* \r\n after data */
    mov     w2, #0x0D
    strb    w2, [x0], #1
    mov     w2, #0x0A
    strb    w2, [x0], #1

    /* Return total bytes written */
    sub     w0, w0, w3
    ret

.Lce_zero:
    mov     w0, #0
    ret

/*
 * http_chunk_terminate — Write chunked transfer terminator
 *
 * Writes "0\r\n\r\n" (5 bytes) to output buffer.
 *
 * x0: output buffer
 * Returns: w0 = 5 (bytes written)
 * Clobbers: x0, w1
 */
http_chunk_terminate:
    mov     w1, #'0'
    strb    w1, [x0]
    mov     w1, #0x0D
    strb    w1, [x0, #1]
    mov     w1, #0x0A
    strb    w1, [x0, #2]
    mov     w1, #0x0D
    strb    w1, [x0, #3]
    mov     w1, #0x0A
    strb    w1, [x0, #4]
    mov     w0, #5
    ret
