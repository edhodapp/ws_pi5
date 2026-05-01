/*
 * lib/config_parser.S — bare-metal network.conf parser.
 *
 * Per D004 / D012 — locked to the Python linter at
 * scripts/lint_network_conf.py via the shared TSV vector file at
 * tests/func/network_conf_vectors.tsv. Any divergence between the
 * two implementations surfaces as a failing parametrized test (I9).
 *
 * Public entry point:
 *
 *   config_parse(x0=start, x1=len)  →  x0 = 0 on success;
 *                                       x0 = error code on failure
 *
 * Caller passes the range [start, start+len) of bytes to parse.
 * The parser does NOT call panic_n directly — the caller (I5
 * main.S) decides whether to halt on a non-zero return.
 *
 * Side effect on success: the appropriate net_cfg labels are
 * populated. Fields not present in the input retain their
 * compile-time defaults (lib/net_cfg.S).
 *
 * Error codes (mirror the linter's, see D012):
 *   1 E_MAGIC, 2 E_LINE, 3 E_KEY, 4 E_DUP, 5 E_REQ,
 *   6 E_IP, 7 E_HOST, 8 E_MAC.
 *
 * Register convention inside config_parse:
 *   x19 — current cursor through the buffer (callee-saved)
 *   x20 — limit ptr (one past last byte; callee-saved)
 *   x21 — seen-keys bitmask (callee-saved)
 *         bit 0 ip, 1 netmask, 2 gateway, 3 hostname,
 *         bit 4 ntp_server, 5 mac
 *   x22 — current key index (0..5) during a single line's
 *         dispatch (callee-saved within _parse_line)
 *
 * All helper subroutines take their input in x0/x1 (start/end of
 * a substring), return status in w0, and clobber only x0..x17 +
 * x30 — they preserve x19..x28. This lets the outer parser keep
 * its state in callee-saved regs without per-call save/restore.
 */

.include "net.inc"

.equ E_MAGIC,   1
.equ E_LINE,    2
.equ E_KEY,     3
.equ E_DUP,     4
.equ E_REQ,     5
.equ E_IP,      6
.equ E_HOST,    7
.equ E_MAC,     8

.equ REQUIRED_MASK, 0x0F        /* bits 0..3 — ip, netmask, gateway, hostname */
.equ HOSTNAME_MAX_LEN, 63

.section .rodata

_magic:
    .ascii "# WSPI5CFG"
.equ _MAGIC_LEN, (. - _magic)

/* Known keys, packed as (length-byte, ascii bytes) entries.
 * Trailing entry has length 0 to terminate the scan. The order
 * fixes the key index used by the seen-bitmask and dispatch:
 * 0 = ip, 1 = netmask, 2 = gateway, 3 = hostname,
 * 4 = ntp_server, 5 = mac. */
_keys:
    .byte 2;  .ascii "ip"
    .byte 7;  .ascii "netmask"
    .byte 7;  .ascii "gateway"
    .byte 8;  .ascii "hostname"
    .byte 10; .ascii "ntp_server"
    .byte 3;  .ascii "mac"
    .byte 0
_keys_end:

.section .text

.global config_parse

config_parse:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                 /* cursor */
    add     x20, x0, x1             /* limit  */
    mov     x21, #0                 /* seen mask */

    bl      _check_magic
    cbnz    w0, .Lcp_done

.Lcp_loop:
    cmp     x19, x20
    b.hs    .Lcp_finish
    bl      _parse_line
    cbnz    w0, .Lcp_done
    b       .Lcp_loop

.Lcp_finish:
    and     w0, w21, #REQUIRED_MASK
    cmp     w0, #REQUIRED_MASK
    b.eq    .Lcp_ok
    mov     w0, #E_REQ
    b       .Lcp_done

.Lcp_ok:
    mov     w0, #0
.Lcp_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


