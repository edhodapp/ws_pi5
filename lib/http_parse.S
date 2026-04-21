/*
 * http_parse.S — FSA-based HTTP/1.x request parser
 *
 * Table-driven character-at-a-time parser. Processes bytes from the
 * TCP rx buffer, advancing the FSA state stored in HCONN. Returns
 * when the request is fully parsed (S_DONE), an error is detected
 * (S_ERROR), or the buffer is exhausted (partial request).
 *
 * Character classes: ALPHA, DIGIT, SP, CR, LF, COLON, SLASH, OTHER
 * States: S_METHOD through S_ERROR (20 states, see http.inc)
 * Transition table: 20 × 8 = 160 bytes in .rodata
 *
 * Each table entry is 1 byte: upper 3 bits = action, lower 5 bits =
 * next state. Supports 32 states and 8 actions. Table: 160 bytes,
 * lookup is a single ldrb.
 */

.include "net.inc"
.include "tcp.inc"
.include "http.inc"

.global http_parse_request
.global http_classify_char

.section .text

/*
 * http_classify_char — Map ASCII byte to character class (0-8)
 *
 * w0: input byte (0-255)
 * Returns: w0 = character class (CC_*)
 * Leaf function, clobbers w0-w1.
 *
 * Uses a 256-byte lookup table for single-ldrb classification.
 */
http_classify_char:
    ldr     x1, =http_char_class_table
    ldrb    w0, [x1, w0, uxtw]
    ret

/*
 * http_parse_request — Run the FSA parser on available rx data
 *
 * x0: HCONN pointer
 * x1: rx buffer pointer (from tcp_rx_peek)
 * w2: rx data length
 *
 * Returns: w0 = parser state after processing:
 *   S_DONE  (18) — request fully parsed
 *   S_ERROR (19) — malformed request
 *   other        — need more data (partial request)
 *
 * The parser reads HCONN_PARSE_STATE and HCONN_PARSE_OFF on entry,
 * processes bytes from offset to the end of available data (or until
 * S_DONE/S_ERROR), and writes back HCONN_PARSE_STATE, HCONN_PARSE_OFF,
 * and any extracted fields (URI_START, URI_LEN, VER_MINOR, etc.).
 *
 * Clobbers: x0-x7, x19-x22 saved/restored
 */
