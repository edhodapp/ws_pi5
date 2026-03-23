/*
 * test_cpsw.S — CPSW top-level driver tests
 *
 * 7 tests: init success/failures (3 failure paths),
 * state struct verification, send/recv stub verification.
 *
 * Uses a 256 KB fake register block and injects fakes into
 * the MDIO and MACSL poll function pointers.
 */

.include "cpsw.inc"

.section .text

/* -----------------------------------------------------------------------
 * Helpers
 * ----------------------------------------------------------------------- */

/* Zero the 64-byte state struct */
zero_state:
    ldr     x0, =fake_cpsw_state
    stp     xzr, xzr, [x0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]
    stp     xzr, xzr, [x0, #48]
    ret

/* Zero the MDIO region (0x90 bytes at offset 0xF00) in the fake block */
zero_mdio_region:
    ldr     x0, =fake_cpsw_regs
    add     x0, x0, #CPSW_MDIO_OFFSET
    add     x1, x0, #MDIO_FAKE_SIZE
.Lzm:
    stp     xzr, xzr, [x0], #16
    cmp     x0, x1
    b.lo    .Lzm
    ret

/* Zero MACSL region (16 bytes at NU+0x2000+0x330) */
zero_macsl_region:
    ldr     x0, =fake_cpsw_regs
    add     x0, x0, #0x20, lsl #12     /* +0x20000 (NU) */
    add     x0, x0, #0x2, lsl #12      /* +0x2000 (port 1) */
    add     x0, x0, #PN_MACSL_OFFSET   /* +0x330 */
    stp     xzr, xzr, [x0]
    ret

/* Save all three poll function pointers, install fakes */
.macro save_poll_fns
    ldr     x9, =cpsw_mdio_poll_idle_fn
    ldr     x10, [x9]
    ldr     x11, =cpsw_mdio_poll_go_fn
    ldr     x12, [x11]
    ldr     x13, =cpsw_macsl_poll_reset_fn
    ldr     x14, [x13]
.endm

/* Restore all three poll function pointers */
.macro restore_poll_fns
    ldr     x9, =cpsw_mdio_poll_idle_fn
    str     x10, [x9]
    ldr     x9, =cpsw_mdio_poll_go_fn
    str     x12, [x9]
    ldr     x9, =cpsw_macsl_poll_reset_fn
    str     x14, [x9]
.endm

/* Install success fakes for all three polls */
install_success_fakes:
    ldr     x0, =cpsw_mdio_poll_idle_fn
    ldr     x1, =fake_idle_ok
    str     x1, [x0]

    ldr     x0, =cpsw_mdio_poll_go_fn
    ldr     x1, =fake_go_ack
    str     x1, [x0]

    ldr     x0, =cpsw_macsl_poll_reset_fn
    ldr     x1, =fake_reset_ok
    str     x1, [x0]
    ret

/* =======================================================================
 * Test 1: cpsw_init success — all sub-inits succeed
 * ======================================================================= */
.global test_cpsw_init_success
test_cpsw_init_success:
    stp     x19, x30, [sp, #-80]!
    stp     x20, x21, [sp, #16]
    stp     x10, x12, [sp, #32]
    stp     x14, xzr, [sp, #48]
    /* Save x9, x11, x13 for macro restore */
    stp     x9, x11, [sp, #56]
    str     x13, [sp, #72]

    bl      zero_state
    bl      zero_mdio_region
    bl      zero_macsl_region
    save_poll_fns
    bl      install_success_fakes

    ldr     x0, =fake_cpsw_state
    ldr     x1, =test_mac
    ldr     x2, =fake_cpsw_regs
    bl      cpsw_init

    mov     w19, w0
    restore_poll_fns

    cbnz    w19, .Lfail_init_ok

    ldr     x0, =name_init_ok
    bl      test_pass
    b       .Ldone_init_ok
.Lfail_init_ok:
    ldr     x0, =name_init_ok
    bl      test_fail
.Ldone_init_ok:
    ldr     x13, [sp, #72]
    ldp     x9, x11, [sp, #56]
    ldp     x14, xzr, [sp, #48]
    ldp     x10, x12, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #80
    ret

/* =======================================================================
 * Test 2: cpsw_init state populated — verify base addrs, PHY, speed
 * ======================================================================= */
.global test_cpsw_init_state_populated
test_cpsw_init_state_populated:
    stp     x19, x30, [sp, #-80]!
    stp     x20, x21, [sp, #16]
    stp     x10, x12, [sp, #32]
    stp     x14, xzr, [sp, #48]
    stp     x9, x11, [sp, #56]
    str     x13, [sp, #72]

    bl      zero_state
    bl      zero_mdio_region
    bl      zero_macsl_region
    save_poll_fns
    bl      install_success_fakes

    ldr     x0, =fake_cpsw_state
    ldr     x1, =test_mac
    ldr     x2, =fake_cpsw_regs
    bl      cpsw_init

    restore_poll_fns

    /* Verify state struct fields */
    ldr     x0, =fake_cpsw_state

    /* MDIO base = fake_cpsw_regs + 0xF00 */
    ldr     x1, [x0, #CPSW_ST_MDIO_BASE]
    ldr     x2, =fake_cpsw_regs
    add     x2, x2, #CPSW_MDIO_OFFSET
    cmp     x1, x2
    b.ne    .Lfail_state

    /* NU base = fake_cpsw_regs + 0x20000 */
    ldr     x1, [x0, #CPSW_ST_NU_BASE]
    ldr     x2, =fake_cpsw_regs
    add     x2, x2, #0x20, lsl #12
    cmp     x1, x2
    b.ne    .Lfail_state

    /* PHY addr = 0 */
    ldr     w1, [x0, #CPSW_ST_PHY_ADDR]
    cbnz    w1, .Lfail_state

    /* Link speed = 1000 */
    ldr     w1, [x0, #CPSW_ST_LINK_SPEED]
    cmp     w1, #SPEED_1000
    b.ne    .Lfail_state

    ldr     x0, =name_state
    bl      test_pass
    b       .Ldone_state
.Lfail_state:
    ldr     x0, =name_state
    bl      test_fail
.Ldone_state:
    ldr     x13, [sp, #72]
    ldp     x9, x11, [sp, #56]
    ldp     x14, xzr, [sp, #48]
    ldp     x10, x12, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #80
    ret

/* =======================================================================
 * Test 3: cpsw_init MDIO fail — idle poll times out
 * ======================================================================= */
.global test_cpsw_init_mdio_fail
test_cpsw_init_mdio_fail:
    stp     x19, x30, [sp, #-80]!
    stp     x20, x21, [sp, #16]
    stp     x10, x12, [sp, #32]
    stp     x14, xzr, [sp, #48]
    stp     x9, x11, [sp, #56]
    str     x13, [sp, #72]

    bl      zero_state
    bl      zero_mdio_region
    save_poll_fns

    /* MDIO idle → timeout */
    ldr     x0, =cpsw_mdio_poll_idle_fn
    ldr     x1, =fake_timeout
    str     x1, [x0]

    ldr     x0, =fake_cpsw_state
    ldr     x1, =test_mac
    ldr     x2, =fake_cpsw_regs
    bl      cpsw_init

    mov     w19, w0
    restore_poll_fns

    cmp     w19, #1
    b.ne    .Lfail_mdio_fail

    ldr     x0, =name_mdio_fail
    bl      test_pass
    b       .Ldone_mdio_fail
.Lfail_mdio_fail:
    ldr     x0, =name_mdio_fail
    bl      test_fail
.Ldone_mdio_fail:
    ldr     x13, [sp, #72]
    ldp     x9, x11, [sp, #56]
    ldp     x14, xzr, [sp, #48]
    ldp     x10, x12, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #80
    ret

/* =======================================================================
 * Test 4: cpsw_init PHY detect fail — MDIO read times out
 * ======================================================================= */
.global test_cpsw_init_phy_detect_fail
test_cpsw_init_phy_detect_fail:
    stp     x19, x30, [sp, #-80]!
    stp     x20, x21, [sp, #16]
    stp     x10, x12, [sp, #32]
    stp     x14, xzr, [sp, #48]
    stp     x9, x11, [sp, #56]
    str     x13, [sp, #72]

    bl      zero_state
    bl      zero_mdio_region
    save_poll_fns

    /* MDIO idle → success, MDIO go → timeout */
    ldr     x0, =cpsw_mdio_poll_idle_fn
    ldr     x1, =fake_idle_ok
    str     x1, [x0]
    ldr     x0, =cpsw_mdio_poll_go_fn
    ldr     x1, =fake_timeout
    str     x1, [x0]

    ldr     x0, =fake_cpsw_state
    ldr     x1, =test_mac
    ldr     x2, =fake_cpsw_regs
    bl      cpsw_init

    mov     w19, w0
    restore_poll_fns

    cmp     w19, #1
    b.ne    .Lfail_phy_fail

    ldr     x0, =name_phy_fail
    bl      test_pass
    b       .Ldone_phy_fail
.Lfail_phy_fail:
    ldr     x0, =name_phy_fail
    bl      test_fail
.Ldone_phy_fail:
    ldr     x13, [sp, #72]
    ldp     x9, x11, [sp, #56]
    ldp     x14, xzr, [sp, #48]
    ldp     x10, x12, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #80
    ret

/* =======================================================================
 * Test 5: cpsw_init MACSL reset fail — reset poll times out
 * ======================================================================= */
.global test_cpsw_init_macsl_fail
test_cpsw_init_macsl_fail:
    stp     x19, x30, [sp, #-80]!
    stp     x20, x21, [sp, #16]
    stp     x10, x12, [sp, #32]
    stp     x14, xzr, [sp, #48]
    stp     x9, x11, [sp, #56]
    str     x13, [sp, #72]

    bl      zero_state
    bl      zero_mdio_region
    bl      zero_macsl_region
    save_poll_fns

    /* MDIO idle + go → success, MACSL reset → timeout */
    bl      install_success_fakes
    ldr     x0, =cpsw_macsl_poll_reset_fn
    ldr     x1, =fake_timeout
    str     x1, [x0]

    ldr     x0, =fake_cpsw_state
    ldr     x1, =test_mac
    ldr     x2, =fake_cpsw_regs
    bl      cpsw_init

    mov     w19, w0
    restore_poll_fns

    cmp     w19, #1
    b.ne    .Lfail_macsl_fail

    ldr     x0, =name_macsl_fail
    bl      test_pass
    b       .Ldone_macsl_fail
.Lfail_macsl_fail:
    ldr     x0, =name_macsl_fail
    bl      test_fail
.Ldone_macsl_fail:
    ldr     x13, [sp, #72]
    ldp     x9, x11, [sp, #56]
    ldp     x14, xzr, [sp, #48]
    ldp     x10, x12, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #80
    ret

/* =======================================================================
 * Test 6: cpsw_send stub returns 1
 * ======================================================================= */
.global test_cpsw_send_stub
test_cpsw_send_stub:
    stp     x29, x30, [sp, #-16]!

    mov     x0, xzr
    mov     x1, xzr
    mov     x2, xzr
    mov     w3, #0
    bl      cpsw_send

    cmp     w0, #1
    b.ne    .Lfail_send

    ldr     x0, =name_send_stub
    bl      test_pass
    b       .Ldone_send
.Lfail_send:
    ldr     x0, =name_send_stub
    bl      test_fail
.Ldone_send:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 7: cpsw_recv stub returns w0=1, w1=0
 * ======================================================================= */
.global test_cpsw_recv_stub
test_cpsw_recv_stub:
    stp     x29, x30, [sp, #-16]!

    mov     x0, xzr
    mov     x1, xzr
    mov     x2, xzr
    mov     w3, #0
    bl      cpsw_recv

    cmp     w0, #1
    b.ne    .Lfail_recv
    cbnz    w1, .Lfail_recv

    ldr     x0, =name_recv_stub
    bl      test_pass
    b       .Ldone_recv
.Lfail_recv:
    ldr     x0, =name_recv_stub
    bl      test_fail
.Ldone_recv:
    ldp     x29, x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * Fake poll functions for cpsw_init testing
 * ----------------------------------------------------------------------- */

/* MDIO idle success: write ENABLE|CLKDIV to CONTROL, return it */
fake_idle_ok:
    mov     w1, #MDIO_CLKDIV_DEFAULT
    orr     w1, w1, #MDIO_CTRL_ENABLE
    str     w1, [x0, #MDIO_CONTROL]
    mov     w0, w1
    ret

/* MDIO GO success: write ACK|0x1234 to USERACCESS0, return it */
fake_go_ack:
    ldr     w1, =0x20001234         /* ACK | PHYID=0x1234 */
    str     w1, [x0, #MDIO_USERACCESS0]
    mov     w0, w1
    ret

/* MACSL reset success */
fake_reset_ok:
    mov     w0, #1
    ret

/* Generic timeout */
fake_timeout:
    mov     w0, #0
    ret

/* -----------------------------------------------------------------------
 * Test data
 * ----------------------------------------------------------------------- */
.section .rodata
.balign 2
test_mac: .byte 0x02, 0xBE, 0xEF, 0x00, 0x00, 0x01

/* -----------------------------------------------------------------------
 * BSS
 * ----------------------------------------------------------------------- */
.section .bss
.balign 8
fake_cpsw_state:
    .space CPSW_ST_SIZE

.balign 16
fake_cpsw_regs:
    .space CPSW_FAKE_SIZE

/* -----------------------------------------------------------------------
 * Test name strings
 * ----------------------------------------------------------------------- */
.section .rodata
name_init_ok:       .asciz "cpsw_init"
name_state:         .asciz "cpsw_init_state_populated"
name_mdio_fail:     .asciz "cpsw_init_mdio_fail"
name_phy_fail:      .asciz "cpsw_init_phy_detect_fail"
name_macsl_fail:    .asciz "cpsw_init_macsl_fail"
name_send_stub:     .asciz "cpsw_send_stub"
name_recv_stub:     .asciz "cpsw_recv_stub"