/* ---------------------------------------------------------------------------
 * _check_magic — find the first non-empty line; verify it's
 * "# WSPI5CFG" (after stripping a whitespace-prefixed inline
 * comment and trailing whitespace, including \r for CRLF).
 *
 * On success advances x19 past the magic line's newline (if any).
 * On failure returns w0 = E_MAGIC and leaves x19 unspecified.
 * --------------------------------------------------------------------------- */
_check_magic:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

.Lcm_next_line:
    cmp     x19, x20
    b.hs    .Lcm_fail               /* hit EOF before any magic */

    /* Find this line's natural end: '\n' or limit or EOF marker. */
    mov     x9, x19                 /* line_start */
    mov     x10, x19                /* scan cursor */
.Lcm_scan:
    cmp     x10, x20
    b.hs    .Lcm_have_end
    ldrb    w11, [x10]
    cmp     w11, #'\n'
    b.eq    .Lcm_have_end
    cbz     w11, .Lcm_have_end      /* NUL = EOF */
    cmp     w11, #0x7E
    b.hi    .Lcm_have_end           /* non-ASCII = EOF marker */
    add     x10, x10, #1
    b       .Lcm_scan
.Lcm_have_end:
    mov     x12, x10                /* line_end (excl. newline) */

    /* Strip the magic-line trailing inline comment: scan from
     * line_start+1 forward for a whitespace-prefixed '#'. */
    cmp     x9, x12
    b.hs    .Lcm_no_inline
    add     x13, x9, #1
.Lcm_inline:
    cmp     x13, x12
    b.hs    .Lcm_no_inline
    ldrb    w11, [x13]
    cmp     w11, #'#'
    b.ne    .Lcm_inline_step
    sub     x14, x13, #1
    ldrb    w15, [x14]
    cmp     w15, #' '
    b.eq    .Lcm_inline_cut
    cmp     w15, #'\t'
    b.eq    .Lcm_inline_cut
    cmp     w15, #'\r'
    b.eq    .Lcm_inline_cut
.Lcm_inline_step:
    add     x13, x13, #1
    b       .Lcm_inline
.Lcm_inline_cut:
    mov     x12, x13

.Lcm_no_inline:
    /* Trim trailing whitespace from [x9, x12). */
.Lcm_trim_trail:
    cmp     x9, x12
    b.hs    .Lcm_trim_lead
    sub     x14, x12, #1
    ldrb    w11, [x14]
    cmp     w11, #' '
    b.eq    .Lcm_trim_trail_step
    cmp     w11, #'\t'
    b.eq    .Lcm_trim_trail_step
    cmp     w11, #'\r'
    b.eq    .Lcm_trim_trail_step
    b       .Lcm_trim_lead
.Lcm_trim_trail_step:
    mov     x12, x14
    b       .Lcm_trim_trail

.Lcm_trim_lead:
    /* Trim leading whitespace from [x9, x12). */
    cmp     x9, x12
    b.hs    .Lcm_blank
    ldrb    w11, [x9]
    cmp     w11, #' '
    b.eq    .Lcm_trim_lead_step
    cmp     w11, #'\t'
    b.eq    .Lcm_trim_lead_step
    cmp     w11, #'\r'
    b.eq    .Lcm_trim_lead_step
    b       .Lcm_compare
.Lcm_trim_lead_step:
    add     x9, x9, #1
    b       .Lcm_trim_lead

.Lcm_blank:
    /* Stripped line is empty — advance past the newline (or EOF
     * byte) and try again. */
    mov     x19, x10
    cmp     x19, x20
    b.hs    .Lcm_fail
    ldrb    w11, [x19]
    cbz     w11, .Lcm_fail          /* hit NUL EOF */
    cmp     w11, #0x7E
    b.hi    .Lcm_fail               /* hit non-ASCII EOF */
    /* Otherwise it's '\n' — skip and continue. */
    add     x19, x19, #1
    b       .Lcm_next_line

