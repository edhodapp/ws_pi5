/*
 * test_reasm_func.S — Functional test harness for IP fragment reassembly
 *
 * Loads binary test vectors (.incbin), loops over them, calls
 * ip_reasm_input, verifies return value and post-slot state.
 *
 * Mirrors tests/test_tcp_func.S architecture.
 *
 * Binary entry layout (384 bytes):
 *
 *   Pre-seed block (offset 0, 40 bytes):
 *     [0]      u8   slot_state_code (0=empty, 1=first_half,
 *                   2=second_half, 3=near_complete)
 *     [1]      u8   pool_free (1=yes, 0=no)
 *     [2]      u8   pre_flags (bit7=active, bit0=have_last)
 *     [3]      u8   pre_min_ttl
 *     [4..5]   u16  pre_total_len (LE)
 *     [6..7]   pad
 *     [8..39]  32B  pre_bitmap
 *
 *   Fragment input block (offset 40, 264 bytes):
 *     [40..41] u16  frame_len (LE)
 *     [42..43] u16  frag_offset (unused by harness — info only)
 *     [44..45] u16  payload_len (unused by harness — info only)
 *     [46]     u8   mf_flag (unused by harness — info only)
 *     [47]     pad
 *     [48..303] 256B frame_data
 *
 *   Expected output block (offset 304, 40 bytes + pad to 384):
 *     [304]    u8   expected_ret_nonzero (1=complete, 0=drop/incomplete)
 *     [305]    u8   expected_reason (diagnostic only)
 *     [306]    u8   expected_post_active (1=slot still active)
 *     [307]    u8   expected_post_have_last
 *     [308..309] u16 expected_post_total_len (LE)
 *     [310..311] pad
 *     [312..343] 32B expected_post_bitmap
 *
 *   Header: 16 bytes at blob start.  [0..3] = u32 LE entry count.
 */

.include "net.inc"
.include "timer.inc"

.global test_reasm_functional

/* Entry layout offsets */
.equ RE_STATE_CODE,         0
.equ RE_POOL_FREE,          1
.equ RE_PRE_FLAGS,          2
.equ RE_PRE_MIN_TTL,        3
.equ RE_PRE_TOTAL_LEN,      4
.equ RE_PRE_BITMAP,         8

.equ RE_FRAME_LEN,          40
.equ RE_FRAG_OFFSET,        42
.equ RE_PAYLOAD_LEN,        44
.equ RE_MF_FLAG,            46
.equ RE_FRAME_DATA,         48

.equ RE_EXPECTED_RET,       304
.equ RE_EXPECTED_REASON,    305
.equ RE_EXPECTED_ACTIVE,    306
.equ RE_EXPECTED_HAVE_LAST, 307
.equ RE_EXPECTED_TOTAL_LEN, 308
.equ RE_EXPECTED_BITMAP,    312

.equ RE_SIZE,               384

/* Canonical flow key (NBO bytes stored directly — matches wire order) */
.equ KEY_SRC_IP,   0x0202000A      /* 10.0.2.2  in LE from NBO */
.equ KEY_DST_IP,   0x0F02000A      /* 10.0.2.15 in LE from NBO */
.equ KEY_IP_ID,    0xCDAB          /* 0xABCD in LE from NBO */
.equ KEY_PROTO,    1               /* ICMP */

/* Dummy ip_id values for filling non-matching slots */
.equ DUMMY_ID_1,   0x0100
.equ DUMMY_ID_2,   0x0200
.equ DUMMY_ID_3,   0x0300

.section .text

/* ---------------------------------------------------------------------------
 * reasm_write_hex8 — Write 2-digit hex into buffer at x1
 * w0: 8-bit value, x1: destination pointer (2 bytes written)
 * Clobbers: w2, w3
 * --------------------------------------------------------------------------- */
reasm_write_hex8:
    lsr     w2, w0, #4
    and     w2, w2, #0xF
    cmp     w2, #10
    b.lt    .Lrwh_hi_digit
    add     w2, w2, #('A' - 10)
    b       .Lrwh_hi_store
.Lrwh_hi_digit:
    add     w2, w2, #'0'
.Lrwh_hi_store:
    strb    w2, [x1]

    and     w3, w0, #0xF
    cmp     w3, #10
    b.lt    .Lrwh_lo_digit
    add     w3, w3, #('A' - 10)
    b       .Lrwh_lo_store
.Lrwh_lo_digit:
    add     w3, w3, #'0'
