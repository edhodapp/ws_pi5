/*
 * md5.S — MD5 hash (RFC 1321)
 *
 * md5_hash(input, length, output): compute 16-byte MD5 digest.
 * Supports inputs up to 119 bytes (2 padded blocks).
 */

.global md5_hash

.section .text

/*
 * md5_hash — Compute MD5 digest
 *
 * x0: input pointer
 * w1: input length (bytes, 0..119)
 * x2: output pointer (16 bytes)
 * Clobbers: x0-x12, x19-x20, x30
 */
md5_hash:
    stp     x29, x30, [sp, #-224]!
    stp     x19, x20, [sp, #16]

    mov     x19, x2                 /* output ptr */
    mov     w20, w1                 /* input length */

    /* Copy input to stack buffer at sp+48 (192 bytes) */
    add     x2, sp, #48
    mov     w3, #0
.Lmh_copy:
    cmp     w3, w1
    b.hs    .Lmh_copy_done
    ldrb    w4, [x0, w3, uxtw]
    strb    w4, [x2, w3, uxtw]
    add     w3, w3, #1
    b       .Lmh_copy
.Lmh_copy_done:

    /* Append 0x80 */
    mov     w4, #0x80
    strb    w4, [x2, w20, uxtw]
    add     w3, w20, #1             /* current position */

    /* Determine pad target: first N ≡ 56 (mod 64) where N >= w3 */
    mov     w5, #56
    cmp     w3, w5
    b.ls    .Lmh_pad_target
    mov     w5, #120                /* next 56-mod-64 boundary */
.Lmh_pad_target:
    /* Zero-fill from w3 to w5 */
.Lmh_zero:
    cmp     w3, w5
    b.hs    .Lmh_zero_done
    strb    wzr, [x2, w3, uxtw]
    add     w3, w3, #1
    b       .Lmh_zero
.Lmh_zero_done:

    /* Append 64-bit length in bits (little-endian) */
    lsl     w4, w20, #3             /* bits */
    str     w4, [x2, w3, uxtw]
    add     w3, w3, #4
    str     wzr, [x2, w3, uxtw]
    add     w3, w3, #4
    /* w3 = total padded length (64 or 128) */

    /* Initialize MD5 state at sp+32 (16 bytes) */
    add     x4, sp, #32
    ldr     x5, =md5_init_vals
    ldp     x6, x7, [x5]
    stp     x6, x7, [x4]

    /* Process block 1 */
    mov     x0, x4                  /* state */
    add     x1, sp, #48             /* block data */
    bl      md5_block

    /* Process block 2 if needed (input >= 56 bytes → 2 blocks) */
    cmp     w20, #56
    b.lo    .Lmh_done

    add     x0, sp, #32
    add     x1, sp, #112            /* block 2 = sp+48+64 */
    bl      md5_block

.Lmh_done:
    /* Copy state to output */
    add     x0, sp, #32
    ldp     x1, x2, [x0]
    stp     x1, x2, [x19]

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #224
    ret

/*
 * md5_block — Process one 64-byte MD5 block
 *
 * x0: state pointer (4 × u32, updated in place)
 * x1: block pointer (64 bytes, read-only)
 * Clobbers: x0-x12, x19-x23, x30
 */
md5_block:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x12, x0                 /* save state ptr */

    /* Load state: w2=a, w3=b, w4=c, w5=d */
    ldp     w2, w3, [x0]
    ldp     w4, w5, [x0, #8]

    /* Save initial state for final addition */
    mov     w19, w2
    mov     w20, w3
    mov     w21, w4
    mov     w22, w5

    ldr     x6, =md5_K
    ldr     x7, =md5_shifts
    mov     w8, #0                  /* round counter */

.Lmb_round:
    cmp     w8, #64
    b.hs    .Lmb_end

    /* Select round function + message index */
    cmp     w8, #16
    b.hs    .Lmb_not_F

    /* Pass 1: F(b,c,d) = (b & c) | (~b & d), g = i */
    and     w9, w3, w4
    bic     w10, w5, w3
    orr     w9, w9, w10
    mov     w10, w8
    b       .Lmb_common

.Lmb_not_F:
    cmp     w8, #32
    b.hs    .Lmb_not_G

    /* Pass 2: G(b,c,d) = (d & b) | (~d & c), g = (5*i+1) % 16 */
    and     w9, w5, w3
    bic     w10, w4, w5
    orr     w9, w9, w10
    mov     w10, #5
    mul     w10, w8, w10
    add     w10, w10, #1
    and     w10, w10, #15
    b       .Lmb_common

.Lmb_not_G:
    cmp     w8, #48
    b.hs    .Lmb_I

    /* Pass 3: H(b,c,d) = b ^ c ^ d, g = (3*i+5) % 16 */
    eor     w9, w3, w4
    eor     w9, w9, w5
    mov     w10, #3
    mul     w10, w8, w10
    add     w10, w10, #5
    and     w10, w10, #15
    b       .Lmb_common

.Lmb_I:
    /* Pass 4: I(b,c,d) = c ^ (~d | b), g = (7*i) % 16 */
    mvn     w9, w5
    orr     w9, w9, w3
    eor     w9, w9, w4
    mov     w10, #7
    mul     w10, w8, w10
    and     w10, w10, #15

.Lmb_common:
    /* w9 = f, w10 = g (message word index) */

    add     w2, w2, w9             /* a += f */
    ldr     w9, [x6, w8, uxtw #2] /* K[i] */
    add     w2, w2, w9             /* a += K[i] */
    ldr     w9, [x1, w10, uxtw #2] /* M[g] */
    add     w2, w2, w9             /* a += M[g] */

    /* Rotate left by s[i]: ROL(x, s) = ROR(x, 32-s) */
    ldrb    w10, [x7, w8, uxtw]   /* s[i] */
    mov     w9, #32
    sub     w9, w9, w10
    ror     w2, w2, w9

    add     w2, w2, w3             /* a = b + result */

    /* Rotate state: (a,b,c,d) ← (d, new_a, b, c) */
    mov     w9, w5                 /* save d */
    mov     w5, w4                 /* d = c */
    mov     w4, w3                 /* c = b */
    mov     w3, w2                 /* b = new_a */
    mov     w2, w9                 /* a = old_d */

    add     w8, w8, #1
    b       .Lmb_round

.Lmb_end:
    /* Add saved state */
    add     w2, w2, w19
    add     w3, w3, w20
    add     w4, w4, w21
    add     w5, w5, w22

    stp     w2, w3, [x12]
    stp     w4, w5, [x12, #8]

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #48
    ret

/* ---- Constant tables ---- */
.section .rodata
.balign 4

md5_init_vals:
    .word   0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

/* K[i] = floor(2^32 * |sin(i+1)|), i = 0..63 */
md5_K:
    .word   0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee
    .word   0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501
    .word   0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be
    .word   0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821
    .word   0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa
    .word   0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8
    .word   0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed
    .word   0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a
    .word   0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c
    .word   0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70
    .word   0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05
    .word   0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665
    .word   0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039
    .word   0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1
    .word   0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1
    .word   0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391

/* Per-round shift amounts (64 bytes) */
md5_shifts:
    .byte   7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22
    .byte   5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20
    .byte   4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23
    .byte   6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21