.Lcm_compare:
    sub     x11, x12, x9
    cmp     x11, #_MAGIC_LEN
    b.ne    .Lcm_fail
    mov     x0, x9
    adrp    x1, _magic
    add     x1, x1, :lo12:_magic
    mov     x2, #_MAGIC_LEN
    bl      _memcmp
    cbnz    w0, .Lcm_fail

    /* Magic matched. Advance x19 past the line's newline if any. */
    mov     x19, x10
    cmp     x19, x20
    b.hs    .Lcm_ok
    ldrb    w11, [x19]
    cmp     w11, #'\n'
    b.ne    .Lcm_ok                 /* could be EOF marker — leave cursor */
    add     x19, x19, #1
.Lcm_ok:
    mov     w0, #0
    b       .Lcm_return
.Lcm_fail:
    mov     w0, #E_MAGIC
.Lcm_return:
    ldp     x29, x30, [sp], #16
    ret


/* ---------------------------------------------------------------------------
 * _parse_line — parse one line starting at x19. On success or
 * skip-empty advances x19 past the line's newline and returns
 * w0 = 0. On rejection returns the error code in w0; cursor is
 * unspecified.
 * --------------------------------------------------------------------------- */
/* Register usage inside _parse_line:
 *   x22  key index (callee-saved across helper calls)
 *   x23  newline position (for advancing x19 at end; survives bl)
 *   x24  val_start (survives _validate_*)
 *   x25  val_end   (survives _validate_*)
 *   x9..x17  scratch — clobbered by bl, never read after bl
 */
