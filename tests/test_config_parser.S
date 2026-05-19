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
.global test_config_parse_mathpages_trailing_garbage

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


/* ========================================================================
 * test_config_parse_mathpages_trailing_garbage
 *
 * Repro for the 2026-05-18 home-install regression. The kernel reads
 * 4 KiB from INITRAMFS_ADDR (0x20000000) per main.S:
 *     ldr     x0, =INITRAMFS_ADDR
 *     mov     w1, #4096
 *     bl      config_parse
 *
 * The firmware loads network.conf into that physical address but
 * does NOT zero-pad the remainder. Real-world network.conf files
 * are under 2 KiB (Ed's was 1731 B), so the trailing ~2.3 KiB of
 * the 4 KiB buffer is whatever the DRAM cell happened to hold
 * before firmware wrote the file — could be zeros on a fresh DRAM
 * init, could be uninitialized garbage on a warm boot, could be
 * leftover kernel state if a watchdog reset just fired.
 *
 * This test simulates the worst case: a complete, valid config
 * (the exact `dhcp=yes` + `hostname=mathpages` shape Ed flashed
 * to the 1 GB Pi 4) followed by trailing bytes that resemble
 * another key=value line. If config_parse scans the whole buffer
 * without bounded EOF detection, it processes the trailing
 * pseudo-line, hits an unknown key, and returns E_KEY — which
 * the kernel turns into a panic_n (Morse "N") at .Lcfg_fail in
 * main.S. That's the failure mode Ed observed in the field: a
 * valid file on disk, accepted by the Python linter (which reads
 * a file, not a buffer), rejected by the asm parser (which reads
 * a fixed-size buffer that includes trailing RAM contents).
 *
 * Expected: rc = 0 (parser stops at the file's last meaningful
 * byte and ignores trailing garbage, matching the contract the
 * Python linter implements).
 *
 * Pre-fix this test FAILS, demonstrating the regression. Post-fix
 * (e.g., config_parser stops at the first NUL byte, or main.S
 * passes the actual file length from the DTB initrd-end property)
 * this test passes.
 * ======================================================================== */
test_config_parse_mathpages_trailing_garbage:
    stp     x29, x30, [sp, #-16]!

    /* Drive config_parse against the 4 KiB buffer (file content
     * followed by trailing pseudo-line garbage — see rodata below). */
    ldr     x0, =_cp_mathpages_buf
    mov     w1, #_cp_mathpages_len
    bl      config_parse
    cbnz    w0, .Lcpt_fail

    ldr     x0, =_cp_name_mathpages
    bl      test_pass
    b       .Lcpt_done
.Lcpt_fail:
    ldr     x0, =_cp_name_mathpages
    bl      test_fail
.Lcpt_done:
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
_cp_name_mathpages:
    .asciz "config_parse_mathpages_trailing_garbage"

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

/* 4 KiB buffer mirroring the runtime layout main.S hands to
 * config_parse: file content at the start (Ed's `dhcp=yes` +
 * `hostname=mathpages` shape — the exact config that triggered
 * panic_n on the 1 GB Pi 4 during the 2026-05-18 home-network
 * test), then a pseudo-config-line IMMEDIATELY after (no NUL
 * separator), then zeros to 4 KiB.
 *
 * Why no NUL separator: the existing H4 fix in config_parser.S
 * stops on the first NUL byte, which handles the common
 * "firmware zero-pads after file" case (covered by
 * test_config_parse_eof_midstream above). But firmware doesn't
 * always zero-pad — Raspberry Pi firmware in particular just
 * dd's the file into the load address without touching the
 * bytes past file_size. On a cold boot DRAM is typically zeros,
 * but on warm boots (watchdog resets, prior kernel runs) the
 * trailing bytes are whatever was in RAM. If they happen to
 * form `\n<word>=<word>\n` (random chance given ASCII-range
 * uninitialized bytes), the parser treats it as another config
 * line and returns an error code — kernel turns that into
 * panic_n in the field.
 *
 * The bait line "\nfoo=bar\n" placed RIGHT after the last \n of
 * the file content provokes E_KEY (unknown key "foo"). If the
 * parser stops at file_end (e.g., via a real DTB-supplied
 * initrd-end, or by detecting NUL as a sentinel before consuming
 * non-NUL trailing bytes), this test passes. If it scans the
 * whole 4 KiB buffer in fixed-length mode (current behavior),
 * it processes the bait line and returns E_KEY → test fails. */
.balign 16
_cp_mathpages_buf:
    .ascii "# WSPI5CFG\n"               /* 11 bytes */
    .ascii "dhcp=yes\n"                 /*  9 bytes */
    .ascii "hostname=mathpages\n"       /* 19 bytes — total 39 */
    .ascii "\nfoo=bar\n"                /*  9 bytes — pseudo-line bait,
                                         * NO NUL separator before */
    .space (4096 - 39 - 9), 0x00        /* fill to exactly 4 KiB */
.equ _cp_mathpages_len, 4096
