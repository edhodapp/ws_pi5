/*
 * test_hex_parse.S — Unit tests for Intel HEX parser (chainload/hex_parse.S)
 *
 * Tests cl_hex_nibble, cl_hex_byte, and cl_parse_hex_record by pre-filling
 * the line buffer with known records and checking results. No UART I/O
 * needed for these — pure logic tests.
 */

.global test_hex_parse

.section .text

/* -----------------------------------------------------------------------
 * Helper: load a test record string into hex_line_buf
 * x0 = source string pointer (null-terminated)
 * Returns: w26 = string length (excluding null)
 * Clobbers: x0, x1, w2, w26
 * ----------------------------------------------------------------------- */
load_record:
    ldr     x1, =hex_line_buf
    mov     w26, #0
1:  ldrb    w2, [x0], #1
    cbz     w2, 2f
    strb    w2, [x1], #1
    add     w26, w26, #1
    b       1b
2:  ret

/* ======================================================================= */

test_hex_parse:
    stp     x29, x30, [sp, #-16]!

    /* === cl_hex_nibble tests === */

    /* '0' → 0 */
    mov     w0, #'0'
    bl      cl_hex_nibble
    cmp     w0, #0
    b.ne    .Lfail_nibble_0
    ldr     x0, =name_nibble_0
    bl      test_pass
    b       .Lnibble_9
.Lfail_nibble_0:
    ldr     x0, =name_nibble_0
    bl      test_fail

.Lnibble_9:
    /* '9' → 9 */
    mov     w0, #'9'
    bl      cl_hex_nibble
    cmp     w0, #9
    b.ne    .Lfail_nibble_9
    ldr     x0, =name_nibble_9
    bl      test_pass
    b       .Lnibble_A
.Lfail_nibble_9:
    ldr     x0, =name_nibble_9
    bl      test_fail

.Lnibble_A:
    /* 'A' → 10 */
    mov     w0, #'A'
    bl      cl_hex_nibble
    cmp     w0, #10
    b.ne    .Lfail_nibble_A
    ldr     x0, =name_nibble_A
    bl      test_pass
    b       .Lnibble_F
.Lfail_nibble_A:
    ldr     x0, =name_nibble_A
    bl      test_fail

.Lnibble_F:
    /* 'F' → 15 */
    mov     w0, #'F'
    bl      cl_hex_nibble
    cmp     w0, #15
    b.ne    .Lfail_nibble_F
    ldr     x0, =name_nibble_F
    bl      test_pass
    b       .Lnibble_a
.Lfail_nibble_F:
    ldr     x0, =name_nibble_F
    bl      test_fail

.Lnibble_a:
    /* 'a' → 10 */
    mov     w0, #'a'
    bl      cl_hex_nibble
    cmp     w0, #10
    b.ne    .Lfail_nibble_a
    ldr     x0, =name_nibble_a
    bl      test_pass
    b       .Lnibble_f
.Lfail_nibble_a:
    ldr     x0, =name_nibble_a
    bl      test_fail

.Lnibble_f:
    /* 'f' → 15 */
    mov     w0, #'f'
    bl      cl_hex_nibble
    cmp     w0, #15
    b.ne    .Lfail_nibble_f
    ldr     x0, =name_nibble_f
    bl      test_pass
    b       .Ltest_hex_byte
.Lfail_nibble_f:
    ldr     x0, =name_nibble_f
    bl      test_fail

    /* === cl_hex_byte tests === */

.Ltest_hex_byte:
    /* "FF" → 0xFF */
    ldr     x0, =rec_ff
    bl      load_record
    ldr     x25, =hex_line_buf
    mov     w22, #0
    bl      cl_hex_byte
    cmp     w0, #0xFF
    b.ne    .Lfail_byte_ff
    cmp     w22, #2                    /* index advanced by 2 */
    b.ne    .Lfail_byte_ff
    ldr     x0, =name_byte_ff
    bl      test_pass
    b       .Lbyte_00
.Lfail_byte_ff:
    ldr     x0, =name_byte_ff
    bl      test_fail

.Lbyte_00:
    /* "00" → 0x00 */
    ldr     x0, =rec_00
    bl      load_record
    ldr     x25, =hex_line_buf
    mov     w22, #0
    bl      cl_hex_byte
    cmp     w0, #0x00
    b.ne    .Lfail_byte_00
    ldr     x0, =name_byte_00
    bl      test_pass
    b       .Lbyte_a5
.Lfail_byte_00:
    ldr     x0, =name_byte_00
    bl      test_fail

.Lbyte_a5:
    /* "a5" → 0xA5 (lowercase) */
    ldr     x0, =rec_a5
    bl      load_record
    ldr     x25, =hex_line_buf
    mov     w22, #0
    bl      cl_hex_byte
    cmp     w0, #0xA5
    b.ne    .Lfail_byte_a5
    ldr     x0, =name_byte_a5
    bl      test_pass
    b       .Ltest_parse_eof
.Lfail_byte_a5:
    ldr     x0, =name_byte_a5
    bl      test_fail

    /* === cl_parse_hex_record tests === */

.Ltest_parse_eof:
    /* EOF record: ":00000001FF" → return 1 */
    ldr     x0, =rec_eof
    bl      load_record
    ldr     x25, =hex_line_buf
    mov     x24, xzr
    mov     w20, wzr
    bl      cl_parse_hex_record
    cmp     w0, #1
    b.ne    .Lfail_parse_eof
    ldr     x0, =name_parse_eof
    bl      test_pass
    b       .Ltest_parse_ext
.Lfail_parse_eof:
    ldr     x0, =name_parse_eof
    bl      test_fail

.Ltest_parse_ext:
    /* Extended address: ":020000040008F2" → x24 = 0x80000 */
    ldr     x0, =rec_ext_addr
    bl      load_record
    ldr     x25, =hex_line_buf
    mov     x24, xzr
    mov     w20, wzr
    bl      cl_parse_hex_record
    cmp     w0, #0                     /* should return 0 (OK) */
    b.ne    .Lfail_parse_ext
    ldr     x0, =0x80000
    cmp     x24, x0                   /* x24 should be 0x80000 */
    b.ne    .Lfail_parse_ext
    ldr     x0, =name_parse_ext
    bl      test_pass
    b       .Ltest_parse_data
.Lfail_parse_ext:
    ldr     x0, =name_parse_ext
    bl      test_fail

.Ltest_parse_data:
    /* Data record: 4 bytes of 0xDE,0xAD,0xBE,0xEF at offset 0x0000
     * ":04000000DEADBEEF62" → writes to x24 + 0 = data_target */
    ldr     x0, =rec_data_4
    bl      load_record
    ldr     x25, =hex_line_buf
    ldr     x24, =data_target         /* set base to our test buffer */
    mov     w20, wzr
    bl      cl_parse_hex_record
    cmp     w0, #0
    b.ne    .Lfail_parse_data
    cmp     w20, #4                    /* 4 bytes written */
    b.ne    .Lfail_parse_data
    /* Verify written data */
    ldr     x0, =data_target
    ldrb    w1, [x0]
    cmp     w1, #0xDE
    b.ne    .Lfail_parse_data
    ldrb    w1, [x0, #1]
    cmp     w1, #0xAD
    b.ne    .Lfail_parse_data
    ldrb    w1, [x0, #2]
    cmp     w1, #0xBE
    b.ne    .Lfail_parse_data
    ldrb    w1, [x0, #3]
    cmp     w1, #0xEF
    b.ne    .Lfail_parse_data
    ldr     x0, =name_parse_data
    bl      test_pass
    b       .Ltest_parse_badcsum
.Lfail_parse_data:
    ldr     x0, =name_parse_data
    bl      test_fail

.Ltest_parse_badcsum:
    /* Bad checksum: ":00000001FE" (should be FF) → return -1 */
    ldr     x0, =rec_bad_csum
    bl      load_record
    ldr     x25, =hex_line_buf
    mov     x24, xzr
    mov     w20, wzr
    bl      cl_parse_hex_record
    cmn     w0, #1                     /* w0 == -1? */
    b.ne    .Lfail_parse_badcsum
    ldr     x0, =name_parse_badcsum
    bl      test_pass
    b       .Ltest_parse_nocolon
.Lfail_parse_badcsum:
    ldr     x0, =name_parse_badcsum
    bl      test_fail

.Ltest_parse_nocolon:
    /* No start colon: "00000001FF" → return -1 */
    ldr     x0, =rec_no_colon
    bl      load_record
    ldr     x25, =hex_line_buf
    mov     x24, xzr
    mov     w20, wzr
    bl      cl_parse_hex_record
    cmn     w0, #1
    b.ne    .Lfail_parse_nocolon
    ldr     x0, =name_parse_nocolon
    bl      test_pass
    b       .Ltest_parse_16byte
.Lfail_parse_nocolon:
    ldr     x0, =name_parse_nocolon
    bl      test_fail

.Ltest_parse_16byte:
    /* Full 16-byte data record */
    ldr     x0, =rec_data_16
    bl      load_record
    ldr     x25, =hex_line_buf
    ldr     x24, =data_target
    mov     w20, wzr
    bl      cl_parse_hex_record
    cmp     w0, #0
    b.ne    .Lfail_parse_16byte
    cmp     w20, #16
    b.ne    .Lfail_parse_16byte
    /* Verify first and last bytes */
    ldr     x0, =data_target
    ldrb    w1, [x0]
    cmp     w1, #0x00
    b.ne    .Lfail_parse_16byte
    ldrb    w1, [x0, #15]
    cmp     w1, #0x0F
    b.ne    .Lfail_parse_16byte
    ldr     x0, =name_parse_16byte
    bl      test_pass
    b       .Ltest_parse_offset
.Lfail_parse_16byte:
    ldr     x0, =name_parse_16byte
    bl      test_fail

.Ltest_parse_offset:
    /* Data at non-zero offset: address=0x0010, base=data_target
     * Should write to data_target + 0x10 */
    ldr     x0, =rec_data_offset
    bl      load_record
    ldr     x25, =hex_line_buf
    ldr     x24, =data_target
    mov     w20, wzr
    bl      cl_parse_hex_record
    cmp     w0, #0
    b.ne    .Lfail_parse_offset
    /* Verify byte at offset 0x10 */
    ldr     x0, =data_target
    ldrb    w1, [x0, #0x10]
    cmp     w1, #0xAA
    b.ne    .Lfail_parse_offset
    ldr     x0, =name_parse_offset
    bl      test_pass
    b       .Lhex_done
.Lfail_parse_offset:
    ldr     x0, =name_parse_offset
    bl      test_fail

.Lhex_done:
    ldp     x29, x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * Test data strings (Intel HEX records without CR/LF)
 * ----------------------------------------------------------------------- */
.section .rodata
rec_ff:            .asciz "FF"
rec_00:            .asciz "00"
rec_a5:            .asciz "a5"
rec_eof:           .asciz ":00000001FF"
rec_ext_addr:      .asciz ":020000040008F2"
rec_data_4:        .asciz ":04000000DEADBEEFC4"
rec_bad_csum:      .asciz ":00000001FE"
rec_no_colon:      .asciz "00000001FF"
/* 16 bytes: 00 01 02 ... 0F, checksum = ~(10+00+00+00+00+01+...+0F)+1 */
rec_data_16:       .asciz ":10000000000102030405060708090A0B0C0D0E0F78"
/* 1 byte 0xAA at offset 0x0010 */
rec_data_offset:   .asciz ":01001000AA45"

name_nibble_0:     .asciz "hex_nibble_0"
name_nibble_9:     .asciz "hex_nibble_9"
name_nibble_A:     .asciz "hex_nibble_A"
name_nibble_F:     .asciz "hex_nibble_F"
name_nibble_a:     .asciz "hex_nibble_a"
name_nibble_f:     .asciz "hex_nibble_f"
name_byte_ff:      .asciz "hex_byte_FF"
name_byte_00:      .asciz "hex_byte_00"
name_byte_a5:      .asciz "hex_byte_a5"
name_parse_eof:    .asciz "parse_eof"
name_parse_ext:    .asciz "parse_ext_addr"
name_parse_data:   .asciz "parse_data_4byte"
name_parse_badcsum: .asciz "parse_bad_checksum"
name_parse_nocolon: .asciz "parse_no_colon"
name_parse_16byte: .asciz "parse_data_16byte"
name_parse_offset: .asciz "parse_data_offset"

/* Test buffer for data record writes (64 bytes) */
.section .bss
.balign 8
data_target:
    .skip   64
