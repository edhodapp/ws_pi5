/*
 * test_cpsw_port.S — CPSW port and ALE configuration tests
 *
 * 15 tests covering both sides of every branch:
 *   nu_init (register writes), port_init (host/external),
 *   macsl_reset (success/timeout), macsl_config (1000/100/10/unknown),
 *   ale_init (CTL/port modes), MAC address field encoding.
 */

.include "cpsw.inc"

.section .text

/* -----------------------------------------------------------------------
 * Helpers: zero fake register blocks
 * ----------------------------------------------------------------------- */
zero_fake_nu:
    ldr     x0, =fake_nu_regs
    ldr     x1, =NU_FAKE_SIZE
    add     x1, x0, x1
.Lzero_nu:
    stp     xzr, xzr, [x0], #16
    cmp     x0, x1
    b.lo    .Lzero_nu
    ret

zero_fake_ale:
    ldr     x0, =fake_ale_regs
    ldr     x1, =ALE_FAKE_SIZE
    add     x1, x0, x1
.Lzero_ale:
    stp     xzr, xzr, [x0], #16
    cmp     x0, x1
    b.lo    .Lzero_ale
    ret

/* =======================================================================
 * Test 1: cpsw_nu_init — CTL register written with 0x6004
 * ======================================================================= */
.global test_nu_init_ctl_reg
test_nu_init_ctl_reg:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    bl      cpsw_nu_init

    ldr     x0, =fake_nu_regs
    ldr     w1, [x0, #NU_CTL_REG]
    mov     w2, #NU_CTL_INIT_VAL
    cmp     w1, w2
    b.ne    .Lfail_nu_ctl

    ldr     x0, =name_nu_init_ctl
    bl      test_pass
    b       .Ldone_nu_ctl
.Lfail_nu_ctl:
    ldr     x0, =name_nu_init_ctl
    bl      test_fail
.Ldone_nu_ctl:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 2: cpsw_nu_init — STAT_PORT_EN = 7, PTYPE = 0
 * ======================================================================= */
.global test_nu_init_stat_ptype
test_nu_init_stat_ptype:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    bl      cpsw_nu_init

    ldr     x0, =fake_nu_regs
    ldr     w1, [x0, #NU_STAT_PORT_EN]
    cmp     w1, #NU_STAT_PORT_EN_ALL
    b.ne    .Lfail_nu_stat

    ldr     w1, [x0, #NU_PTYPE_REG]
    cbnz    w1, .Lfail_nu_stat

    ldr     x0, =name_nu_init_stat
    bl      test_pass
    b       .Ldone_nu_stat
.Lfail_nu_stat:
    ldr     x0, =name_nu_init_stat
    bl      test_fail
.Ldone_nu_stat:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 3: cpsw_port_init host — RX_MAXLEN = 1522
 * ======================================================================= */
.global test_port_init_host_maxlen
test_port_init_host_maxlen:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    mov     w1, #0              /* port 0 (host) */
    mov     x2, xzr
    bl      cpsw_port_init

    /* Port 0 base = fake_nu_regs + NU_PORT0_OFFSET (0x1000) */
    ldr     x0, =fake_nu_regs
    ldr     w1, [x0, #(NU_PORT0_OFFSET + PN_RX_MAXLEN)]
    mov     w2, #PN_MAXLEN_DEFAULT
    cmp     w1, w2
    b.ne    .Lfail_host_maxlen

    ldr     x0, =name_host_maxlen
    bl      test_pass
    b       .Ldone_host_maxlen
.Lfail_host_maxlen:
    ldr     x0, =name_host_maxlen
    bl      test_fail
.Ldone_host_maxlen:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 4: cpsw_port_init host — FLOW_ID = 0, no MAC write
 * ======================================================================= */
.global test_port_init_host_flowid
test_port_init_host_flowid:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    mov     w1, #0
    mov     x2, xzr
    bl      cpsw_port_init

    ldr     x0, =fake_nu_regs

    /* FLOW_ID should be 0 */
    ldr     w1, [x0, #(NU_PORT0_OFFSET + PN_FLOW_ID_REG)]
    cbnz    w1, .Lfail_host_flowid

    /* SA_L and SA_H should remain 0 (not written for host port) */
    ldr     w1, [x0, #(NU_PORT0_OFFSET + PN_REG_SA_L)]
    cbnz    w1, .Lfail_host_flowid
    ldr     w1, [x0, #(NU_PORT0_OFFSET + PN_REG_SA_H)]
    cbnz    w1, .Lfail_host_flowid

    ldr     x0, =name_host_flowid
    bl      test_pass
    b       .Ldone_host_flowid
.Lfail_host_flowid:
    ldr     x0, =name_host_flowid
    bl      test_fail
.Ldone_host_flowid:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 5: cpsw_port_init external — RX_MAXLEN = 1522
 * ======================================================================= */
.global test_port_init_ext_maxlen
test_port_init_ext_maxlen:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    mov     w1, #1              /* port 1 (external) */
    ldr     x2, =test_mac_addr
    bl      cpsw_port_init

    /* Port 1 base = fake_nu_regs + NU_PORT1_OFFSET (0x2000) */
    ldr     x0, =fake_nu_regs
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_RX_MAXLEN)]
    mov     w2, #PN_MAXLEN_DEFAULT
    cmp     w1, w2
    b.ne    .Lfail_ext_maxlen

    ldr     x0, =name_ext_maxlen
    bl      test_pass
    b       .Ldone_ext_maxlen
.Lfail_ext_maxlen:
    ldr     x0, =name_ext_maxlen
    bl      test_fail
.Ldone_ext_maxlen:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 6: cpsw_port_init external — SA_L/SA_H match MAC
 * ======================================================================= */
.global test_port_init_ext_mac
test_port_init_ext_mac:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    mov     w1, #1
    ldr     x2, =test_mac_addr
    bl      cpsw_port_init

    ldr     x0, =fake_nu_regs

    /* SA_L should be bytes [2:5] of MAC = 0x33445566 */
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_REG_SA_L)]
    ldr     w2, =0x33445566
    cmp     w1, w2
    b.ne    .Lfail_ext_mac

    /* SA_H should be bytes [0:1] of MAC = 0x1122 */
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_REG_SA_H)]
    mov     w2, #0x1122
    cmp     w1, w2
    b.ne    .Lfail_ext_mac

    ldr     x0, =name_ext_mac
    bl      test_pass
    b       .Ldone_ext_mac
.Lfail_ext_mac:
    ldr     x0, =name_ext_mac
    bl      test_fail
.Ldone_ext_mac:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 7: cpsw_macsl_reset success — poll returns non-zero
 * ======================================================================= */
.global test_macsl_reset_success
test_macsl_reset_success:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_nu

    ldr     x19, =cpsw_macsl_poll_reset_fn
    ldr     x20, [x19]

    ldr     x0, =fake_poll_reset_ok
    str     x0, [x19]

    /* MACSL base = fake_nu_regs + NU_PORT1_OFFSET + PN_MACSL_OFFSET */
    ldr     x0, =fake_nu_regs
    add     x0, x0, #NU_PORT1_OFFSET
    add     x0, x0, #PN_MACSL_OFFSET
    bl      cpsw_macsl_reset

    str     x20, [x19]

    cbnz    w0, .Lfail_macsl_ok

    ldr     x0, =name_macsl_reset_ok
    bl      test_pass
    b       .Ldone_macsl_ok
.Lfail_macsl_ok:
    ldr     x0, =name_macsl_reset_ok
    bl      test_fail
.Ldone_macsl_ok:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 8: cpsw_macsl_reset timeout — poll returns 0
 * ======================================================================= */
.global test_macsl_reset_timeout
test_macsl_reset_timeout:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    bl      zero_fake_nu

    ldr     x19, =cpsw_macsl_poll_reset_fn
    ldr     x20, [x19]

    ldr     x0, =fake_poll_reset_timeout
    str     x0, [x19]

    ldr     x0, =fake_nu_regs
    add     x0, x0, #NU_PORT1_OFFSET
    add     x0, x0, #PN_MACSL_OFFSET
    bl      cpsw_macsl_reset

    str     x20, [x19]

    cmp     w0, #1
    b.ne    .Lfail_macsl_timeout

    ldr     x0, =name_macsl_reset_timeout
    bl      test_pass
    b       .Ldone_macsl_timeout
.Lfail_macsl_timeout:
    ldr     x0, =name_macsl_reset_timeout
    bl      test_fail
.Ldone_macsl_timeout:
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

/* =======================================================================
 * Test 9: cpsw_macsl_config 1000 Mbps — CTL = 0xA1
 * ======================================================================= */
.global test_macsl_config_1000
test_macsl_config_1000:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    add     x0, x0, #NU_PORT1_OFFSET
    add     x0, x0, #PN_MACSL_OFFSET
    mov     w1, #SPEED_1000
    bl      cpsw_macsl_config

    ldr     x0, =fake_nu_regs
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_MACSL_OFFSET + MACSL_CTL)]
    cmp     w1, #MACSL_CTL_1000
    b.ne    .Lfail_cfg_1000

    ldr     x0, =name_macsl_cfg_1000
    bl      test_pass
    b       .Ldone_cfg_1000
