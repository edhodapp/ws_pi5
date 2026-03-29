/*
 * hex_parse.S — Intel HEX record parser
 *
 * Pure parsing logic: operates on a line buffer in memory.
 * No platform-specific or UART dependencies.
 *
 * Registers used by caller convention:
 *   x24 = extended base address (modified by Type 04 records)
 *   x25 = line buffer pointer
 *   w20 = total data bytes received (incremented by Type 00 records)
 */

.equ LINE_BUF_SIZE, 80

/* -----------------------------------------------------------------------
 * cl_hex_nibble — Convert ASCII hex character to 0-15
 *
 * Input:  w0 = ASCII char ('0'-'9', 'A'-'F', 'a'-'f')
 * Output: w0 = 0-15 value
 * Leaf function. Clobbers w0 only.
 * ----------------------------------------------------------------------- */
.global cl_hex_nibble
cl_hex_nibble:
    cmp     w0, #'9'
    b.hi    1f
    sub     w0, w0, #'0'              /* '0'-'9' → 0-9 */
    ret
1:  orr     w0, w0, #0x20             /* tolower: 'A'-'F' → 'a'-'f' */
    sub     w0, w0, #('a' - 10)       /* 'a'-'f' → 10-15 */
    ret

/* -----------------------------------------------------------------------
 * cl_hex_byte — Parse two ASCII hex chars from line buffer into one byte
 *
 * Input:  x25 = buffer base, w22 = current index (advanced by 2)
 * Output: w0 = byte value (0-255)
 * Clobbers: w0, w1, w22
 * ----------------------------------------------------------------------- */
.global cl_hex_byte
cl_hex_byte:
    str     x30, [sp, #-16]!
    ldrb    w0, [x25, w22, uxtw]
    add     w22, w22, #1
    bl      cl_hex_nibble
    mov     w1, w0                     /* w1 = high nibble */
    ldrb    w0, [x25, w22, uxtw]
    add     w22, w22, #1
    bl      cl_hex_nibble
    orr     w0, w0, w1, lsl #4        /* w0 = (high << 4) | low */
    ldr     x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * cl_parse_hex_record — Parse and process one Intel HEX record
 *
 * Input:
 *   x25 = line buffer (contains record without CR/LF)
 *   w26 = line length
 *   x24 = current extended base address (upper 16 bits << 16)
 *
 * Output:
 *   w0: 0 = data record OK, 1 = EOF, -1 = error
 *   x24 updated for Type 04 (extended linear address)
 *   w20 += data bytes written for Type 00
 *
 * Clobbers: w0-w9, w22, w27
 * Preserves: x19, x23, x25
 * ----------------------------------------------------------------------- */
.global cl_parse_hex_record
cl_parse_hex_record:
    stp     x29, x30, [sp, #-48]!     /* frame: 16 saved + 16 staging + 16 pad */

    /* Validate start code */
    ldrb    w0, [x25]
    cmp     w0, #':'
    b.ne    .Lparse_err

    mov     w22, #1                    /* buffer index, skip ':' */

    /* Parse header: LL, AAAA, TT */
    bl      cl_hex_byte
    mov     w2, w0                     /* w2 = byte count (LL) */

    bl      cl_hex_byte
    mov     w3, w0                     /* w3 = address high byte */

    bl      cl_hex_byte
    orr     w3, w0, w3, lsl #8        /* w3 = 16-bit address */

    bl      cl_hex_byte
    mov     w5, w0                     /* w5 = record type (TT) */

    /* Initialize checksum: LL + addr_hi + addr_lo + TT */
    ubfx    w0, w3, #8, #8            /* addr high byte */
    and     w1, w3, #0xFF             /* addr low byte */
    add     w27, w2, w0
    add     w27, w27, w1
    add     w27, w27, w5

    /* Parse data bytes into staging area on stack */
    add     x8, sp, #16               /* x8 = staging buffer */
    mov     w6, #0                     /* staging index */
    mov     w7, w2                     /* loop counter = byte count */
.Lparse_data:
    cbz     w7, .Lparse_data_done
    bl      cl_hex_byte
    add     w27, w27, w0              /* accumulate checksum */
    strb    w0, [x8, w6, uxtw]
    add     w6, w6, #1
    sub     w7, w7, #1
    b       .Lparse_data
.Lparse_data_done:

    /* Parse and verify checksum */
    bl      cl_hex_byte               /* w0 = checksum byte */
    add     w27, w27, w0
    and     w27, w27, #0xFF
    cbnz    w27, .Lparse_err          /* sum must be 0 */

    /* Dispatch on record type */
    cbz     w5, .Ltype_data           /* Type 00: data */
    cmp     w5, #0x01
    b.eq    .Ltype_eof                /* Type 01: EOF */
    cmp     w5, #0x04
    b.eq    .Ltype_ext_addr           /* Type 04: extended linear address */
    b       .Lparse_err               /* unknown type */

.Ltype_data:
    /* Write staged data to RAM at (extended_base + 16-bit offset) */
    add     x9, x24, w3, uxtw        /* x9 = absolute target address */
    mov     w7, #0
.Lcopy_data:
    cmp     w7, w6
    b.ge    .Lcopy_done
    ldrb    w0, [x8, w7, uxtw]
    strb    w0, [x9, w7, uxtw]
    add     w7, w7, #1
    b       .Lcopy_data
.Lcopy_done:
    add     w20, w20, w6              /* total bytes received */
    mov     w0, #0                     /* return 0: data OK */
    b       .Lparse_ret

.Ltype_eof:
    mov     w0, #1                     /* return 1: EOF */
    b       .Lparse_ret

.Ltype_ext_addr:
    /* Two data bytes form the upper 16 bits of the base address */
    ldrb    w0, [x8]                  /* high byte */
    ldrb    w1, [x8, #1]             /* low byte */
    orr     w0, w1, w0, lsl #8       /* 16-bit value */
    lsl     x24, x0, #16             /* x24 = upper address << 16 */
    mov     w0, #0                     /* return 0: OK */
    b       .Lparse_ret

.Lparse_err:
    mov     w0, #-1
    /* fall through */

.Lparse_ret:
    ldp     x29, x30, [sp], #48
    ret

/* -----------------------------------------------------------------------
 * BSS: line buffer (zeroed by caller's BSS init)
 * ----------------------------------------------------------------------- */
.section .bss
.balign 8
.global hex_line_buf
hex_line_buf:
    .skip   LINE_BUF_SIZE