.Lrwh_lo_store:
    strb    w3, [x1, #1]
    ret

/* ---------------------------------------------------------------------------
 * test_reasm_functional — Main functional test loop
 *
 * Register allocation:
 *   x19: table base (after 16-byte header)
 *   w20: entry count (N)
 *   w21: loop index (i)
 *   x22: current entry pointer
 *   x23: scratch frame buffer address
 *   x24: reasm_slots base address
 *   x25: timer pool address
 *   x26: name buffer address
 * --------------------------------------------------------------------------- */
test_reasm_functional:
    stp     x29, x30, [sp, #-80]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    /* Load table header */
    ldr     x19, =reasm_func_table
    ldr     w20, [x19]              /* entry count */
    add     x19, x19, #16           /* skip header, point to first entry */
    mov     w21, #0                 /* i = 0 */
    ldr     x23, =reasm_func_scratch
    ldr     x24, =reasm_slots
    ldr     x25, =reasm_func_timer_pool
    ldr     x26, =reasm_name_buf

.Lrf_loop:
    cmp     w21, w20
    b.ge    .Lrf_done

    /* x22 = &table[i] — compute entry pointer */
    mov     w0, #RE_SIZE
    umull   x22, w21, w0
    add     x22, x22, x19

    /* Write hex index into name buffer "reasm_XX\0" */
    mov     w0, w21
    add     x1, x26, #6            /* point to the "XX" portion */
    bl      reasm_write_hex8

    /* --- 1. ip_reasm_init — zeros all 4 slots --- */
    bl      ip_reasm_init

    /* Set up timer pool for reassembly timeouts */
    mov     x0, x25
    mov     w1, #TPOOL_DEFAULT_CAP
    bl      timer_pool_init
    mov     x0, x25
    bl      ip_reasm_set_timer_pool

    /* --- 2. Pre-seed slot 0 if slot_state_code != 0 --- */
    ldrb    w0, [x22, #RE_STATE_CODE]
    cbz     w0, .Lrf_check_pool

    /* Write canonical key to slot 0 header */
    ldr     x24, =reasm_slots

    ldr     w0, =KEY_SRC_IP
    str     w0, [x24, #REASM_SRC_IP]
    ldr     w0, =KEY_DST_IP
    str     w0, [x24, #REASM_DST_IP]
    mov     w0, #KEY_IP_ID
    strh    w0, [x24, #REASM_IP_ID]
    mov     w0, #KEY_PROTO
    strb    w0, [x24, #REASM_PROTO]

    /* Write pre_flags, pre_min_ttl, pre_total_len */
    ldrb    w0, [x22, #RE_PRE_FLAGS]
    strb    w0, [x24, #REASM_FLAGS]
    ldrb    w0, [x22, #RE_PRE_MIN_TTL]
    strb    w0, [x24, #REASM_MIN_TTL]
    ldrh    w0, [x22, #RE_PRE_TOTAL_LEN]
    strh    w0, [x24, #REASM_TOTAL_LEN]

    /* Write 0xFF to REASM_TIMER_SLOT (no active timer) */
    mov     w0, #0xFF
    strb    w0, [x24, #REASM_TIMER_SLOT]

    /* Copy 32 bytes of pre_bitmap from entry to slot[REASM_BITMAP] */
    add     x0, x22, #RE_PRE_BITMAP     /* src: entry bitmap */
    add     x1, x24, #REASM_BITMAP      /* dst: slot bitmap */
    ldp     x2, x3, [x0]
    stp     x2, x3, [x1]
    ldp     x2, x3, [x0, #16]
    stp     x2, x3, [x1, #16]

.Lrf_check_pool:
    /* --- 3. If pool_free == 0: fill remaining slots with dummies --- */
    ldrb    w0, [x22, #RE_POOL_FREE]
    cbnz    w0, .Lrf_copy_frame         /* pool_free == 1 → skip */

    /* Determine which slots to fill.
     * If slot_state == empty (code 0): fill all 4 slots (0..3).
     * If slot_state != empty (code != 0): fill slots 1,2,3.
     */
    ldr     x24, =reasm_slots
    ldrb    w4, [x22, #RE_STATE_CODE]
    cbz     w4, .Lrf_fill_slot0

    /* slot_state != empty: slot 0 already pre-seeded, fill 1,2,3 */
    mov     w5, #1                      /* start slot index */
    b       .Lrf_fill_loop

.Lrf_fill_slot0:
    /* slot_state == empty: fill all 4 slots */
    mov     w5, #0                      /* start slot index */

.Lrf_fill_loop:
    cmp     w5, #REASM_MAX_SLOTS
    b.ge    .Lrf_copy_frame

    /* Calculate slot pointer: x24 + w5 * REASM_SLOT_SIZE */
    mov     w0, #REASM_SLOT_SIZE
    umull   x6, w5, w0
    add     x6, x6, x24                /* x6 = slot pointer */

    /* Write canonical src/dst but different ip_id so they don't match */
    ldr     w0, =KEY_SRC_IP
    str     w0, [x6, #REASM_SRC_IP]
    ldr     w0, =KEY_DST_IP
    str     w0, [x6, #REASM_DST_IP]

    /* Use slot index to pick a unique dummy ip_id */
    add     w0, w5, #1                 /* 1, 2, 3, or 4 — all != 0xCDAB */
    strh    w0, [x6, #REASM_IP_ID]

    mov     w0, #KEY_PROTO
    strb    w0, [x6, #REASM_PROTO]

    /* Mark active (bit 7 set) */
    mov     w0, #0x80
    strb    w0, [x6, #REASM_FLAGS]

    /* Timer slot = 0xFF (no timer) */
    mov     w0, #0xFF
    strb    w0, [x6, #REASM_TIMER_SLOT]

    add     w5, w5, #1
    b       .Lrf_fill_loop

.Lrf_copy_frame:
    /* --- 4. Copy frame_data (up to frame_len bytes) to scratch buffer --- */
    ldrh    w2, [x22, #RE_FRAME_LEN]
    add     x0, x22, #RE_FRAME_DATA    /* src: frame_data in entry */
    mov     x1, x23                     /* dst: scratch buffer */
    mov     w3, #0
.Lrf_copy:
    cmp     w3, w2
    b.ge    .Lrf_copy_done
    ldrb    w4, [x0, x3]
    strb    w4, [x1, x3]
    add     w3, w3, #1
    b       .Lrf_copy
.Lrf_copy_done:

    /* --- 5. Call ip_reasm_input(scratch_buf, frame_len) --- */
    mov     x0, x23
    ldrh    w1, [x22, #RE_FRAME_LEN]
    bl      ip_reasm_input
    /* x0 = pointer to reassembled frame or 0 */

    /* --- 6. Check return: w0 != 0 vs expected_ret_nonzero --- */
    ldrb    w1, [x22, #RE_EXPECTED_RET]
    cmp     x0, #0
    cset    w2, ne                      /* w2 = 1 if returned non-zero */
    cmp     w2, w1
    b.ne    .Lrf_fail

    /* --- 7. Check slot 0's post-state --- */
    ldr     x24, =reasm_slots

    /* Check REASM_FLAGS bit 7 (active) against expected_post_active */
    ldrb    w3, [x24, #REASM_FLAGS]
    ubfx    w3, w3, #7, #1             /* w3 = active bit */
    ldrb    w4, [x22, #RE_EXPECTED_ACTIVE]
    cmp     w3, w4
    b.ne    .Lrf_fail

    /* If slot is not expected to be active, skip remaining slot checks */
    cbz     w4, .Lrf_pass

    /* Check have_last (bit 0 of REASM_FLAGS) */
    ldrb    w3, [x24, #REASM_FLAGS]
    and     w3, w3, #1                  /* w3 = have_last bit */
    ldrb    w4, [x22, #RE_EXPECTED_HAVE_LAST]
    cmp     w3, w4
    b.ne    .Lrf_fail

    /* Check post total_len */
    ldrh    w3, [x24, #REASM_TOTAL_LEN]
    ldrh    w4, [x22, #RE_EXPECTED_TOTAL_LEN]
    cmp     w3, w4
    b.ne    .Lrf_fail

    /* Check 32-byte post bitmap */
    add     x5, x24, #REASM_BITMAP
    add     x6, x22, #RE_EXPECTED_BITMAP
    ldp     x7, x8, [x5]
    ldp     x9, x10, [x6]
    cmp     x7, x9
    b.ne    .Lrf_fail
    cmp     x8, x10
    b.ne    .Lrf_fail
    ldp     x7, x8, [x5, #16]
    ldp     x9, x10, [x6, #16]
    cmp     x7, x9
    b.ne    .Lrf_fail
    cmp     x8, x10
    b.ne    .Lrf_fail

.Lrf_pass:
    mov     x0, x26                     /* name buffer: "reasm_XX" */
    bl      test_pass
    b       .Lrf_next

.Lrf_fail:
    mov     x0, x26                     /* name buffer: "reasm_XX" */
    bl      test_fail

.Lrf_next:
    add     w21, w21, #1
    b       .Lrf_loop

.Lrf_done:
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret

/* --- Data sections --- */

.section .rodata
.balign 4
reasm_func_table:
    .incbin "build/reasm_vectors.bin"

.section .data
.balign 8
reasm_func_timer_pool:
    .space  TPOOL_DEFAULT_SIZE

/* Mutable name buffer: "reasm_XX\0" — hex index written at runtime */
reasm_name_buf:
    .ascii  "reasm_00"
    .byte   0

.section .bss
.balign 16
reasm_func_scratch:
    .space  ETH_FRAME_MAX