.Lfail_cfg_1000:
    ldr     x0, =name_macsl_cfg_1000
    bl      test_fail
.Ldone_cfg_1000:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 10: cpsw_macsl_config 100 Mbps — CTL = 0x8021
 * ======================================================================= */
.global test_macsl_config_100
test_macsl_config_100:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    add     x0, x0, #NU_PORT1_OFFSET
    add     x0, x0, #PN_MACSL_OFFSET
    mov     w1, #SPEED_100
    bl      cpsw_macsl_config

    ldr     x0, =fake_nu_regs
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_MACSL_OFFSET + MACSL_CTL)]
    mov     w2, #MACSL_CTL_100
    cmp     w1, w2
    b.ne    .Lfail_cfg_100

    ldr     x0, =name_macsl_cfg_100
    bl      test_pass
    b       .Ldone_cfg_100
.Lfail_cfg_100:
    ldr     x0, =name_macsl_cfg_100
    bl      test_fail
.Ldone_cfg_100:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 11: cpsw_macsl_config 10 Mbps — CTL = 0x21
 * ======================================================================= */
.global test_macsl_config_10
test_macsl_config_10:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    add     x0, x0, #NU_PORT1_OFFSET
    add     x0, x0, #PN_MACSL_OFFSET
    mov     w1, #SPEED_10
    bl      cpsw_macsl_config

    ldr     x0, =fake_nu_regs
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_MACSL_OFFSET + MACSL_CTL)]
    cmp     w1, #MACSL_CTL_10
    b.ne    .Lfail_cfg_10

    ldr     x0, =name_macsl_cfg_10
    bl      test_pass
    b       .Ldone_cfg_10