_parse_line:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x22, x23, [sp, #16]
    stp     x24, x25, [sp, #32]

    mov     x9, x19                 /* line_start */
    mov     x23, x19                /* scan cursor → ends as newline pos */
.Lpl_scan:
    cmp     x23, x20
    b.hs    .Lpl_have_end
    ldrb    w11, [x23]
    cmp     w11, #'\n'
    b.eq    .Lpl_have_end
    cbz     w11, .Lpl_have_end
    cmp     w11, #0x7E
    b.hi    .Lpl_have_end
    add     x23, x23, #1
    b       .Lpl_scan
.Lpl_have_end:
    mov     x12, x23                /* line_end (excl. newline) */

    /* Inline comment: shell-style — '#' at line start or
     * preceded by whitespace truncates here. */
    mov     x13, x9
.Lpl_inline:
    cmp     x13, x12
    b.hs    .Lpl_no_inline
    ldrb    w11, [x13]
    cmp     w11, #'#'
    b.ne    .Lpl_inline_step
    cmp     x13, x9
    b.eq    .Lpl_inline_cut
    sub     x14, x13, #1
    ldrb    w15, [x14]
    cmp     w15, #' '
    b.eq    .Lpl_inline_cut
    cmp     w15, #'\t'
    b.eq    .Lpl_inline_cut
    cmp     w15, #'\r'
    b.eq    .Lpl_inline_cut
.Lpl_inline_step:
    add     x13, x13, #1
    b       .Lpl_inline
.Lpl_inline_cut:
    mov     x12, x13

.Lpl_no_inline:
    /* Trim trailing whitespace from [x9, x12). */
.Lpl_trim_trail:
    cmp     x9, x12
    b.hs    .Lpl_trim_lead
    sub     x14, x12, #1
    ldrb    w11, [x14]
    cmp     w11, #' '
    b.eq    .Lpl_trim_trail_step
    cmp     w11, #'\t'
    b.eq    .Lpl_trim_trail_step
    cmp     w11, #'\r'
    b.eq    .Lpl_trim_trail_step
    b       .Lpl_trim_lead
.Lpl_trim_trail_step:
    mov     x12, x14
    b       .Lpl_trim_trail

.Lpl_trim_lead:
    cmp     x9, x12
    b.hs    .Lpl_blank
    ldrb    w11, [x9]
    cmp     w11, #' '
    b.eq    .Lpl_trim_lead_step
    cmp     w11, #'\t'
    b.eq    .Lpl_trim_lead_step
    cmp     w11, #'\r'
    b.eq    .Lpl_trim_lead_step
    b       .Lpl_find_eq
.Lpl_trim_lead_step:
    add     x9, x9, #1
    b       .Lpl_trim_lead

.Lpl_blank:
    /* Empty line — advance and return success. */
    mov     w0, #0
    b       .Lpl_advance

.Lpl_find_eq:
    /* Scan [x9, x12) for '='. */
    mov     x13, x9
.Lpl_eq_scan:
    cmp     x13, x12
    b.hs    .Lpl_no_eq
    ldrb    w11, [x13]
    cmp     w11, #'='
    b.eq    .Lpl_have_eq
    add     x13, x13, #1
    b       .Lpl_eq_scan

.Lpl_no_eq:
    mov     w0, #E_LINE
    b       .Lpl_return

.Lpl_have_eq:
    /* x9 = key_start, x13 = '=' position, x12 = line_end. */
    mov     x14, x9                 /* key_start (working) */
    mov     x15, x13                /* key_end (working) */
    /* Strip key trailing whitespace. */
.Lpl_key_trim_trail:
    cmp     x14, x15
    b.hs    .Lpl_key_trim_lead
    sub     x16, x15, #1
    ldrb    w11, [x16]
    cmp     w11, #' '
    b.eq    .Lpl_key_trim_trail_step
    cmp     w11, #'\t'
    b.eq    .Lpl_key_trim_trail_step
    b       .Lpl_key_trim_lead
.Lpl_key_trim_trail_step:
    mov     x15, x16
    b       .Lpl_key_trim_trail
.Lpl_key_trim_lead:
    cmp     x14, x15
    b.hs    .Lpl_lookup_key
    ldrb    w11, [x14]
    cmp     w11, #' '
    b.eq    .Lpl_key_trim_lead_step
    cmp     w11, #'\t'
    b.eq    .Lpl_key_trim_lead_step
    b       .Lpl_lookup_key
.Lpl_key_trim_lead_step:
    add     x14, x14, #1
    b       .Lpl_key_trim_lead

.Lpl_lookup_key:
    /* x14 = key_start (stripped), x15 = key_end (stripped).
     * Need x12 (line_end) and x13 ('=' position) to survive the
     * call. Stash on the stack — _lookup_key clobbers x9..x10. */
    mov     x0, x14
    mov     x1, x15
    stp     x12, x13, [sp, #-16]!
    bl      _lookup_key
    ldp     x12, x13, [sp], #16
    cmn     w0, #1
    b.ne    .Lpl_have_key
    mov     w0, #E_KEY
    b       .Lpl_return

.Lpl_have_key:
    /* Key index → x22 (callee-saved, used by dispatch + _store_ip). */
    mov     w22, w0

    /* Duplicate check via seen mask. */
    mov     w11, #1
    lsl     w11, w11, w22
    tst     w21, w11
    b.eq    .Lpl_not_dup
    mov     w0, #E_DUP
    b       .Lpl_return
.Lpl_not_dup:
    orr     w21, w21, w11

    /* Compute value bounds. val_start = '=' + 1 then strip leading
     * WS; val_end = line_end then strip trailing WS. Park them in
     * x24/x25 (callee-saved) so the validator/storer calls can't
     * lose them. */
    add     x24, x13, #1            /* val_start */
    mov     x25, x12                /* val_end (working copy) */
.Lpl_val_trim_trail:
    cmp     x24, x25
    b.hs    .Lpl_val_trim_lead
    sub     x17, x25, #1
    ldrb    w11, [x17]
    cmp     w11, #' '
    b.eq    .Lpl_val_trim_trail_step
    cmp     w11, #'\t'
    b.eq    .Lpl_val_trim_trail_step
    b       .Lpl_val_trim_lead
.Lpl_val_trim_trail_step:
    mov     x25, x17
    b       .Lpl_val_trim_trail
.Lpl_val_trim_lead:
    cmp     x24, x25
    b.hs    .Lpl_dispatch
    ldrb    w11, [x24]
    cmp     w11, #' '
    b.eq    .Lpl_val_trim_lead_step
    cmp     w11, #'\t'
    b.eq    .Lpl_val_trim_lead_step
    b       .Lpl_dispatch
.Lpl_val_trim_lead_step:
    add     x24, x24, #1
    b       .Lpl_val_trim_lead

.Lpl_dispatch:
    /* Dispatch on key index. 0/1/2/4 → IP; 3 → hostname; 5 → MAC. */
    mov     x0, x24                 /* val_start */
    mov     x1, x25                 /* val_end */
    cmp     w22, #3
    b.eq    .Lpl_do_hostname
    cmp     w22, #5
    b.eq    .Lpl_do_mac
    /* Else IP. */
    bl      _validate_ip            /* w0 = 0 or E_IP; w1..w4 = octets */
    cbnz    w0, .Lpl_return
    bl      _store_ip               /* uses w22 to pick destination */
    mov     w0, #0
    b       .Lpl_advance

.Lpl_do_hostname:
    bl      _validate_hostname      /* w0 = 0 or E_HOST */
    cbnz    w0, .Lpl_return
    mov     x0, x24
    mov     x1, x25
    bl      _store_hostname
    mov     w0, #0
    b       .Lpl_advance

.Lpl_do_mac:
    bl      _validate_mac           /* w0 = 0 or E_MAC; w1..w6 = bytes */
    cbnz    w0, .Lpl_return
    bl      _store_mac
    mov     w0, #0
    b       .Lpl_advance

.Lpl_advance:
    /* Advance x19 to one past the newline. x23 holds the position
     * the scan stopped at (newline OR EOF marker OR limit). It's
     * callee-saved so survives all bl calls above.
     *
     * If we stopped at a real '\n', advance past it.
     * If we stopped at an EOF marker (NUL or byte > 0x7E), force
     * x19 = x20 so the outer config_parse loop terminates cleanly.
     * Without that fast-forward, the outer loop sees x19 < x20,
     * re-enters _parse_line, the scan stops on the same marker,
     * yields an empty line that "succeeds", and we infinite-loop
     * on the same byte. */
    mov     x19, x23
    cmp     x19, x20
    b.hs    .Lpl_return
    ldrb    w11, [x19]
    cmp     w11, #'\n'
    b.eq    .Lpl_advance_nl
    /* Anything else at x23 is an EOF marker (NUL or > 0x7E by the
     * scan's loop conditions). Terminate the outer loop. */
    mov     x19, x20
    b       .Lpl_return
.Lpl_advance_nl:
    add     x19, x19, #1
.Lpl_return:
    ldp     x24, x25, [sp, #32]
    ldp     x22, x23, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


/* ---------------------------------------------------------------------------
 * _lookup_key — match [x0, x1) against the _keys table.
 * Returns w0 = key index 0..5 on match, -1 on no match.
 * Preserves x19+. --------------------------------------------------------- */
_lookup_key:
    sub     x2, x1, x0              /* needle length */
    adrp    x3, _keys
    add     x3, x3, :lo12:_keys
    mov     w4, #0                  /* index */
.Llk_next:
    ldrb    w5, [x3]
    cbz     w5, .Llk_no_match
    cmp     w5, w2
    b.ne    .Llk_skip
    /* Compare bytes. */
    add     x6, x3, #1
    mov     x7, x0
    mov     w8, w2
.Llk_cmp:
    ldrb    w9, [x6], #1
    ldrb    w10, [x7], #1
    cmp     w9, w10
    b.ne    .Llk_skip
    subs    w8, w8, #1
    b.ne    .Llk_cmp
    mov     w0, w4
    ret
.Llk_skip:
    add     x3, x3, #1
    add     x3, x3, x5
    add     w4, w4, #1
    b       .Llk_next
.Llk_no_match:
    mov     w0, #-1
    ret


/* ---------------------------------------------------------------------------
 * _validate_ip — parse [x0, x1) as IPv4 dotted-decimal.
 * Returns w0 = 0 with octets in w1..w4, or w0 = E_IP.
 * Preserves x19+.
 *
 * Rules: ASCII digits only; reject leading-zero octets ("010" bad,
 * "0" ok); each octet 0..255; exactly four octets.
 * --------------------------------------------------------------------------- */
_validate_ip:
    mov     x9, x0                  /* cursor */
    mov     x10, x1                 /* limit */
    mov     w11, #0                 /* octet index */

.Lvi_octet:
    cmp     w11, #4
    b.hs    .Lvi_bad
    mov     w12, #0                 /* octet value */
    mov     w13, #0                 /* digit count */

.Lvi_digit:
    cmp     x9, x10
    b.hs    .Lvi_octet_done
    ldrb    w14, [x9]
    cmp     w14, #'.'
    b.eq    .Lvi_octet_done
    cmp     w14, #'0'
    b.lo    .Lvi_bad
    cmp     w14, #'9'
    b.hi    .Lvi_bad
    /* Leading-zero rejection: if w13 > 0 and the FIRST digit was '0'
     * (i.e. octet value is currently 0), reject — anything beyond a
     * single "0" is "010"-style. */
    cbnz    w13, .Lvi_check_lead
    b       .Lvi_accumulate
.Lvi_check_lead:
    cbz     w12, .Lvi_bad
.Lvi_accumulate:
    sub     w14, w14, #'0'
    mov     w15, #10
    madd    w12, w12, w15, w14
    cmp     w12, #255
    b.hi    .Lvi_bad
    add     w13, w13, #1
    add     x9, x9, #1
    b       .Lvi_digit

.Lvi_octet_done:
    cbz     w13, .Lvi_bad           /* zero digits = bad (e.g. "10..0.1") */
    /* Store octet into w1..w4 by index. */
    cmp     w11, #0
    b.ne    1f
    mov     w1, w12
    b       .Lvi_octet_advance
1:  cmp     w11, #1
    b.ne    2f
    mov     w2, w12
    b       .Lvi_octet_advance
2:  cmp     w11, #2
    b.ne    3f
    mov     w3, w12
    b       .Lvi_octet_advance
3:  mov     w4, w12
.Lvi_octet_advance:
    add     w11, w11, #1
    cmp     x9, x10
    b.hs    .Lvi_check_count
    /* Skip the '.'. */
    add     x9, x9, #1
    b       .Lvi_octet
.Lvi_check_count:
    cmp     w11, #4
    b.ne    .Lvi_bad
    mov     w0, #0
    ret

.Lvi_bad:
    mov     w0, #E_IP
    ret


/* ---------------------------------------------------------------------------
 * _store_ip — write the four octets w1..w4 to the right net_cfg
 * label per current key index in w22. */
_store_ip:
    cmp     w22, #0
    b.ne    1f
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    b       .Lsi_write
1:  cmp     w22, #1
    b.ne    2f
    adrp    x0, net_netmask
    add     x0, x0, :lo12:net_netmask
    b       .Lsi_write
2:  cmp     w22, #2
    b.ne    3f
    adrp    x0, net_gw_ip
    add     x0, x0, :lo12:net_gw_ip
    b       .Lsi_write
3:  /* w22 == 4: ntp_server */
    adrp    x0, net_ntp_ip
    add     x0, x0, :lo12:net_ntp_ip
.Lsi_write:
    strb    w1, [x0, #0]
    strb    w2, [x0, #1]
    strb    w3, [x0, #2]
    strb    w4, [x0, #3]
    ret


/* ---------------------------------------------------------------------------
 * _validate_hostname — verify [x0, x1) per RFC 1123 LDH:
 *   1..63 chars; first AND last letter-or-digit; interior LDH.
 * Returns w0 = 0 or E_HOST. Preserves x19+. */
_validate_hostname:
    sub     x2, x1, x0              /* length */
    cbz     x2, .Lvh_bad
    cmp     x2, #HOSTNAME_MAX_LEN
    b.hi    .Lvh_bad

    /* First char letter-or-digit. */
    ldrb    w3, [x0]
    cmp     w3, #'0'
    b.lo    .Lvh_bad
    cmp     w3, #'9'
    b.ls    .Lvh_first_ok
    cmp     w3, #'A'
    b.lo    .Lvh_bad
    cmp     w3, #'Z'
    b.ls    .Lvh_first_ok
    cmp     w3, #'a'
    b.lo    .Lvh_bad
    cmp     w3, #'z'
    b.hi    .Lvh_bad
.Lvh_first_ok:

    /* Last char letter-or-digit. */
    sub     x4, x1, #1
    ldrb    w3, [x4]
    cmp     w3, #'0'
    b.lo    .Lvh_bad
    cmp     w3, #'9'
    b.ls    .Lvh_last_ok
    cmp     w3, #'A'
    b.lo    .Lvh_bad
    cmp     w3, #'Z'
    b.ls    .Lvh_last_ok
    cmp     w3, #'a'
    b.lo    .Lvh_bad
    cmp     w3, #'z'
    b.hi    .Lvh_bad
.Lvh_last_ok:

    /* Interior: every char must be LDH (letter / digit / hyphen). */
    mov     x5, x0
.Lvh_scan:
    cmp     x5, x1
    b.hs    .Lvh_ok
    ldrb    w3, [x5]
    cmp     w3, #'-'
    b.eq    .Lvh_step
    cmp     w3, #'0'
    b.lo    .Lvh_bad
    cmp     w3, #'9'
    b.ls    .Lvh_step
    cmp     w3, #'A'
    b.lo    .Lvh_bad
    cmp     w3, #'Z'
    b.ls    .Lvh_step
    cmp     w3, #'a'
    b.lo    .Lvh_bad
    cmp     w3, #'z'
    b.hi    .Lvh_bad
.Lvh_step:
    add     x5, x5, #1
    b       .Lvh_scan

.Lvh_ok:
    mov     w0, #0
    ret
.Lvh_bad:
    mov     w0, #E_HOST
    ret


/* ---------------------------------------------------------------------------
 * _store_hostname — copy [x0, x1) into net_hostname; set
 * net_hostname_len. Caller has verified length ≤ 63 via
 * _validate_hostname. Zeroes the 64-byte buffer first so trailing
 * bytes from a prior config don't leak. */
_store_hostname:
    sub     x2, x1, x0              /* length */
    adrp    x3, net_hostname
    add     x3, x3, :lo12:net_hostname
    /* Zero 64 bytes of buffer (8x stp xzr at 8-byte alignment). */
    stp     xzr, xzr, [x3, #0]
    stp     xzr, xzr, [x3, #16]
    stp     xzr, xzr, [x3, #32]
    stp     xzr, xzr, [x3, #48]
    /* Copy bytes. */
    mov     x4, x0
    mov     x5, x3
    mov     x6, x2
.Lsh_copy:
    cbz     x6, .Lsh_done
    ldrb    w7, [x4], #1
    strb    w7, [x5], #1
    sub     x6, x6, #1
    b       .Lsh_copy
.Lsh_done:
    adrp    x3, net_hostname_len
    add     x3, x3, :lo12:net_hostname_len
    str     w2, [x3]
    ret


/* ---------------------------------------------------------------------------
 * _validate_mac — parse [x0, x1) as six colon-separated 2-digit
 * hex bytes (e.g. "de:ad:be:ef:ca:fe"). Case-insensitive.
 * Returns w0 = 0 with bytes in w1..w6, or w0 = E_MAC. */
_validate_mac:
    /* x30 must be saved across the `bl _hex_nibble` calls below —
     * without this prologue, `bl` would overwrite x30 with an
     * internal return address and our own `ret` would jump back
     * inside this function (infinite loop). */
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     x2, x1, x0
    cmp     x2, #17                 /* exact length: 6*2 + 5 colons */
    b.ne    .Lvm_bad
    mov     x9, x0
    mov     w10, #0                 /* byte index */

.Lvm_byte:
    /* High nibble. */
    ldrb    w11, [x9]
    bl      _hex_nibble
    cmn     w0, #1
    b.eq    .Lvm_bad
    mov     w12, w0
    add     x9, x9, #1
    /* Low nibble. */
    ldrb    w11, [x9]
    bl      _hex_nibble
    cmn     w0, #1
    b.eq    .Lvm_bad
    add     x9, x9, #1
    lsl     w12, w12, #4
    orr     w13, w12, w0
    /* Store byte to wN. */
    cmp     w10, #0
    b.ne    1f
    mov     w1, w13
    b       .Lvm_after_store
1:  cmp     w10, #1
    b.ne    2f
    mov     w2, w13
    b       .Lvm_after_store
2:  cmp     w10, #2
    b.ne    3f
    mov     w3, w13
    b       .Lvm_after_store
3:  cmp     w10, #3
    b.ne    4f
    mov     w4, w13
    b       .Lvm_after_store
4:  cmp     w10, #4
    b.ne    5f
    mov     w5, w13
    b       .Lvm_after_store
5:  mov     w6, w13
.Lvm_after_store:
    add     w10, w10, #1
    cmp     w10, #6
    b.eq    .Lvm_ok
    /* Expect ':' between bytes. */
    ldrb    w11, [x9]
    cmp     w11, #':'
    b.ne    .Lvm_bad
    add     x9, x9, #1
    b       .Lvm_byte

.Lvm_ok:
    mov     w0, #0
    ldp     x29, x30, [sp], #16
    ret
.Lvm_bad:
    mov     w0, #E_MAC
    ldp     x29, x30, [sp], #16
    ret


/* ---------------------------------------------------------------------------
 * _hex_nibble — w11 is a byte. Returns w0 = 0..15 if hex digit,
 * w0 = -1 otherwise. */
_hex_nibble:
    cmp     w11, #'0'
    b.lo    .Lhn_no
    cmp     w11, #'9'
    b.hi    .Lhn_alpha
    sub     w0, w11, #'0'
    ret
.Lhn_alpha:
    cmp     w11, #'A'
    b.lo    .Lhn_no
    cmp     w11, #'F'
    b.hi    .Lhn_lower
    sub     w0, w11, #('A' - 10)
    ret
.Lhn_lower:
    cmp     w11, #'a'
    b.lo    .Lhn_no
    cmp     w11, #'f'
    b.hi    .Lhn_no
    sub     w0, w11, #('a' - 10)
    ret
.Lhn_no:
    mov     w0, #-1
    ret


/* ---------------------------------------------------------------------------
 * _store_mac — write w1..w6 to net_our_mac. */
_store_mac:
    adrp    x0, net_our_mac
    add     x0, x0, :lo12:net_our_mac
    strb    w1, [x0, #0]
    strb    w2, [x0, #1]
    strb    w3, [x0, #2]
    strb    w4, [x0, #3]
    strb    w5, [x0, #4]
    strb    w6, [x0, #5]
    ret


/* ---------------------------------------------------------------------------
 * _memcmp — compare x0..x0+x2 against x1..x1+x2.
 * Returns w0 = 0 if equal, non-zero otherwise. */
_memcmp:
    cbz     x2, .Lmc_eq
.Lmc_loop:
    ldrb    w3, [x0], #1
    ldrb    w4, [x1], #1
    cmp     w3, w4
    b.ne    .Lmc_neq
    sub     x2, x2, #1
    cbnz    x2, .Lmc_loop
.Lmc_eq:
    mov     w0, #0
    ret
.Lmc_neq:
    mov     w0, #1
    ret
