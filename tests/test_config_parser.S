/*
 * test_config_parser.S — smoke tests for lib/config_parser.S (I4).
 *
 * Two cases — exhaustive TSV-driven validation lands as I9.
 *
 *   1. test_config_parse_valid     — minimal valid network.conf →
 *                                     return 0, net_our_ip populated.
 *   2. test_config_parse_bad_magic — wrong magic → return E_MAGIC.
 */

.include "net.inc"

.equ E_MAGIC, 1

.global test_config_parse_valid
.global test_config_parse_bad_magic
.global test_config_parse_eof_midstream
.global test_config_parse_with_mac

.section .text

/* ========================================================================
 * test_config_parse_valid
 * ======================================================================== */
test_config_parse_valid:
    stp     x29, x30, [sp, #-16]!

    /* Use the QEMU compile-time defaults as the parsed values so
     * mutating net_our_ip / net_gw_ip is a no-op for downstream
     * tests (ARP / IP / HTTP tests assume the QEMU defaults).
     * Asserts that the parser DOES write to net_hostname (no
     * default) and the IP/MAC fields match the parsed text. */
    ldr     x0, =_cp_valid_buf
    mov     x1, #_cp_valid_len
    bl      config_parse
    cbnz    w0, .Lcpv_fail

    /* net_our_ip should be 10.0.2.15 (0x0A 0x00 0x02 0x0F). */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    ldrb    w1, [x0, #0]
    cmp     w1, #10
    b.ne    .Lcpv_fail
    ldrb    w1, [x0, #1]
    cmp     w1, #0
    b.ne    .Lcpv_fail
    ldrb    w1, [x0, #2]
    cmp     w1, #2
    b.ne    .Lcpv_fail
    ldrb    w1, [x0, #3]
    cmp     w1, #15
    b.ne    .Lcpv_fail

    /* net_hostname_len should be 4 ("qemu"). */
    adrp    x0, net_hostname_len
    add     x0, x0, :lo12:net_hostname_len
    ldr     w1, [x0]
    cmp     w1, #4
    b.ne    .Lcpv_fail
    /* net_hostname[0..3] should be 'q','e','m','u'. */
    adrp    x0, net_hostname
    add     x0, x0, :lo12:net_hostname
    ldrb    w1, [x0, #0]
    cmp     w1, #'q'
    b.ne    .Lcpv_fail
    ldrb    w1, [x0, #3]
    cmp     w1, #'u'
    b.ne    .Lcpv_fail

    ldr     x0, =_cp_name_valid
    bl      test_pass
    b       .Lcpv_done
.Lcpv_fail:
    ldr     x0, =_cp_name_valid
    bl      test_fail
.Lcpv_done:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_config_parse_bad_magic
 * ======================================================================== */
test_config_parse_bad_magic:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =_cp_bad_magic_buf
    mov     x1, #_cp_bad_magic_len
    bl      config_parse
    cmp     w0, #E_MAGIC
    b.ne    .Lcpb_fail

    ldr     x0, =_cp_name_bad_magic
    bl      test_pass
    b       .Lcpb_done
.Lcpb_fail:
    ldr     x0, =_cp_name_bad_magic
    bl      test_fail
.Lcpb_done:
    ldp     x29, x30, [sp], #16
    ret

/* ========================================================================
 * test_config_parse_with_mac — regression guard for the bug where
 * _validate_mac forgot to save x30 across `bl _hex_nibble`, so the
 * function's own `ret` jumped back into itself (Gemini review,
 * post-I4 commit). Smoke tests with no `mac=` line never reached
 * the bug; this test exercises the full mac=... path.
 * Asserts: parser returns 0 AND net_our_mac contains the parsed
 * bytes.
 * ======================================================================== */
test_config_parse_with_mac:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =_cp_mac_buf
    mov     x1, #_cp_mac_len
    bl      config_parse
    cbnz    w0, .Lcpm_fail

    /* net_our_mac should be 02:00:00:00:00:01 (the QEMU default). */
    adrp    x0, net_our_mac
    add     x0, x0, :lo12:net_our_mac
    ldrb    w1, [x0, #0]
    cmp     w1, #0x02
    b.ne    .Lcpm_fail
    ldrb    w1, [x0, #5]
    cmp     w1, #0x01
    b.ne    .Lcpm_fail

    ldr     x0, =_cp_name_with_mac
    bl      test_pass
    b       .Lcpm_done
.Lcpm_fail:
    ldr     x0, =_cp_name_with_mac
    bl      test_fail
.Lcpm_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_config_parse_eof_midstream — regression guard for an early
 * bug where a NUL or non-ASCII byte mid-buffer (firmware-loaded
 * uninitialized RAM after the actual file content) caused
 * _parse_line to terminate without advancing the outer cursor,
 * spinning forever in config_parse's main loop. The fix in
 * .Lpl_advance forces cursor = limit on EOF-marker byte. This
 * test would HANG without that fix, killing make test.
 * ======================================================================== */
test_config_parse_eof_midstream:
    stp     x29, x30, [sp, #-16]!

    ldr     x0, =_cp_eof_buf
    mov     x1, #_cp_eof_len
    bl      config_parse
    /* Expect E_REQ — the buffer's content is all-comments after the
     * magic, so required keys are missing. The KEY assertion is
     * that this returns AT ALL, not the specific code. */
    cmp     w0, #5                  /* E_REQ */
    b.ne    .Lcpe_fail

    ldr     x0, =_cp_name_eof
    bl      test_pass
    b       .Lcpe_done
.Lcpe_fail:
    ldr     x0, =_cp_name_eof
    bl      test_fail
.Lcpe_done:
    ldp     x29, x30, [sp], #16
    ret


.section .rodata

_cp_name_valid:
    .asciz "config_parse_valid"
_cp_name_bad_magic:
    .asciz "config_parse_bad_magic"
_cp_name_eof:
    .asciz "config_parse_eof_midstream"
_cp_name_with_mac:
    .asciz "config_parse_with_mac"

/* Minimal valid network.conf. Values match QEMU compile-time
 * defaults from lib/net_cfg.S so this test's parse-and-write
 * leaves the rest of the test suite unchanged. */
_cp_valid_buf:
    .ascii "# WSPI5CFG\n"
    .ascii "ip=10.0.2.15\n"
    .ascii "netmask=255.255.255.0\n"
    .ascii "gateway=10.0.2.2\n"
    .ascii "hostname=qemu\n"
.equ _cp_valid_len, (. - _cp_valid_buf)

_cp_bad_magic_buf:
    .ascii "# WSPICFG\n"
    .ascii "ip=10.0.0.2\n"
.equ _cp_bad_magic_len, (. - _cp_bad_magic_buf)

/* Magic line, then a NUL byte where uninitialized RAM would start.
 * Pre-fix (H4 from clean review) this hung config_parse forever;
 * post-fix it terminates cleanly with E_REQ (no required keys
 * present after the magic). */
_cp_eof_buf:
    .ascii "# WSPI5CFG\n"
    .byte 0x00, 0xFF, 0x00, 0xFF
.equ _cp_eof_len, (. - _cp_eof_buf)

/* Valid config with all six keys, including a MAC. ALL values
 * match the QEMU compile-time defaults from lib/net_cfg.S so this
 * test's writes are byte-identical no-ops; downstream ICMP / UDP /
 * IP tests that check against those defaults stay green. */
_cp_mac_buf:
    .ascii "# WSPI5CFG\n"
    .ascii "ip=10.0.2.15\n"
    .ascii "netmask=255.255.255.0\n"
    .ascii "gateway=10.0.2.2\n"
    .ascii "hostname=qemu\n"
    .ascii "mac=02:00:00:00:00:01\n"
.equ _cp_mac_len, (. - _cp_mac_buf)