http_parse_request:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* x19 = HCONN */
    mov     x20, x1                 /* x20 = rx buffer */
    mov     w21, w2                 /* w21 = rx data len */

    ldrb    w4, [x19, #HCONN_PARSE_STATE]   /* w4 = current state */
    ldrh    w5, [x19, #HCONN_PARSE_OFF]     /* w5 = current offset */

    ldr     x6, =http_fsa_table

.Lparse_loop:
    /* Exit if we've consumed all available data */
    cmp     w5, w21
    b.hs    .Lparse_need_more

    /* Exit if terminal state */
    cmp     w4, #S_DONE
    b.hs    .Lparse_terminal        /* S_DONE or S_ERROR */

    /* Load current byte */
    ldrb    w0, [x20, w5, uxtw]
    mov     w22, w0                 /* w22 = raw byte (preserved) */

    /* Classify character */
    bl      http_classify_char      /* w0 = char class */

    /* Look up transition: table[state * 9 + class] */
    mov     w7, #CC_COUNT
    mul     w7, w4, w7              /* state * 9 */
    add     w7, w7, w0              /* + class */
    ldrb    w7, [x6, w7, uxtw]     /* w7 = packed (action:4 | next_state:4) */

    /* Extract next state and action */
    and     w4, w7, #0x1F           /* new state = lower 5 bits */
    lsr     w7, w7, #5              /* action = upper 3 bits */

    /* Execute action (0 = none, skip fast) */
    cbz     w7, .Lparse_advance

    /* Action dispatch */
    cmp     w7, #1
    b.eq    .Lact_uri_start
    cmp     w7, #2
    b.eq    .Lact_uri_end
    cmp     w7, #3
    b.eq    .Lact_ver_minor
    cmp     w7, #4
    b.eq    .Lact_hdr_name_start
    cmp     w7, #5
    b.eq    .Lact_hdr_check_host
    cmp     w7, #6
    b.eq    .Lact_req_done
    b       .Lparse_advance         /* unknown action → skip */

.Lact_uri_start:
    /* Record URI start position (current byte is first URI char) */
    strh    w5, [x19, #HCONN_URI_START]
    /* Also record method length = current offset (method was 0..offset-1,
     * but offset now points past the space, so method_len = offset - 1.
     * Actually, offset points to URI start, method ended at offset-1 (space).
     * method_len = offset of space = the w5 we had when we saw the space.
     * But we're at URI start now, so method_len is saved separately
     * when transitioning from S_METHOD to S_M_SP. Let's store it here:
     * URI_START is the byte AFTER the space, so method ended at URI_START-2
     * (the last method char before the space). Method length = URI_START - 1.
     * Hmm, that's not quite right either. Let me just record method_len
     * in the S_METHOD→S_M_SP transition. For now, derive it from URI_START.
     */
    b       .Lparse_advance

.Lact_uri_end:
    /* Record URI length: current offset - URI_START */
    ldrh    w0, [x19, #HCONN_URI_START]
    sub     w0, w5, w0
    strh    w0, [x19, #HCONN_URI_LEN]
    b       .Lparse_advance

.Lact_ver_minor:
    /* Store the minor version digit */
    strb    w22, [x19, #HCONN_VER_MINOR]
    b       .Lparse_advance

.Lact_hdr_name_start:
    /* Beginning of a header field name — record position for Host check.
     * We'll check the accumulated name when we see the colon. */
    strh    w5, [x19, #HCONN_HDR_NM_START]   /* temp: hdr_name_start at offset 50 */
    b       .Lparse_advance

.Lact_hdr_check_host:
    /* We've seen a colon — check if the header name is "Host" or
     * "Connection" (case-insensitive). Header name: bytes from
     * hdr_name_start to current offset. */
    ldrh    w0, [x19, #HCONN_HDR_NM_START]   /* hdr_name_start */
    sub     w1, w5, w0              /* name_len */

    cmp     w1, #4
    b.eq    .Lhdr_check_host_4
    cmp     w1, #10
    b.eq    .Lhdr_check_conn_10
    cmp     w1, #14
    b.eq    .Lhdr_check_cl_14
    b       .Lparse_advance

.Lhdr_check_host_4:
    /* Case-insensitive check for "host" */
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'h'
    b.ne    .Lparse_advance
    add     w0, w0, #1
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'o'
    b.ne    .Lparse_advance
    add     w0, w0, #1
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'s'
    b.ne    .Lparse_advance
    add     w0, w0, #1
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'t'
    b.ne    .Lparse_advance
    mov     w0, #1
    strb    w0, [x19, #HCONN_HOST_FOUND]
    b       .Lparse_advance

.Lhdr_check_conn_10:
    /* Case-insensitive check for "connection" (10 chars).
     * If found AND value contains "close", set HCONN_CLOSE_FOUND. */
    mov     w3, w0                  /* save name start */
    ldr     x1, =http_conn_name     /* "connection" reference */
    mov     w2, #10
.Lhdr_conn_cmp:
    cbz     w2, .Lhdr_conn_match
    ldrb    w7, [x20, w0, uxtw]
    orr     w7, w7, #0x20
    ldrb    w8, [x1], #1
    cmp     w7, w8
    b.ne    .Lparse_advance
    add     w0, w0, #1
    sub     w2, w2, #1
    b       .Lhdr_conn_cmp

.Lhdr_conn_match:
    /* "Connection" header found. Scan value for "close".
     * Value starts at current parse position + 1 (skip colon).
     * We look for "close" case-insensitive in the value bytes
     * until CR. Since we're mid-parse at the colon, the value
     * hasn't been consumed yet. Scan forward from w5+1. */
    add     w0, w5, #1             /* skip colon, start of value */
.Lhdr_conn_skip_sp:
    cmp     w0, w21                /* bounds check */
    b.hs    .Lparse_advance
    ldrb    w1, [x20, w0, uxtw]
    cmp     w1, #' '               /* skip OWS */
    b.ne    .Lhdr_conn_val
    add     w0, w0, #1
    b       .Lhdr_conn_skip_sp

.Lhdr_conn_val:
    /* Check if value starts with "close" (5 chars, case-insensitive) */
    add     w2, w0, #5
    cmp     w2, w21
    b.hs    .Lparse_advance        /* not enough bytes */
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'c'
    b.ne    .Lparse_advance
    add     w0, w0, #1
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'l'
    b.ne    .Lparse_advance
    add     w0, w0, #1
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'o'
    b.ne    .Lparse_advance
    add     w0, w0, #1
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'s'
    b.ne    .Lparse_advance
    add     w0, w0, #1
    ldrb    w1, [x20, w0, uxtw]
    orr     w1, w1, #0x20
    cmp     w1, #'e'
    b.ne    .Lparse_advance

    /* "Connection: close" detected */
    mov     w0, #1
    strb    w0, [x19, #HCONN_CLOSE_FOUND]
    b       .Lparse_advance

.Lhdr_check_cl_14:
    /* Case-insensitive compare against "content-length". */
    ldr     x1, =http_content_length_name
    mov     w2, #14
.Lhdr_cl_cmp:
    cbz     w2, .Lhdr_cl_match
    ldrb    w7, [x20, w0, uxtw]
    orr     w7, w7, #0x20
    ldrb    w8, [x1], #1
    cmp     w7, w8
    b.ne    .Lparse_advance
    add     w0, w0, #1
    sub     w2, w2, #1
    b       .Lhdr_cl_cmp

.Lhdr_cl_match:
    /* Duplicate Content-Length is a smuggling risk (RFC 7230 §3.3.3).
     * If the flag is already set, transition the FSA to S_ERROR so
     * the request is rejected as 400 Bad Request. */
    ldrb    w3, [x19, #HCONN_FLAGS]
    tst     w3, #HFLAG_CL_SEEN
    b.ne    .Lhdr_cl_dup

    /* Name matches. Parse decimal value from w5+1 (past colon), skip
     * leading OWS, accumulate digits. Non-digit terminates. */
    add     w0, w5, #1
.Lhdr_cl_skip_sp:
    cmp     w0, w21
    b.hs    .Lparse_advance
    ldrb    w1, [x20, w0, uxtw]
    cmp     w1, #' '
    b.ne    .Lhdr_cl_digits
    add     w0, w0, #1
    b       .Lhdr_cl_skip_sp

.Lhdr_cl_digits:
    mov     w2, #0                  /* accumulator */
.Lhdr_cl_loop:
    cmp     w0, w21
    b.hs    .Lhdr_cl_store
    ldrb    w1, [x20, w0, uxtw]
    sub     w1, w1, #'0'
    cmp     w1, #9
    b.hi    .Lhdr_cl_store
    mov     w8, #10
    mul     w2, w2, w8
    add     w2, w2, w1
    /* Stop once the accumulator exceeds HTTP_MAX_RECV_BODY. This keeps
     * w2 well under 2^32 so the next multiply can never wrap silently,
     * and the stored value still exceeds the 413 threshold downstream.
     * Remaining digits in the value are left for the FSA to consume. */
    cmp     w2, #HTTP_MAX_RECV_BODY
    b.hi    .Lhdr_cl_store
    add     w0, w0, #1
    b       .Lhdr_cl_loop

.Lhdr_cl_store:
    str     w2, [x19, #HCONN_CONTENT_LEN]
    /* Mark the header as seen so http_poll can distinguish an explicit
     * "Content-Length: 0" from a missing Content-Length — the POST/411
     * check needs to know which case this is. */
    ldrb    w3, [x19, #HCONN_FLAGS]
    orr     w3, w3, #HFLAG_CL_SEEN
    strb    w3, [x19, #HCONN_FLAGS]
    b       .Lparse_advance

.Lhdr_cl_dup:
    /* Second Content-Length header — force parser into S_ERROR; the
     * main loop's next iteration will terminate and http_poll emits
     * 400 Bad Request. */
    mov     w4, #S_ERROR
    b       .Lparse_advance

.Lact_req_done:
    /* Record total request length (offset + 1 = byte past final LF) */
    add     w0, w5, #1
    str     w0, [x19, #HCONN_REQ_LEN]
    b       .Lparse_advance

.Lparse_advance:
    add     w5, w5, #1
    b       .Lparse_loop

.Lparse_need_more:
    /* Save state for resumption */
    strb    w4, [x19, #HCONN_PARSE_STATE]
    strh    w5, [x19, #HCONN_PARSE_OFF]
    mov     w0, w4                  /* return current state */
    b       .Lparse_ret

.Lparse_terminal:
    strb    w4, [x19, #HCONN_PARSE_STATE]
    strh    w5, [x19, #HCONN_PARSE_OFF]
    mov     w0, w4

.Lparse_ret:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* ===================================================================
 * FSA transition table
 *
 * 20 states × 8 character classes = 160 bytes
 * Each byte: upper 4 bits = action, lower 4 bits = next state
 *
 * Actions: 0=none, 1=uri_start, 2=uri_end, 3=ver_minor,
 *          4=hdr_name_start, 5=hdr_check_host, 6=req_done
 *
 * Encoding: (action << 5) | next_state  (3-bit action, 5-bit state)
 *
 * 9 columns: ALPHA DIGIT SP    CR    LF    COLON SLASH DOT   OTHER
 * =================================================================== */
.section .rodata
.balign 4
.global http_fsa_table
http_fsa_table:
/*  S_METHOD(0)  */ .byte 0x00, 0x13, 0x01, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_M_SP(1)    */ .byte 0x22, 0x22, 0x13, 0x13, 0x13, 0x22, 0x22, 0x22, 0x22
/*  S_URI(2)     */ .byte 0x02, 0x02, 0x43, 0x13, 0x13, 0x02, 0x02, 0x02, 0x02
/*  S_U_SP(3)    */ .byte 0x04, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_VH(4)      */ .byte 0x05, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_VT1(5)     */ .byte 0x06, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_VT2(6)     */ .byte 0x07, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_VP(7)      */ .byte 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x08, 0x13, 0x13
/*  S_VSLASH(8)  */ .byte 0x13, 0x09, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_VMAJ(9)    */ .byte 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x0A, 0x13
/*  S_VDOT(10)   */ .byte 0x13, 0x6B, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_VMIN(11)   */ .byte 0x13, 0x13, 0x13, 0x0C, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_RL_CR(12)  */ .byte 0x13, 0x13, 0x13, 0x13, 0x0D, 0x13, 0x13, 0x13, 0x13
/*  S_HDR_ST(13) */ .byte 0x8E, 0x13, 0x13, 0x11, 0x13, 0x13, 0x13, 0x13, 0x13
/*  S_HDR_NM(14) */ .byte 0x0E, 0x0E, 0x13, 0x13, 0x13, 0xAF, 0x0E, 0x0E, 0x0E
/*  S_HDR_VL(15) */ .byte 0x0F, 0x0F, 0x0F, 0x10, 0x13, 0x0F, 0x0F, 0x0F, 0x0F
/*  S_HDR_CR(16) */ .byte 0x13, 0x13, 0x13, 0x13, 0x0D, 0x13, 0x13, 0x13, 0x13
/*  S_END_CR(17) */ .byte 0x13, 0x13, 0x13, 0x13, 0xD2, 0x13, 0x13, 0x13, 0x13
/*  S_DONE(18)   */ .byte 0x12, 0x12, 0x12, 0x12, 0x12, 0x12, 0x12, 0x12, 0x12
/*  S_ERROR(19)  */ .byte 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13, 0x13

/* Reference string for case-insensitive "connection" header match */
http_conn_name:
    .ascii  "connection"

/* Reference string for case-insensitive "content-length" header match */
http_content_length_name:
    .ascii  "content-length"

/* ===================================================================
 * Character classification lookup table (256 bytes)
 *
 * Maps each ASCII byte to its CC_* class. Single ldrb lookup.
 * =================================================================== */
.balign 16
.global http_char_class_table
http_char_class_table:
    /*     0     1     2     3     4     5     6     7 */
    /* 00 */ .byte 8, 8, 8, 8, 8, 8, 8, 8      /* NUL-BEL */
    /* 08 */ .byte 8, 8, 4, 8, 8, 3, 8, 8      /* BS,HT,LF,VT,FF,CR,SO,SI */
    /* 10 */ .byte 8, 8, 8, 8, 8, 8, 8, 8      /* DLE-ETB */
    /* 18 */ .byte 8, 8, 8, 8, 8, 8, 8, 8      /* CAN-US */
    /* 20 */ .byte 2, 8, 8, 8, 8, 8, 8, 8      /* SP ! " # $ % & ' */
    /* 28 */ .byte 8, 8, 8, 8, 8, 8, 7, 6      /* ( ) * + , - . / */
    /* 30 */ .byte 1, 1, 1, 1, 1, 1, 1, 1      /* 0-7 */
    /* 38 */ .byte 1, 1, 5, 8, 8, 8, 8, 8      /* 8 9 : ; < = > ? */
    /* 40 */ .byte 8, 0, 0, 0, 0, 0, 0, 0      /* @ A-G */
    /* 48 */ .byte 0, 0, 0, 0, 0, 0, 0, 0      /* H-O */
    /* 50 */ .byte 0, 0, 0, 0, 0, 0, 0, 0      /* P-W */
    /* 58 */ .byte 0, 0, 0, 8, 8, 8, 8, 8      /* X Y Z [ \ ] ^ _ */
    /* 60 */ .byte 8, 0, 0, 0, 0, 0, 0, 0      /* ` a-g */
    /* 68 */ .byte 0, 0, 0, 0, 0, 0, 0, 0      /* h-o */
    /* 70 */ .byte 0, 0, 0, 0, 0, 0, 0, 0      /* p-w */
    /* 78 */ .byte 0, 0, 0, 8, 8, 8, 8, 8      /* x y z { | } ~ DEL */
    /* 80-FF: all OTHER */
    .byte 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8
    .byte 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8
    .byte 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8
    .byte 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8
    .byte 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8
    .byte 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8
    .byte 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8
    .byte 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8