.Lfail_cfg_10:
    ldr     x0, =name_macsl_cfg_10
    bl      test_fail
.Ldone_cfg_10:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 12: cpsw_macsl_config unknown speed — defaults to 10M (0x21)
 * ======================================================================= */
.global test_macsl_config_unknown
test_macsl_config_unknown:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    add     x0, x0, #NU_PORT1_OFFSET
    add     x0, x0, #PN_MACSL_OFFSET
    mov     w1, #42             /* unknown speed */
    bl      cpsw_macsl_config

    ldr     x0, =fake_nu_regs
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_MACSL_OFFSET + MACSL_CTL)]
    cmp     w1, #MACSL_CTL_10
    b.ne    .Lfail_cfg_unknown

    ldr     x0, =name_macsl_cfg_unknown
    bl      test_pass
    b       .Ldone_cfg_unknown
.Lfail_cfg_unknown:
    ldr     x0, =name_macsl_cfg_unknown
    bl      test_fail
.Ldone_cfg_unknown:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 13: cpsw_ale_init — ALE_CTL = 0xC0000010
 * ======================================================================= */
.global test_ale_init_ctl
test_ale_init_ctl:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_ale

    ldr     x0, =fake_ale_regs
    bl      cpsw_ale_init

    ldr     x0, =fake_ale_regs
    ldr     w1, [x0, #ALE_CTL]
    ldr     w2, =ALE_CTL_BYPASS_VAL
    cmp     w1, w2
    b.ne    .Lfail_ale_ctl

    ldr     x0, =name_ale_ctl
    bl      test_pass
    b       .Ldone_ale_ctl
.Lfail_ale_ctl:
    ldr     x0, =name_ale_ctl
    bl      test_fail
.Ldone_ale_ctl:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 14: cpsw_ale_init — port modes = FORWARD (3)
 * ======================================================================= */
.global test_ale_init_port_modes
test_ale_init_port_modes:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_ale

    ldr     x0, =fake_ale_regs
    bl      cpsw_ale_init

    ldr     x0, =fake_ale_regs

    /* Port 0 */
    ldr     w1, [x0, #ALE_PN_CTL_BASE]
    cmp     w1, #ALE_PN_FORWARD
    b.ne    .Lfail_ale_ports

    /* Port 1 */
    ldr     w1, [x0, #(ALE_PN_CTL_BASE + ALE_PN_CTL_STRIDE)]
    cmp     w1, #ALE_PN_FORWARD
    b.ne    .Lfail_ale_ports

    ldr     x0, =name_ale_ports
    bl      test_pass
    b       .Ldone_ale_ports
.Lfail_ale_ports:
    ldr     x0, =name_ale_ports
    bl      test_fail
.Ldone_ale_ports:
    ldp     x29, x30, [sp], #16
    ret

/* =======================================================================
 * Test 15: MAC address field encoding
 *          MAC 0x11:22:33:44:55:66 → SA_L=0x33445566, SA_H=0x1122
 * ======================================================================= */
.global test_port_init_mac_encoding
test_port_init_mac_encoding:
    stp     x29, x30, [sp, #-16]!
    bl      zero_fake_nu

    ldr     x0, =fake_nu_regs
    mov     w1, #1
    ldr     x2, =test_mac_addr
    bl      cpsw_port_init

    ldr     x0, =fake_nu_regs

    /* Verify SA_L: unaligned load of bytes [2:5] = 0x33445566 */
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_REG_SA_L)]
    ldr     w2, =0x33445566
    cmp     w1, w2
    b.ne    .Lfail_mac_enc

    /* Verify SA_H: bytes [0:1] = 0x1122 */
    ldr     w1, [x0, #(NU_PORT1_OFFSET + PN_REG_SA_H)]
    mov     w2, #0x1122
    cmp     w1, w2
    b.ne    .Lfail_mac_enc

    ldr     x0, =name_mac_enc
    bl      test_pass
    b       .Ldone_mac_enc
.Lfail_mac_enc:
    ldr     x0, =name_mac_enc
    bl      test_fail
.Ldone_mac_enc:
    ldp     x29, x30, [sp], #16
    ret

/* -----------------------------------------------------------------------
 * Fake poll functions
 * ----------------------------------------------------------------------- */

/* MACSL reset cleared — success */
fake_poll_reset_ok:
    mov     w0, #1
    ret

/* MACSL reset timeout */
fake_poll_reset_timeout:
    mov     w0, #0
    ret

/* -----------------------------------------------------------------------
 * Test data
 * ----------------------------------------------------------------------- */
.section .rodata
.balign 2
test_mac_addr: .byte 0x11, 0x22, 0x33, 0x44, 0x55, 0x66

/* -----------------------------------------------------------------------
 * BSS — fake register blocks
 * ----------------------------------------------------------------------- */
.section .bss
.balign 8
fake_nu_regs:
    .space NU_FAKE_SIZE

.balign 8
fake_ale_regs:
    .space ALE_FAKE_SIZE

/* -----------------------------------------------------------------------
 * Test name strings
 * ----------------------------------------------------------------------- */
.section .rodata
name_nu_init_ctl:           .asciz "cpsw_nu_init_ctl"
name_nu_init_stat:          .asciz "cpsw_nu_init_stat_ptype"
name_host_maxlen:           .asciz "cpsw_port_host_maxlen"
name_host_flowid:           .asciz "cpsw_port_host_flowid"
name_ext_maxlen:            .asciz "cpsw_port_ext_maxlen"
name_ext_mac:               .asciz "cpsw_port_ext_mac"
name_macsl_reset_ok:        .asciz "cpsw_macsl_reset"
name_macsl_reset_timeout:   .asciz "cpsw_macsl_reset_timeout"
name_macsl_cfg_1000:        .asciz "cpsw_macsl_config_1000"
name_macsl_cfg_100:         .asciz "cpsw_macsl_config_100"
name_macsl_cfg_10:          .asciz "cpsw_macsl_config_10"
name_macsl_cfg_unknown:     .asciz "cpsw_macsl_config_unknown"
name_ale_ctl:               .asciz "cpsw_ale_init_ctl"
name_ale_ports:             .asciz "cpsw_ale_init_port_modes"
name_mac_enc:               .asciz "cpsw_port_mac_encoding"
