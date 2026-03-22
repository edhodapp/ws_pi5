/*
 * test_cpsw_mdio.S — CPSW MDIO driver tests
 *
 * 13 tests covering both sides of every branch:
 *   init (success/timeout), read (success/timeout/nack),
 *   write (success/timeout), link (up/down), alive (yes/no),
 *   field encoding (read/write).
 *
 * All tests use a fake register block in BSS and injectable
 * poll function pointers — no hardware needed.
 */

.include "cpsw.inc"

.section .text

/* -----------------------------------------------------------------------
 * Helper: zero the fake MDIO register block
 * Clobbers: x0, x1, w2
 * ----------------------------------------------------------------------- */
zero_fake_mdio:
    ldr     x0, =fake_mdio_regs
    mov     w2, #MDIO_FAKE_SIZE
.Lzero_loop:
    subs    w2, w2, #8
    str     xzr, [x0, x2]
    b.gt    .Lzero_loop
    str     xzr, [x0]
    ret

/* =======================================================================
 * Test 1: cpsw_mdio_init success — IDLE clears after ENABLE
 * ======================================================================= */
.global test_mdio_init_success
test_mdio_init_success:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    /* Save original poll function */
    ldr     x19, =cpsw_mdio_poll_idle_fn
    ldr     x20, [x19]

    /* Install fake: returns ENABLE|CLKDIV (IDLE=0) */
    ldr     x0, =fake_poll_idle_ok
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    bl      cpsw_mdio_init

    /* Restore */
    str     x20, [x19]

    /* Verify success */
    cbnz    w0, .Lfail_init_success

    /* Verify CONTROL was written with ENABLE + CLKDIV */
    ldr     x0, =fake_mdio_regs
    ldr     w1, [x0, #MDIO_CONTROL]
    mov     w2, #MDIO_CLKDIV_DEFAULT
    orr     w2, w2, #MDIO_CTRL_ENABLE
    cmp     w1, w2
    b.ne    .Lfail_init_success

    ldr     x0, =name_mdio_init_success
    bl      test_pass
    b       .Ldone_init_success
.Lfail_init_success:
    ldr     x0, =name_mdio_init_success
    bl      test_fail
.Ldone_init_success:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 2: cpsw_mdio_init timeout — IDLE never clears
 * ======================================================================= */
.global test_mdio_init_timeout
test_mdio_init_timeout:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    ldr     x19, =cpsw_mdio_poll_idle_fn
    ldr     x20, [x19]

    /* Install fake: returns 0 (timeout) */
    ldr     x0, =fake_poll_timeout
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    bl      cpsw_mdio_init

    str     x20, [x19]

    /* Verify failure */
    cmp     w0, #1
    b.ne    .Lfail_init_timeout

    ldr     x0, =name_mdio_init_timeout
    bl      test_pass
    b       .Ldone_init_timeout
.Lfail_init_timeout:
    ldr     x0, =name_mdio_init_timeout
    bl      test_fail
.Ldone_init_timeout:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 3: cpsw_mdio_read success — GO clears, ACK=1, data=0xABCD
 * ======================================================================= */
.global test_mdio_read_success
test_mdio_read_success:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    ldr     x19, =cpsw_mdio_poll_go_fn
    ldr     x20, [x19]

    /* Install fake: writes ACK|0xABCD to USERACCESS0, returns it */
    ldr     x0, =fake_poll_go_ack_abcd
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    mov     w1, #1              /* PHY 1 */
    mov     w2, #0              /* Reg 0 */
    bl      cpsw_mdio_read

    str     x20, [x19]

    /* w0 should be 0xABCD, w1 should be 0 */
    mov     w2, #0xABCD
    movk    w2, #0, lsl #16
    cmp     w0, w2
    b.ne    .Lfail_read_success
    cbnz    w1, .Lfail_read_success

    ldr     x0, =name_mdio_read_success
    bl      test_pass
    b       .Ldone_read_success
.Lfail_read_success:
    ldr     x0, =name_mdio_read_success
    bl      test_fail
.Ldone_read_success:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 4: cpsw_mdio_read timeout — GO never clears
 * ======================================================================= */
.global test_mdio_read_timeout
test_mdio_read_timeout:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    ldr     x19, =cpsw_mdio_poll_go_fn
    ldr     x20, [x19]

    ldr     x0, =fake_poll_timeout
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    mov     w1, #1
    mov     w2, #0
    bl      cpsw_mdio_read

    str     x20, [x19]

    /* w1 should be 1 (failure) */
    cmp     w1, #1
    b.ne    .Lfail_read_timeout

    ldr     x0, =name_mdio_read_timeout
    bl      test_pass
    b       .Ldone_read_timeout
.Lfail_read_timeout:
    ldr     x0, =name_mdio_read_timeout
    bl      test_fail
.Ldone_read_timeout:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 5: cpsw_mdio_read NACK — GO clears but ACK=0
 * ======================================================================= */
.global test_mdio_read_nack
test_mdio_read_nack:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    ldr     x19, =cpsw_mdio_poll_go_fn
    ldr     x20, [x19]

    /* Install fake: GO=0, ACK=0, returns non-zero (just DATA=0) */
    ldr     x0, =fake_poll_go_nack
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    mov     w1, #1
    mov     w2, #0
    bl      cpsw_mdio_read

    str     x20, [x19]

    /* w1 should be 1 (NACK failure) */
    cmp     w1, #1
    b.ne    .Lfail_read_nack

    ldr     x0, =name_mdio_read_nack
    bl      test_pass
    b       .Ldone_read_nack
.Lfail_read_nack:
    ldr     x0, =name_mdio_read_nack
    bl      test_fail
.Ldone_read_nack:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 6: cpsw_mdio_write success — GO clears
 * ======================================================================= */
.global test_mdio_write_success
test_mdio_write_success:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    ldr     x19, =cpsw_mdio_poll_go_fn
    ldr     x20, [x19]

    ldr     x0, =fake_poll_go_ok
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    mov     w1, #1              /* PHY 1 */
    mov     w2, #4              /* Reg 4 (ANAR) */
    mov     w3, #0x1234         /* Data */
    bl      cpsw_mdio_write

    str     x20, [x19]

    /* Verify success */
    cbnz    w0, .Lfail_write_success

    ldr     x0, =name_mdio_write_success
    bl      test_pass
    b       .Ldone_write_success
.Lfail_write_success:
    ldr     x0, =name_mdio_write_success
    bl      test_fail
.Ldone_write_success:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 7: cpsw_mdio_write timeout — GO never clears
 * ======================================================================= */
.global test_mdio_write_timeout
test_mdio_write_timeout:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    ldr     x19, =cpsw_mdio_poll_go_fn
    ldr     x20, [x19]

    ldr     x0, =fake_poll_timeout
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    mov     w1, #1
    mov     w2, #4
    mov     w3, #0x1234
    bl      cpsw_mdio_write

    str     x20, [x19]

    cmp     w0, #1
    b.ne    .Lfail_write_timeout

    ldr     x0, =name_mdio_write_timeout
    bl      test_pass
    b       .Ldone_write_timeout
.Lfail_write_timeout:
    ldr     x0, =name_mdio_write_timeout
    bl      test_fail
.Ldone_write_timeout:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 8: cpsw_mdio_link_status — link up
 * ======================================================================= */
.global test_mdio_link_up
test_mdio_link_up:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_mdio

    /* Set PHY 3 bit in LINK register */
    ldr     x0, =fake_mdio_regs
    mov     w1, #(1 << 3)
    str     w1, [x0, #MDIO_LINK]

    mov     w1, #3
    bl      cpsw_mdio_link_status

    cmp     w0, #1
    b.ne    .Lfail_link_up

    ldr     x0, =name_mdio_link_up
    bl      test_pass
    b       .Ldone_link_up
.Lfail_link_up:
    ldr     x0, =name_mdio_link_up
    bl      test_fail
.Ldone_link_up:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 9: cpsw_mdio_link_status — link down
 * ======================================================================= */
.global test_mdio_link_down
test_mdio_link_down:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_mdio

    /* LINK register is zero (from zero_fake_mdio) */
    ldr     x0, =fake_mdio_regs
    mov     w1, #3
    bl      cpsw_mdio_link_status

    cbnz    w0, .Lfail_link_down

    ldr     x0, =name_mdio_link_down
    bl      test_pass
    b       .Ldone_link_down
.Lfail_link_down:
    ldr     x0, =name_mdio_link_down
    bl      test_fail
.Ldone_link_down:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 10: cpsw_mdio_phy_alive — PHY detected
 * ======================================================================= */
.global test_mdio_phy_alive
test_mdio_phy_alive:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_mdio

    /* Set PHY 5 bit in ALIVE register */
    ldr     x0, =fake_mdio_regs
    mov     w1, #(1 << 5)
    str     w1, [x0, #MDIO_ALIVE]

    mov     w1, #5
    bl      cpsw_mdio_phy_alive

    cmp     w0, #1
    b.ne    .Lfail_phy_alive

    ldr     x0, =name_mdio_phy_alive
    bl      test_pass
    b       .Ldone_phy_alive
.Lfail_phy_alive:
    ldr     x0, =name_mdio_phy_alive
    bl      test_fail
.Ldone_phy_alive:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 11: cpsw_mdio_phy_alive — PHY not detected
 * ======================================================================= */
.global test_mdio_phy_not_alive
test_mdio_phy_not_alive:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_mdio

    ldr     x0, =fake_mdio_regs
    mov     w1, #5
    bl      cpsw_mdio_phy_alive

    cbnz    w0, .Lfail_phy_not_alive

    ldr     x0, =name_mdio_phy_not_alive
    bl      test_pass
    b       .Ldone_phy_not_alive
.Lfail_phy_not_alive:
    ldr     x0, =name_mdio_phy_not_alive
    bl      test_fail
.Ldone_phy_not_alive:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 12: cpsw_mdio_read field encoding — verify BFI composition
 *          PHY=17, REG=31 (max values to stress field boundaries)
 * ======================================================================= */
.global test_mdio_read_field_encoding
test_mdio_read_field_encoding:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    ldr     x19, =cpsw_mdio_poll_go_fn
    ldr     x20, [x19]

    /* Install fake that returns ACK + data */
    ldr     x0, =fake_poll_go_ack_abcd
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    mov     w1, #17             /* PHY 17 */
    mov     w2, #31             /* REG 31 */
    bl      cpsw_mdio_read

    str     x20, [x19]

    /* Read what the driver wrote to USERACCESS0 before the fake replaced it */
    /* The driver writes, then calls poll. The fake overwrites USERACCESS0.
     * To capture what was written, we need the fake to save it first.
     * Use fake_poll_go_capture which saves the original value. */

    /* Actually: the driver STRs to USERACCESS0, then calls poll.
     * The fake_poll_go_ack_abcd overwrites USERACCESS0 with ACK|0xABCD.
     * We need a different fake that captures the written value.
     * Use fake_poll_go_capture_and_ack. */

    /* Re-run with capture fake */
    bl      zero_fake_mdio
    ldr     x0, =fake_poll_go_capture_and_ack
    str     x0, [x19]

    /* Clear capture */
    ldr     x0, =captured_useraccess0
    str     wzr, [x0]

    ldr     x0, =fake_mdio_regs
    mov     w1, #17
    mov     w2, #31
    bl      cpsw_mdio_read

    str     x20, [x19]

    /* Check captured value */
    ldr     x0, =captured_useraccess0
    ldr     w0, [x0]

    /* Expected: GO | (31 << 21) | (17 << 16) = 0x83E10000 */
    /* GO=0x80000000, REG31<<21=0x03E00000, PHY17<<16=0x00110000 */
    ldr     w1, =0x83F10000
    cmp     w0, w1
    b.ne    .Lfail_read_field

    ldr     x0, =name_mdio_read_field
    bl      test_pass
    b       .Ldone_read_field
.Lfail_read_field:
    ldr     x0, =name_mdio_read_field
    bl      test_fail
.Ldone_read_field:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 13: cpsw_mdio_write field encoding — verify GO+WRITE+fields+data
 *          PHY=31, REG=0, DATA=0xFFFF (boundary values)
 * ======================================================================= */
.global test_mdio_write_field_encoding
test_mdio_write_field_encoding:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_mdio

    ldr     x19, =cpsw_mdio_poll_go_fn
    ldr     x20, [x19]

    /* Clear capture, install capture fake */
    ldr     x0, =captured_useraccess0
    str     wzr, [x0]
    ldr     x0, =fake_poll_go_capture_and_ack
    str     x0, [x19]

    ldr     x0, =fake_mdio_regs
    mov     w1, #31             /* PHY 31 */
    mov     w2, #0              /* REG 0 */
    mov     w3, #0xFFFF         /* DATA 0xFFFF */
    bl      cpsw_mdio_write

    str     x20, [x19]

    /* Check captured value */
    ldr     x0, =captured_useraccess0
    ldr     w0, [x0]

    /* Expected: GO | WRITE | (0 << 21) | (31 << 16) | 0xFFFF */
    /* = 0x80000000 | 0x40000000 | 0x001F0000 | 0x0000FFFF */
    /* = 0xC01FFFFF */
    ldr     w1, =0xC01FFFFF
    cmp     w0, w1
    b.ne    .Lfail_write_field

    ldr     x0, =name_mdio_write_field
    bl      test_pass
    b       .Ldone_write_field
.Lfail_write_field:
    ldr     x0, =name_mdio_write_field
    bl      test_fail
.Ldone_write_field:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* -----------------------------------------------------------------------
 * Fake poll functions
 * ----------------------------------------------------------------------- */

/* Returns ENABLE|CLKDIV (IDLE=0) — init success */
fake_poll_idle_ok:
    ldr     x9, =fake_mdio_regs
    mov     w10, #MDIO_CLKDIV_DEFAULT
    orr     w10, w10, #MDIO_CTRL_ENABLE
    str     w10, [x9, #MDIO_CONTROL]
    mov     w0, w10
    ret

/* Returns 0 — timeout for any poll */
fake_poll_timeout:
    mov     w0, #0
    ret

/* Returns ACK | 0xABCD in USERACCESS0 — read success */
fake_poll_go_ack_abcd:
    ldr     x9, =fake_mdio_regs
    ldr     w10, =0x2000ABCD        /* ACK | 0xABCD */
    str     w10, [x9, #MDIO_USERACCESS0]
    mov     w0, w10
    ret

/* Returns non-zero but no ACK — NACK */
fake_poll_go_nack:
    ldr     x9, =fake_mdio_regs
    mov     w10, #1                  /* non-zero, no ACK bit */
    str     w10, [x9, #MDIO_USERACCESS0]
    mov     w0, w10
    ret

/* Returns non-zero — write success (GO cleared) */
fake_poll_go_ok:
    mov     w0, #1
    ret

/* Captures USERACCESS0 written by driver, then returns ACK|0 */
fake_poll_go_capture_and_ack:
    ldr     x9, =fake_mdio_regs
    ldr     w10, [x9, #MDIO_USERACCESS0]
    ldr     x11, =captured_useraccess0
    str     w10, [x11]
    /* Write back ACK (so read path succeeds) */
    mov     w10, #MDIO_UA_ACK
    str     w10, [x9, #MDIO_USERACCESS0]
    mov     w0, w10
    ret

/* -----------------------------------------------------------------------
 * Data
 * ----------------------------------------------------------------------- */
.section .data
.balign 4
captured_useraccess0: .word 0

/* -----------------------------------------------------------------------
 * BSS — fake register block
 * ----------------------------------------------------------------------- */
.section .bss
.balign 8
fake_mdio_regs:
    .space MDIO_FAKE_SIZE

/* -----------------------------------------------------------------------
 * Test name strings
 * ----------------------------------------------------------------------- */
.section .rodata
name_mdio_init_success:     .asciz "cpsw_mdio_init"
name_mdio_init_timeout:     .asciz "cpsw_mdio_init_timeout"
name_mdio_read_success:     .asciz "cpsw_mdio_read"
name_mdio_read_timeout:     .asciz "cpsw_mdio_read_timeout"
name_mdio_read_nack:        .asciz "cpsw_mdio_read_nack"
name_mdio_write_success:    .asciz "cpsw_mdio_write"
name_mdio_write_timeout:    .asciz "cpsw_mdio_write_timeout"
name_mdio_link_up:          .asciz "cpsw_mdio_link_up"
name_mdio_link_down:        .asciz "cpsw_mdio_link_down"
name_mdio_phy_alive:        .asciz "cpsw_mdio_phy_alive"
name_mdio_phy_not_alive:    .asciz "cpsw_mdio_phy_not_alive"
name_mdio_read_field:       .asciz "cpsw_mdio_read_field_encoding"
name_mdio_write_field:      .asciz "cpsw_mdio_write_field_encoding"
