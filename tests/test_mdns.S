/*
 * test_mdns.S — smoke tests for lib/mdns.S (I15, first commit).
 *
 * Three cases:
 *   1. test_mdns_a_query_match     — A query for "wspi5.local" (or
 *                                     whatever net_hostname holds)
 *                                     → returns response, header
 *                                     flags = 0x8400, ancount = 1.
 *   2. test_mdns_a_query_no_match  — A query for a different name
 *                                     → returns 0.
 *   3. test_mdns_aaaa_query_drop   — AAAA query (type 28) → returns
 *                                     0 even for our hostname (we
 *                                     are IPv4-only per D008).
 *
 * Each test sets up net_hostname / net_hostname_len / net_our_ip
 * to known values, calls mdns_build_response, asserts on the
 * returned length and key bytes of the response. Saves and
 * restores those globals so downstream tests stay green.
 */

.include "net.inc"

.global test_mdns_a_query_match
.global test_mdns_a_query_no_match
.global test_mdns_aaaa_query_drop
.global test_mdns_dispatch_a_match
.global test_mdns_dispatch_no_reply
.global test_mdns_net_recv_e2e
.global test_mdns_build_probe
.global test_mdns_build_probe_frame
.global test_mdns_build_probe_frame_empty
.global test_mdns_conflict_match
.global test_mdns_conflict_other_name
.global test_mdns_conflict_query_qr0
.global test_mdns_conflict_no_answer
.global test_mdns_conflict_short
.global test_mdns_conflict_compressed_name
.global test_mdns_conflict_with_question
.global test_mdns_build_announce
.global test_mdns_build_announce_frame
.global test_mdns_build_announce_empty
.global test_mdns_state_initial
.global test_mdns_state_advance_one
.global test_mdns_state_full_sequence
.global test_mdns_state_first_send_is_probe
.global test_mdns_state_fourth_send_is_announce
.global test_mdns_state_live_noop
.global test_mdns_dispatch_drops_in_probe
.global test_mdns_dispatch_responds_in_announce
.global test_mdns_dispatch_panics_on_conflict

.section .text

/* Set net_hostname to "qemu" / len 4 / net_our_ip to 10.0.2.15.
 * Caller must have already saved these via _mdns_test_save. Also
 * defaults the mDNS state machine to LIVE so dispatch tests that
 * pre-date the 9/N state-gating still see "respond normally"
 * behavior; tests that exercise probe-phase gating must overwrite
 * mdns_send_ctx.state after this call. */
_mdns_test_set_state:
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    mov     w1, #6                      /* MDNS_STATE_LIVE */
    str     w1, [x0, #48]               /* MDNSC_STATE offset */

    adrp    x0, net_hostname
    add     x0, x0, :lo12:net_hostname
    /* Zero 64 bytes via two stp xzr,xzr per 16. */
    stp     xzr, xzr, [x0, #0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]
    stp     xzr, xzr, [x0, #48]
    /* Write 'q','e','m','u'. */
    mov     w1, #'q'
    strb    w1, [x0, #0]
    mov     w1, #'e'
    strb    w1, [x0, #1]
    mov     w1, #'m'
    strb    w1, [x0, #2]
    mov     w1, #'u'
    strb    w1, [x0, #3]
    /* len = 4. */
    adrp    x0, net_hostname_len
    add     x0, x0, :lo12:net_hostname_len
    mov     w1, #4
    str     w1, [x0]
    /* IP = 10.0.2.15 = 0x0F02000A on little-endian-stored wire bytes
     * (.byte 0x0A, 0x00, 0x02, 0x0F per net_cfg.S). Already QEMU
     * default; this is a no-op write but keeps the test self-
     * contained. */
    adrp    x0, net_our_ip
    add     x0, x0, :lo12:net_our_ip
    mov     w1, #0x0A
    strb    w1, [x0, #0]
    strb    wzr, [x0, #1]
    mov     w1, #0x02
    strb    w1, [x0, #2]
    mov     w1, #0x0F
    strb    w1, [x0, #3]
    ret

/* Save net_hostname / len / our_ip into _mdns_save_buf at known
 * offsets. Restore is the symmetric copy. */
_mdns_test_save:
    adrp    x10, _mdns_save_buf
    add     x10, x10, :lo12:_mdns_save_buf
    adrp    x11, net_hostname
    add     x11, x11, :lo12:net_hostname
    /* 64 bytes hostname. */
    ldp     x9, x12, [x11, #0];   stp x9, x12, [x10, #0]
    ldp     x9, x12, [x11, #16];  stp x9, x12, [x10, #16]
    ldp     x9, x12, [x11, #32];  stp x9, x12, [x10, #32]
    ldp     x9, x12, [x11, #48];  stp x9, x12, [x10, #48]
    /* 4 bytes len. */
    adrp    x11, net_hostname_len
    add     x11, x11, :lo12:net_hostname_len
    ldr     w9, [x11];  str w9, [x10, #64]
    /* 4 bytes IP. */
    adrp    x11, net_our_ip
    add     x11, x11, :lo12:net_our_ip
    ldr     w9, [x11];  str w9, [x10, #68]
    ret

_mdns_test_restore:
    adrp    x10, _mdns_save_buf
    add     x10, x10, :lo12:_mdns_save_buf
    adrp    x11, net_hostname
    add     x11, x11, :lo12:net_hostname
    ldp     x9, x12, [x10, #0];   stp x9, x12, [x11, #0]
    ldp     x9, x12, [x10, #16];  stp x9, x12, [x11, #16]
    ldp     x9, x12, [x10, #32];  stp x9, x12, [x11, #32]
    ldp     x9, x12, [x10, #48];  stp x9, x12, [x11, #48]
    adrp    x11, net_hostname_len
    add     x11, x11, :lo12:net_hostname_len
    ldr     w9, [x10, #64]; str w9, [x11]
    adrp    x11, net_our_ip
    add     x11, x11, :lo12:net_our_ip
    ldr     w9, [x10, #68]; str w9, [x11]
    ret


/* ========================================================================
 * test_mdns_a_query_match — A query for "qemu.local" matches and
 * returns a well-formed response.
 * ======================================================================== */
test_mdns_a_query_match:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_q_qemu_a
    mov     w1, #_mdns_q_qemu_a_len
    ldr     x2, =_mdns_resp_buf
    bl      mdns_build_response

    /* Expect non-zero response length. */
    cbz     w0, .Ltma_fail
    /* Expect length to be 12 (hdr) + question + 12 + 4 (answer)
     * = 12 + 16 + 16 = 44. */
    cmp     w0, #44
    b.ne    .Ltma_fail

    /* Header byte 2 (flags high) = 0x84. */
    ldr     x0, =_mdns_resp_buf
    ldrb    w1, [x0, #2]
    cmp     w1, #0x84
    b.ne    .Ltma_fail
    /* ANCOUNT (bytes 6..7) = 0x00 0x01. */
    ldrb    w1, [x0, #6]
    cbnz    w1, .Ltma_fail
    ldrb    w1, [x0, #7]
    cmp     w1, #1
    b.ne    .Ltma_fail
    /* Last 4 bytes = our IP (10, 0, 2, 15). */
    ldrb    w1, [x0, #40]
    cmp     w1, #10
    b.ne    .Ltma_fail
    ldrb    w1, [x0, #41]
    cbnz    w1, .Ltma_fail
    ldrb    w1, [x0, #42]
    cmp     w1, #2
    b.ne    .Ltma_fail
    ldrb    w1, [x0, #43]
    cmp     w1, #15
    b.ne    .Ltma_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_match
    bl      test_pass
    b       .Ltma_done
.Ltma_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_match
    bl      test_fail
.Ltma_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_a_query_no_match — A query for "other.local" doesn't
 * match our hostname → returns 0.
 * ======================================================================== */
test_mdns_a_query_no_match:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_q_other_a
    mov     w1, #_mdns_q_other_a_len
    ldr     x2, =_mdns_resp_buf
    bl      mdns_build_response

    cbnz    w0, .Ltmn_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_no_match
    bl      test_pass
    b       .Ltmn_done
.Ltmn_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_no_match
    bl      test_fail
.Ltmn_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_aaaa_query_drop — AAAA (type 28) query for our
 * hostname is rejected → returns 0 (we are IPv4-only per D008).
 * ======================================================================== */
test_mdns_aaaa_query_drop:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_q_qemu_aaaa
    mov     w1, #_mdns_q_qemu_aaaa_len
    ldr     x2, =_mdns_resp_buf
    bl      mdns_build_response

    cbnz    w0, .Ltad_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_aaaa_drop
    bl      test_pass
    b       .Ltad_done
.Ltad_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_aaaa_drop
    bl      test_fail
.Ltad_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_dispatch_a_match — frame-level test of mdns_dispatch.
 * Builds a synthetic ETH+IP+UDP frame containing a query for
 * "qemu.local", calls mdns_dispatch, and asserts the response
 * frame has the right multicast headers (eth dst = 01:00:5e:00:00:fb,
 * ip dst = 224.0.0.251, ttl = 255, ports 5353/5353), our identity
 * in the src fields, and a well-formed mDNS response payload.
 * ======================================================================== */
test_mdns_dispatch_a_match:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    /* Copy the synthetic input frame into a writable BSS buffer
     * so mdns_dispatch can rewrite it in place. */
    ldr     x0, =_mdns_dispatch_in_frame
    ldr     x1, =_mdns_frame_buf
    mov     x2, #_mdns_dispatch_in_len
    bl      _mdns_test_memcpy

    ldr     x0, =_mdns_frame_buf
    mov     w1, #_mdns_dispatch_in_len
    bl      mdns_dispatch
    cbz     w0, .Ltmd_fail
    /* Expect frame length: ETH(14) + IP(20) + UDP(8) + payload(44) = 86. */
    cmp     w0, #86
    b.ne    .Ltmd_fail

    ldr     x0, =_mdns_frame_buf

    /* Eth dst = 01:00:5e:00:00:fb */
    ldrb    w1, [x0, #0]
    cmp     w1, #0x01
    b.ne    .Ltmd_fail
    ldrb    w1, [x0, #1]
    cbnz    w1, .Ltmd_fail
    ldrb    w1, [x0, #2]
    cmp     w1, #0x5e
    b.ne    .Ltmd_fail
    ldrb    w1, [x0, #5]
    cmp     w1, #0xfb
    b.ne    .Ltmd_fail

    /* Eth src = net_our_mac (02:00:00:00:00:01 per the QEMU default). */
    ldrb    w1, [x0, #6]
    cmp     w1, #0x02
    b.ne    .Ltmd_fail
    ldrb    w1, [x0, #11]
    cmp     w1, #0x01
    b.ne    .Ltmd_fail

    /* IP TTL = 255 per RFC 6762 §11. */
    ldrb    w1, [x0, #(14 + 8)]     /* ETH_HDR_LEN + IP_TTL */
    cmp     w1, #255
    b.ne    .Ltmd_fail

    /* IP src = our IP (10.0.2.15). */
    ldrb    w1, [x0, #(14 + 12)]
    cmp     w1, #10
    b.ne    .Ltmd_fail
    ldrb    w1, [x0, #(14 + 15)]
    cmp     w1, #15
    b.ne    .Ltmd_fail

    /* IP dst = 224.0.0.251. */
    ldrb    w1, [x0, #(14 + 16)]
    cmp     w1, #224
    b.ne    .Ltmd_fail
    ldrb    w1, [x0, #(14 + 19)]
    cmp     w1, #251
    b.ne    .Ltmd_fail

    /* UDP sport (offset 14+20=34) = 5353 (0x14E9). */
    ldrb    w1, [x0, #34]
    cmp     w1, #0x14
    b.ne    .Ltmd_fail
    ldrb    w1, [x0, #35]
    cmp     w1, #0xE9
    b.ne    .Ltmd_fail
    /* UDP dport = 5353. */
    ldrb    w1, [x0, #36]
    cmp     w1, #0x14
    b.ne    .Ltmd_fail
    ldrb    w1, [x0, #37]
    cmp     w1, #0xE9
    b.ne    .Ltmd_fail

    /* mDNS payload starts at offset 42. Header byte 2 = 0x84 (flags hi). */
    ldrb    w1, [x0, #(42 + 2)]
    cmp     w1, #0x84
    b.ne    .Ltmd_fail
    /* ANCOUNT (bytes 42+6, 42+7) = 0x00 0x01. */
    ldrb    w1, [x0, #(42 + 6)]
    cbnz    w1, .Ltmd_fail
    ldrb    w1, [x0, #(42 + 7)]
    cmp     w1, #1
    b.ne    .Ltmd_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_match
    bl      test_pass
    b       .Ltmd_done
.Ltmd_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_match
    bl      test_fail
.Ltmd_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_dispatch_no_reply — frame-level negative test.
 * A query for "other.local" → mdns_dispatch returns 0.
 * ======================================================================== */
test_mdns_dispatch_no_reply:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_dispatch_in_other
    ldr     x1, =_mdns_frame_buf
    mov     x2, #_mdns_dispatch_in_other_len
    bl      _mdns_test_memcpy

    ldr     x0, =_mdns_frame_buf
    mov     w1, #_mdns_dispatch_in_other_len
    bl      mdns_dispatch
    cbnz    w0, .Ltmnr_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_no_reply
    bl      test_pass
    b       .Ltmnr_done
.Ltmnr_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_no_reply
    bl      test_fail
.Ltmnr_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_net_recv_e2e — full L2→L3→L4→mDNS dispatch.
 *
 * Builds the same multicast mDNS query frame and hands it to
 * net_recv_one (the entry point net.S uses for incoming
 * packets). Pre-fix this drops at the L2 dst-MAC filter (which
 * accepts only our_mac or broadcast); after I15 (3/N) net.S
 * also accepts mdns_mac and ip.S accepts the 224.0.0.251
 * destination, so the path completes end-to-end and a non-zero
 * reply length comes back.
 * ======================================================================== */
test_mdns_net_recv_e2e:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_dispatch_in_frame
    ldr     x1, =_mdns_frame_buf
    mov     x2, #_mdns_dispatch_in_len
    bl      _mdns_test_memcpy

    ldr     x0, =_mdns_frame_buf
    mov     w1, #_mdns_dispatch_in_len
    bl      net_recv_one
    cbz     w0, .Ltme_fail
    /* Same expected length as the dispatch test. */
    cmp     w0, #86
    b.ne    .Ltme_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_net_recv_e2e
    bl      test_pass
    b       .Ltme_done
.Ltme_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_net_recv_e2e
    bl      test_fail
.Ltme_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_build_probe — verify mdns_build_probe_payload produces a
 * well-formed RFC 6762 §8.1 probe query packet for the configured
 * hostname.
 *
 * Expected packet for net_hostname="qemu":
 *   Header: id (any), flags=0x0000 (query), QDCOUNT=1, AN/NS/AR=0
 *   Question: QNAME=[4]"qemu"[5]"local"[0], QTYPE=ANY (255),
 *             QCLASS=IN (1)
 *   Total length = 12 + 12 + 4 = 28 bytes.
 * ======================================================================== */
test_mdns_build_probe:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_resp_buf         /* reuse the dispatch resp buf */
    bl      mdns_build_probe_payload
    cbz     w0, .Ltbp_fail
    cmp     w0, #28
    b.ne    .Ltbp_fail

    ldr     x0, =_mdns_resp_buf

    /* Header bytes 2-3: flags should be 0x0000 (query, no QR/AA). */
    ldrb    w1, [x0, #2]
    cbnz    w1, .Ltbp_fail
    ldrb    w1, [x0, #3]
    cbnz    w1, .Ltbp_fail

    /* QDCOUNT (bytes 4-5) = 0x0001. */
    ldrb    w1, [x0, #4]
    cbnz    w1, .Ltbp_fail
    ldrb    w1, [x0, #5]
    cmp     w1, #1
    b.ne    .Ltbp_fail

    /* ANCOUNT (bytes 6-7) = 0x0000. */
    ldrb    w1, [x0, #6]
    cbnz    w1, .Ltbp_fail
    ldrb    w1, [x0, #7]
    cbnz    w1, .Ltbp_fail

    /* QNAME starts at offset 12: [4]'q','e','m','u'[5]'l','o','c','a','l'[0]. */
    ldrb    w1, [x0, #12]
    cmp     w1, #4
    b.ne    .Ltbp_fail
    ldrb    w1, [x0, #13]
    cmp     w1, #'q'
    b.ne    .Ltbp_fail
    ldrb    w1, [x0, #16]
    cmp     w1, #'u'
    b.ne    .Ltbp_fail
    ldrb    w1, [x0, #17]
    cmp     w1, #5
    b.ne    .Ltbp_fail
    ldrb    w1, [x0, #18]
    cmp     w1, #'l'
    b.ne    .Ltbp_fail
    ldrb    w1, [x0, #22]
    cmp     w1, #'l'
    b.ne    .Ltbp_fail
    ldrb    w1, [x0, #23]
    cbnz    w1, .Ltbp_fail              /* terminator */

    /* QTYPE (bytes 24-25) = 0x00FF (ANY). */
    ldrb    w1, [x0, #24]
    cbnz    w1, .Ltbp_fail
    ldrb    w1, [x0, #25]
    cmp     w1, #0xff
    b.ne    .Ltbp_fail

    /* QCLASS (bytes 26-27) = 0x0001 (IN). */
    ldrb    w1, [x0, #26]
    cbnz    w1, .Ltbp_fail
    ldrb    w1, [x0, #27]
    cmp     w1, #1
    b.ne    .Ltbp_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_probe
    bl      test_pass
    b       .Ltbp_done
.Ltbp_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_probe
    bl      test_fail
.Ltbp_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_build_probe_frame — verify mdns_build_probe_frame wraps the
 * payload from mdns_build_probe_payload in correct Eth+IP+UDP multicast
 * headers. The header bytes mirror the wire format produced by
 * mdns_dispatch's response path, so this also pins the shared
 * _mdns_wrap_multicast_frame helper that 5/N extracts.
 *
 * Expected frame for net_hostname="qemu" / our_ip=10.0.2.15 / our_mac
 * QEMU default 02:00:00:00:00:01:
 *   Eth dst = 01:00:5e:00:00:fb (mdns_mac)
 *   Eth src = 02:00:00:00:00:01
 *   Eth type = 0x0800
 *   IP ver/IHL = 0x45, TTL = 255, proto = 17
 *   IP src = 10.0.2.15, dst = 224.0.0.251
 *   UDP sport = dport = 5353
 *   Payload at offset 42 has DNS query header (flags = 0x0000)
 *   QTYPE at offset 42+24 = 0x00FF (ANY)
 * Total length = 14 + 20 + 8 + 28 = 70.
 * ======================================================================== */
test_mdns_build_probe_frame:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_frame_buf
    bl      mdns_build_probe_frame
    cbz     w0, .Ltbpf_fail
    cmp     w0, #70
    b.ne    .Ltbpf_fail

    ldr     x0, =_mdns_frame_buf

    /* Eth dst = 01:00:5e:00:00:fb. */
    ldrb    w1, [x0, #0]
    cmp     w1, #0x01
    b.ne    .Ltbpf_fail
    ldrb    w1, [x0, #2]
    cmp     w1, #0x5e
    b.ne    .Ltbpf_fail
    ldrb    w1, [x0, #5]
    cmp     w1, #0xfb
    b.ne    .Ltbpf_fail

    /* Eth src = net_our_mac (02:00:00:00:00:01 per QEMU default). */
    ldrb    w1, [x0, #6]
    cmp     w1, #0x02
    b.ne    .Ltbpf_fail
    ldrb    w1, [x0, #11]
    cmp     w1, #0x01
    b.ne    .Ltbpf_fail

    /* Eth type = 0x0800. */
    ldrb    w1, [x0, #12]
    cmp     w1, #0x08
    b.ne    .Ltbpf_fail
    ldrb    w1, [x0, #13]
    cbnz    w1, .Ltbpf_fail

    /* IP ver/IHL = 0x45. */
    ldrb    w1, [x0, #14]
    cmp     w1, #0x45
    b.ne    .Ltbpf_fail

    /* IP TotalLength (BE) = 20+8+28 = 56 = 0x0038. */
    ldrb    w1, [x0, #(14 + 2)]
    cbnz    w1, .Ltbpf_fail
    ldrb    w1, [x0, #(14 + 3)]
    cmp     w1, #0x38
    b.ne    .Ltbpf_fail

    /* IP TTL = 255 per RFC 6762 §11. */
    ldrb    w1, [x0, #(14 + 8)]
    cmp     w1, #255
    b.ne    .Ltbpf_fail

    /* IP proto = 17 (UDP). */
    ldrb    w1, [x0, #(14 + 9)]
    cmp     w1, #17
    b.ne    .Ltbpf_fail

    /* IP src = 10.0.2.15. */
    ldrb    w1, [x0, #(14 + 12)]
    cmp     w1, #10
    b.ne    .Ltbpf_fail
    ldrb    w1, [x0, #(14 + 15)]
    cmp     w1, #15
    b.ne    .Ltbpf_fail

    /* IP dst = 224.0.0.251. */
    ldrb    w1, [x0, #(14 + 16)]
    cmp     w1, #224
    b.ne    .Ltbpf_fail
    ldrb    w1, [x0, #(14 + 19)]
    cmp     w1, #251
    b.ne    .Ltbpf_fail

    /* UDP sport (offset 14+20=34) = 5353 (0x14E9). */
    ldrb    w1, [x0, #34]
    cmp     w1, #0x14
    b.ne    .Ltbpf_fail
    ldrb    w1, [x0, #35]
    cmp     w1, #0xE9
    b.ne    .Ltbpf_fail
    /* UDP dport = 5353. */
    ldrb    w1, [x0, #36]
    cmp     w1, #0x14
    b.ne    .Ltbpf_fail
    ldrb    w1, [x0, #37]
    cmp     w1, #0xE9
    b.ne    .Ltbpf_fail

    /* UDP length (BE) = 8 + 28 = 36 = 0x0024. */
    ldrb    w1, [x0, #(14 + 20 + 4)]
    cbnz    w1, .Ltbpf_fail
    ldrb    w1, [x0, #(14 + 20 + 5)]
    cmp     w1, #0x24
    b.ne    .Ltbpf_fail

    /* DNS payload starts at offset 42. Header flags = 0x0000 (query). */
    ldrb    w1, [x0, #(42 + 2)]
    cbnz    w1, .Ltbpf_fail
    ldrb    w1, [x0, #(42 + 3)]
    cbnz    w1, .Ltbpf_fail

    /* QDCOUNT = 1. */
    ldrb    w1, [x0, #(42 + 5)]
    cmp     w1, #1
    b.ne    .Ltbpf_fail
    /* ANCOUNT = 0. */
    ldrb    w1, [x0, #(42 + 6)]
    cbnz    w1, .Ltbpf_fail
    ldrb    w1, [x0, #(42 + 7)]
    cbnz    w1, .Ltbpf_fail

    /* QTYPE = ANY (0x00FF) at offset 42+24. */
    ldrb    w1, [x0, #(42 + 24)]
    cbnz    w1, .Ltbpf_fail
    ldrb    w1, [x0, #(42 + 25)]
    cmp     w1, #0xff
    b.ne    .Ltbpf_fail

    /* QCLASS = IN (0x0001) at offset 42+26. */
    ldrb    w1, [x0, #(42 + 26)]
    cbnz    w1, .Ltbpf_fail
    ldrb    w1, [x0, #(42 + 27)]
    cmp     w1, #1
    b.ne    .Ltbpf_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_probe_frame
    bl      test_pass
    b       .Ltbpf_done
.Ltbpf_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_probe_frame
    bl      test_fail
.Ltbpf_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_build_probe_frame_empty — empty-hostname drop path:
 * mdns_build_probe_payload returns 0 when net_hostname_len is 0, and
 * mdns_build_probe_frame must propagate that as 0 (no frame emitted).
 * Pins the .Lpf_drop branch in lib/mdns.S.
 * ======================================================================== */
test_mdns_build_probe_frame_empty:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    /* Force hostname_len = 0 to trigger the drop path. */
    adrp    x0, net_hostname_len
    add     x0, x0, :lo12:net_hostname_len
    str     wzr, [x0]

    ldr     x0, =_mdns_frame_buf
    bl      mdns_build_probe_frame
    cbnz    w0, .Ltbpe_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_probe_frame_empty
    bl      test_pass
    b       .Ltbpe_done
.Ltbpe_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_probe_frame_empty
    bl      test_fail
.Ltbpe_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_conflict_match — RFC 6762 §8.1 conflict detection.
 * A response (QR=1) advertising our hostname.local with an A record
 * must register as a conflict.
 * ======================================================================== */
test_mdns_conflict_match:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_conflict_resp
    mov     w1, #_mdns_conflict_resp_len
    bl      mdns_check_conflict
    cmp     w0, #1
    b.ne    .Ltcm_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_match
    bl      test_pass
    b       .Ltcm_done
.Ltcm_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_match
    bl      test_fail
.Ltcm_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_conflict_other_name — response advertising a different
 * hostname is not our concern; mdns_check_conflict returns 0.
 * ======================================================================== */
test_mdns_conflict_other_name:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_conflict_other_resp
    mov     w1, #_mdns_conflict_other_resp_len
    bl      mdns_check_conflict
    cbnz    w0, .Ltco_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_other_name
    bl      test_pass
    b       .Ltco_done
.Ltco_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_other_name
    bl      test_fail
.Ltco_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_conflict_query_qr0 — a probe query (QR=0) for our name
 * is NOT yet a conflict at this layer (RFC 6762 §8.2 tiebreaking is
 * separate and out of scope for v1). mdns_check_conflict only
 * triggers on authoritative responses.
 * ======================================================================== */
test_mdns_conflict_query_qr0:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_q_qemu_a       /* same query format we ALREADY answer */
    mov     w1, #_mdns_q_qemu_a_len
    bl      mdns_check_conflict
    cbnz    w0, .Ltcq_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_query_qr0
    bl      test_pass
    b       .Ltcq_done
.Ltcq_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_query_qr0
    bl      test_fail
.Ltcq_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_conflict_no_answer — response (QR=1) with ANCOUNT=0
 * (header-only, no records) returns 0.
 * ======================================================================== */
test_mdns_conflict_no_answer:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_conflict_empty
    mov     w1, #_mdns_conflict_empty_len
    bl      mdns_check_conflict
    cbnz    w0, .Ltcn_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_no_answer
    bl      test_pass
    b       .Ltcn_done
.Ltcn_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_no_answer
    bl      test_fail
.Ltcn_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_conflict_short — packets shorter than DNS header (12)
 * return 0.
 * ======================================================================== */
test_mdns_conflict_short:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_conflict_resp
    mov     w1, #5                    /* truncated, below DNS header */
    bl      mdns_check_conflict
    cbnz    w0, .Ltcs_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_short
    bl      test_pass
    b       .Ltcs_done
.Ltcs_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_short
    bl      test_fail
.Ltcs_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_conflict_compressed_name — locks in the documented v1
 * limitation: an answer whose NAME is a compression pointer is NOT
 * compared against our hostname. mdns_check_conflict returns 0 even
 * when the compression target points at our name in the question
 * section. (RFC 1035 §4.1.4 compression resolution is out of scope
 * for v1 per the function header in lib/mdns.S; this test will need
 * to flip to expect 1 if/when v2 adds pointer-following.)
 * ======================================================================== */
test_mdns_conflict_compressed_name:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_conflict_ptr_resp
    mov     w1, #_mdns_conflict_ptr_resp_len
    bl      mdns_check_conflict
    cbnz    w0, .Ltcc_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_compressed_name
    bl      test_pass
    b       .Ltcc_done
.Ltcc_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_compressed_name
    bl      test_fail
.Ltcc_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_conflict_with_question — proves the QDCOUNT skip loop
 * correctly walks past a question to reach the answer. Packet has
 * QDCOUNT=1 (a "qemu.local" question) and ANCOUNT=1 (also for
 * "qemu.local"); QR=1. Expect return 1.
 * ======================================================================== */
test_mdns_conflict_with_question:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_conflict_with_q
    mov     w1, #_mdns_conflict_with_q_len
    bl      mdns_check_conflict
    cmp     w0, #1
    b.ne    .Ltcwq_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_with_question
    bl      test_pass
    b       .Ltcwq_done
.Ltcwq_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_conflict_with_question
    bl      test_fail
.Ltcwq_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_build_announce — verify mdns_build_announce_payload
 * produces an RFC 6762 §8.3 unsolicited-response payload for our
 * hostname.
 *
 * Expected packet for net_hostname="qemu" / our_ip=10.0.2.15:
 *   Header (12): id=0, flags=0x8400 (QR=1 AA=1), QDCOUNT=0, ANCOUNT=1
 *   Answer:
 *     NAME = [4]"qemu"[5]"local"[0]    (12 bytes, full inline)
 *     TYPE = 0x0001 (A)                (2)
 *     CLASS = 0x8001 (IN | cache-flush) (2)
 *     TTL = 0x00000078 (120 sec)       (4)
 *     RDLENGTH = 4                      (2)
 *     RDATA = 10.0.2.15                 (4)
 *   Total = 12 + 12 + 14 = 38 bytes.
 * ======================================================================== */
test_mdns_build_announce:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_resp_buf
    bl      mdns_build_announce_payload
    cbz     w0, .Ltba_fail
    cmp     w0, #38
    b.ne    .Ltba_fail

    ldr     x0, =_mdns_resp_buf

    /* Header: id (any), flags hi=0x84, lo=0x00. */
    ldrb    w1, [x0, #2]
    cmp     w1, #0x84
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #3]
    cbnz    w1, .Ltba_fail

    /* QDCOUNT = 0 (bytes 4-5). */
    ldrb    w1, [x0, #4]
    cbnz    w1, .Ltba_fail
    ldrb    w1, [x0, #5]
    cbnz    w1, .Ltba_fail

    /* ANCOUNT = 1 (bytes 6-7). */
    ldrb    w1, [x0, #6]
    cbnz    w1, .Ltba_fail
    ldrb    w1, [x0, #7]
    cmp     w1, #1
    b.ne    .Ltba_fail

    /* NAME at offset 12: [4]'q','e','m','u'[5]'l','o','c','a','l'[0]. */
    ldrb    w1, [x0, #12]
    cmp     w1, #4
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #13]
    cmp     w1, #'q'
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #16]
    cmp     w1, #'u'
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #17]
    cmp     w1, #5
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #22]
    cmp     w1, #'l'
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #23]
    cbnz    w1, .Ltba_fail        /* terminator */

    /* TYPE = 0x0001 at offset 24-25. */
    ldrb    w1, [x0, #24]
    cbnz    w1, .Ltba_fail
    ldrb    w1, [x0, #25]
    cmp     w1, #1
    b.ne    .Ltba_fail

    /* CLASS = 0x8001 at offset 26-27. */
    ldrb    w1, [x0, #26]
    cmp     w1, #0x80
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #27]
    cmp     w1, #1
    b.ne    .Ltba_fail

    /* TTL = 0x00000078 at offset 28-31. */
    ldrb    w1, [x0, #28]
    cbnz    w1, .Ltba_fail
    ldrb    w1, [x0, #31]
    cmp     w1, #0x78
    b.ne    .Ltba_fail

    /* RDLENGTH = 4 at offset 32-33. */
    ldrb    w1, [x0, #32]
    cbnz    w1, .Ltba_fail
    ldrb    w1, [x0, #33]
    cmp     w1, #4
    b.ne    .Ltba_fail

    /* RDATA = 10, 0, 2, 15 at offset 34-37. */
    ldrb    w1, [x0, #34]
    cmp     w1, #10
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #35]
    cbnz    w1, .Ltba_fail
    ldrb    w1, [x0, #36]
    cmp     w1, #2
    b.ne    .Ltba_fail
    ldrb    w1, [x0, #37]
    cmp     w1, #15
    b.ne    .Ltba_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_announce
    bl      test_pass
    b       .Ltba_done
.Ltba_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_announce
    bl      test_fail
.Ltba_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_build_announce_frame — verify mdns_build_announce_frame
 * wraps the announce payload in the standard multicast Eth+IP+UDP
 * headers. Total length = 14+20+8+38 = 80 bytes.
 * ======================================================================== */
test_mdns_build_announce_frame:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    ldr     x0, =_mdns_frame_buf
    bl      mdns_build_announce_frame
    cbz     w0, .Ltbaf_fail
    cmp     w0, #80
    b.ne    .Ltbaf_fail

    ldr     x0, =_mdns_frame_buf

    /* Eth dst[0] = 0x01, dst[5] = 0xfb (mdns_mac). */
    ldrb    w1, [x0, #0]
    cmp     w1, #0x01
    b.ne    .Ltbaf_fail
    ldrb    w1, [x0, #5]
    cmp     w1, #0xfb
    b.ne    .Ltbaf_fail

    /* IP TotalLength (BE) = 20+8+38 = 66 = 0x0042. */
    ldrb    w1, [x0, #(14 + 2)]
    cbnz    w1, .Ltbaf_fail
    ldrb    w1, [x0, #(14 + 3)]
    cmp     w1, #0x42
    b.ne    .Ltbaf_fail

    /* IP TTL = 255. */
    ldrb    w1, [x0, #(14 + 8)]
    cmp     w1, #255
    b.ne    .Ltbaf_fail

    /* IP dst = 224.0.0.251. */
    ldrb    w1, [x0, #(14 + 16)]
    cmp     w1, #224
    b.ne    .Ltbaf_fail
    ldrb    w1, [x0, #(14 + 19)]
    cmp     w1, #251
    b.ne    .Ltbaf_fail

    /* UDP sport = 5353 (BE 0x14 0xE9) at offset 34-35. */
    ldrb    w1, [x0, #34]
    cmp     w1, #0x14
    b.ne    .Ltbaf_fail
    ldrb    w1, [x0, #35]
    cmp     w1, #0xE9
    b.ne    .Ltbaf_fail

    /* UDP length (BE) = 8+38 = 46 = 0x002E at offset 38-39. */
    ldrb    w1, [x0, #(14 + 20 + 4)]
    cbnz    w1, .Ltbaf_fail
    ldrb    w1, [x0, #(14 + 20 + 5)]
    cmp     w1, #0x2E
    b.ne    .Ltbaf_fail

    /* DNS payload at offset 42, header byte 2 = 0x84 (QR|AA). */
    ldrb    w1, [x0, #(42 + 2)]
    cmp     w1, #0x84
    b.ne    .Ltbaf_fail

    /* QDCOUNT = 0, ANCOUNT = 1. */
    ldrb    w1, [x0, #(42 + 5)]
    cbnz    w1, .Ltbaf_fail
    ldrb    w1, [x0, #(42 + 7)]
    cmp     w1, #1
    b.ne    .Ltbaf_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_announce_frame
    bl      test_pass
    b       .Ltbaf_done
.Ltbaf_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_announce_frame
    bl      test_fail
.Ltbaf_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_build_announce_empty — empty hostname → no frame.
 * Pins the drop branch in mdns_build_announce_frame.
 * ======================================================================== */
test_mdns_build_announce_empty:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    adrp    x0, net_hostname_len
    add     x0, x0, :lo12:net_hostname_len
    str     wzr, [x0]

    ldr     x0, =_mdns_frame_buf
    bl      mdns_build_announce_frame
    cbnz    w0, .Ltbae_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_announce_empty
    bl      test_pass
    b       .Ltbae_done
.Ltbae_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_build_announce_empty
    bl      test_fail
.Ltbae_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * Fake send_fn used by the state-machine tests. Signature matches
 * what arp.S and (eventually) main.S pass through:
 *   x0 = dwc2_base, x1 = ecm_state, x2 = frame_ptr, w3 = frame_len
 * Captures (frame_ptr, frame_len) and increments a call counter
 * into BSS globals. Returns 0.
 * ======================================================================== */
_mdns_send_capture:
    adrp    x4, _mdns_send_count
    add     x4, x4, :lo12:_mdns_send_count
    ldr     w5, [x4]
    add     w5, w5, #1
    str     w5, [x4]

    adrp    x4, _mdns_last_frame
    add     x4, x4, :lo12:_mdns_last_frame
    str     x2, [x4]
    str     w3, [x4, #8]
    mov     w0, #0
    ret

_mdns_send_capture_reset:
    adrp    x0, _mdns_send_count
    add     x0, x0, :lo12:_mdns_send_count
    str     wzr, [x0]
    adrp    x0, _mdns_last_frame
    add     x0, x0, :lo12:_mdns_last_frame
    str     xzr, [x0]
    str     wzr, [x0, #8]
    ret


/* Common state-machine test setup: save real net_* globals, set
 * QEMU defaults, reset send capture, init a fake timer pool, then
 * call mdns_start. Returns nothing meaningful. */
_mdns_state_setup:
    stp     x29, x30, [sp, #-16]!
    bl      _mdns_test_save
    bl      _mdns_test_set_state
    bl      _mdns_send_capture_reset
    /* Init a roomy timer pool so 5+ arms don't exhaust capacity. */
    ldr     x0, =_mdns_test_tpool
    mov     w1, #8
    bl      timer_pool_init
    /* mdns_start(dwc2_base=0, ecm_state=0, tx_buf, timer_pool, send_fn) */
    mov     x0, #0
    mov     x1, #0
    ldr     x2, =_mdns_frame_buf
    ldr     x3, =_mdns_test_tpool
    ldr     x4, =_mdns_send_capture
    bl      mdns_start
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_state_initial — after mdns_start, state == PROBE_1
 * (a probe is scheduled but has not yet been sent). send_count == 0.
 * ======================================================================== */
test_mdns_state_initial:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_state_setup

    bl      mdns_get_state
    cmp     w0, #1                 /* MDNS_STATE_PROBE_1 */
    b.ne    .Ltsi_fail

    adrp    x0, _mdns_send_count
    add     x0, x0, :lo12:_mdns_send_count
    ldr     w0, [x0]
    cbnz    w0, .Ltsi_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_initial
    bl      test_pass
    b       .Ltsi_done
.Ltsi_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_initial
    bl      test_fail
.Ltsi_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_state_advance_one — one mdns_timer_cb call sends a frame,
 * advances state PROBE_1 → PROBE_2, and increments send_count.
 * ======================================================================== */
test_mdns_state_advance_one:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_state_setup

    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb

    bl      mdns_get_state
    cmp     w0, #2                 /* MDNS_STATE_PROBE_2 */
    b.ne    .Ltsao_fail

    adrp    x0, _mdns_send_count
    add     x0, x0, :lo12:_mdns_send_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ltsao_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_advance_one
    bl      test_pass
    b       .Ltsao_done
.Ltsao_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_advance_one
    bl      test_fail
.Ltsao_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_state_full_sequence — five mdns_timer_cb calls walk
 * through PROBE_1 → PROBE_2 → PROBE_3 → ANNOUNCE_1 → ANNOUNCE_2 →
 * LIVE, with one frame sent at each step (total send_count == 5).
 * ======================================================================== */
test_mdns_state_full_sequence:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_state_setup

    /* Drive 5 callbacks. */
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb

    bl      mdns_get_state
    cmp     w0, #6                 /* MDNS_STATE_LIVE */
    b.ne    .Ltsfs_fail

    adrp    x0, _mdns_send_count
    add     x0, x0, :lo12:_mdns_send_count
    ldr     w0, [x0]
    cmp     w0, #5
    b.ne    .Ltsfs_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_full_sequence
    bl      test_pass
    b       .Ltsfs_done
.Ltsfs_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_full_sequence
    bl      test_fail
.Ltsfs_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_state_first_send_is_probe — the first frame emitted
 * should be a probe. Identifying byte: DNS payload flags hi == 0x00
 * (QR=0). (Announces would be 0x84.)
 * ======================================================================== */
test_mdns_state_first_send_is_probe:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_state_setup
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb

    /* Read captured frame ptr + check payload[42 + 2]. */
    adrp    x0, _mdns_last_frame
    add     x0, x0, :lo12:_mdns_last_frame
    ldr     x0, [x0]
    cbz     x0, .Ltsfp_fail
    ldrb    w1, [x0, #(42 + 2)]
    cbnz    w1, .Ltsfp_fail        /* probe flags byte is 0x00 */

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_first_send_is_probe
    bl      test_pass
    b       .Ltsfp_done
.Ltsfp_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_first_send_is_probe
    bl      test_fail
.Ltsfp_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_state_fourth_send_is_announce — after 3 probe sends and
 * 1 more callback, the 4th frame is an announce: payload flags hi
 * byte == 0x84 (QR=1, AA=1).
 * ======================================================================== */
test_mdns_state_fourth_send_is_announce:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_state_setup
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb

    /* state should now be ANNOUNCE_2 (after 4 sends: probe×3 +
     * announce×1). */
    bl      mdns_get_state
    cmp     w0, #5                 /* MDNS_STATE_ANNOUNCE_2 */
    b.ne    .Ltsfa_fail

    /* Last frame's payload flags hi == 0x84. */
    adrp    x0, _mdns_last_frame
    add     x0, x0, :lo12:_mdns_last_frame
    ldr     x0, [x0]
    cbz     x0, .Ltsfa_fail
    ldrb    w1, [x0, #(42 + 2)]
    cmp     w1, #0x84
    b.ne    .Ltsfa_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_fourth_send_is_announce
    bl      test_pass
    b       .Ltsfa_done
.Ltsfa_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_fourth_send_is_announce
    bl      test_fail
.Ltsfa_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_state_live_noop — once LIVE, mdns_timer_cb is a no-op:
 * state stays LIVE and send_count does not increment.
 * ======================================================================== */
test_mdns_state_live_noop:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_state_setup
    /* Drive to LIVE (5 callbacks). */
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb
    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb

    /* Confirm we're LIVE before the no-op test. */
    bl      mdns_get_state
    cmp     w0, #6
    b.ne    .Ltsln_fail

    /* Snapshot count, hit cb again, verify nothing changed. */
    adrp    x1, _mdns_send_count
    add     x1, x1, :lo12:_mdns_send_count
    ldr     w2, [x1]
    cmp     w2, #5
    b.ne    .Ltsln_fail

    ldr     x0, =mdns_send_ctx
    bl      mdns_timer_cb

    bl      mdns_get_state
    cmp     w0, #6                 /* still LIVE */
    b.ne    .Ltsln_fail

    adrp    x1, _mdns_send_count
    add     x1, x1, :lo12:_mdns_send_count
    ldr     w2, [x1]
    cmp     w2, #5                 /* unchanged */
    b.ne    .Ltsln_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_live_noop
    bl      test_pass
    b       .Ltsln_done
.Ltsln_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_state_live_noop
    bl      test_fail
.Ltsln_done:
    ldp     x29, x30, [sp], #16
    ret


/* Stub panic handler for tests: increments _mdns_panic_count and
 * returns. Wired in via mdns_panic_fn; the production default
 * (mdns_panic_fn = NULL → fall through to bl panic_n in mdns.S)
 * is what production uses, but tests overwrite mdns_panic_fn so
 * the conflict path can be exercised without halting. */
_mdns_panic_capture:
    adrp    x0, _mdns_panic_count
    add     x0, x0, :lo12:_mdns_panic_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]
    ret

_mdns_panic_capture_install:
    adrp    x0, _mdns_panic_count
    add     x0, x0, :lo12:_mdns_panic_count
    str     wzr, [x0]
    adrp    x0, mdns_panic_fn
    add     x0, x0, :lo12:mdns_panic_fn
    ldr     x1, =_mdns_panic_capture
    str     x1, [x0]
    ret

_mdns_panic_capture_uninstall:
    adrp    x0, mdns_panic_fn
    add     x0, x0, :lo12:mdns_panic_fn
    str     xzr, [x0]
    ret


/* ========================================================================
 * test_mdns_dispatch_drops_in_probe — during PROBE_*, dispatch
 * silently drops a query that LIVE state would have answered.
 * Pre-9/N this would have returned 86 (the response frame length).
 * ======================================================================== */
test_mdns_dispatch_drops_in_probe:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    /* Override state to PROBE_2. */
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    mov     w1, #2
    str     w1, [x0, #48]

    /* Seed the standard mDNS query frame and dispatch it. */
    ldr     x0, =_mdns_dispatch_in_frame
    ldr     x1, =_mdns_frame_buf
    mov     x2, #_mdns_dispatch_in_len
    bl      _mdns_test_memcpy
    ldr     x0, =_mdns_frame_buf
    mov     w1, #_mdns_dispatch_in_len
    bl      mdns_dispatch
    cbnz    w0, .Ltddp_fail            /* must drop */

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_drops_in_probe
    bl      test_pass
    b       .Ltddp_done
.Ltddp_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_drops_in_probe
    bl      test_fail
.Ltddp_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_dispatch_responds_in_announce — during ANNOUNCE_*,
 * dispatch responds normally. RFC 6762 §8.3: the responder is
 * authoritative from first announce onward.
 * ======================================================================== */
test_mdns_dispatch_responds_in_announce:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state

    /* Override state to ANNOUNCE_1. */
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    mov     w1, #4
    str     w1, [x0, #48]

    ldr     x0, =_mdns_dispatch_in_frame
    ldr     x1, =_mdns_frame_buf
    mov     x2, #_mdns_dispatch_in_len
    bl      _mdns_test_memcpy
    ldr     x0, =_mdns_frame_buf
    mov     w1, #_mdns_dispatch_in_len
    bl      mdns_dispatch
    cmp     w0, #86                    /* must produce a response frame */
    b.ne    .Ltdra_fail

    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_responds_in_announce
    bl      test_pass
    b       .Ltdra_done
.Ltdra_fail:
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_responds_in_announce
    bl      test_fail
.Ltdra_done:
    ldp     x29, x30, [sp], #16
    ret


/* ========================================================================
 * test_mdns_dispatch_panics_on_conflict — during PROBE_*, a packet
 * that mdns_check_conflict flags must invoke mdns_panic_fn (in
 * production: panic_n; in test: the capture stub). Verified via
 * the stub's call counter.
 * ======================================================================== */
test_mdns_dispatch_panics_on_conflict:
    stp     x29, x30, [sp, #-16]!

    bl      _mdns_test_save
    bl      _mdns_test_set_state
    bl      _mdns_panic_capture_install

    /* State = PROBE_2. */
    adrp    x0, mdns_send_ctx
    add     x0, x0, :lo12:mdns_send_ctx
    mov     w1, #2
    str     w1, [x0, #48]

    /* Build a frame whose UDP payload is a conflict response. The
     * Eth/IP/UDP headers are seeded from the known-valid mDNS
     * dispatch frame so ip_handle/udp_handle don't bail; we only
     * need the mDNS payload to be a conflict packet. _mdns_dispatch_in_frame
     * already has valid Eth/IP/UDP wrap and our standard "qemu.local"
     * query. We need to overwrite the payload (offset 42..) with the
     * conflict-response bytes. */
    ldr     x0, =_mdns_dispatch_in_frame
    ldr     x1, =_mdns_frame_buf
    mov     x2, #_mdns_dispatch_in_len
    bl      _mdns_test_memcpy

    /* Patch payload: stamp _mdns_conflict_resp into frame[42..]. */
    ldr     x0, =_mdns_conflict_resp
    ldr     x1, =_mdns_frame_buf
    add     x1, x1, #42
    mov     x2, #_mdns_conflict_resp_len
    bl      _mdns_test_memcpy

    ldr     x0, =_mdns_frame_buf
    mov     w1, #_mdns_dispatch_in_len
    bl      mdns_dispatch
    /* We don't care about the return value — what matters is that
     * the panic stub was invoked. */

    adrp    x0, _mdns_panic_count
    add     x0, x0, :lo12:_mdns_panic_count
    ldr     w0, [x0]
    cmp     w0, #1
    b.ne    .Ltdpc_fail

    bl      _mdns_panic_capture_uninstall
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_panics_on_conflict
    bl      test_pass
    b       .Ltdpc_done
.Ltdpc_fail:
    bl      _mdns_panic_capture_uninstall
    bl      _mdns_test_restore
    ldr     x0, =_mdns_name_dispatch_panics_on_conflict
    bl      test_fail
.Ltdpc_done:
    ldp     x29, x30, [sp], #16
    ret


/* Tiny memcpy used by the dispatch tests to seed _mdns_frame_buf
 * from the read-only synthetic frames. x0=src, x1=dst, x2=len. */
_mdns_test_memcpy:
    cbz     x2, 9f
1:  ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    sub     x2, x2, #1
    cbnz    x2, 1b
9:  ret


.section .rodata

_mdns_name_match:
    .asciz "mdns_a_query_match"
_mdns_name_no_match:
    .asciz "mdns_a_query_no_match"
_mdns_name_aaaa_drop:
    .asciz "mdns_aaaa_query_drop"
_mdns_name_dispatch_match:
    .asciz "mdns_dispatch_a_match"
_mdns_name_dispatch_no_reply:
    .asciz "mdns_dispatch_no_reply"
_mdns_name_net_recv_e2e:
    .asciz "mdns_net_recv_e2e"
_mdns_name_build_probe:
    .asciz "mdns_build_probe"
_mdns_name_build_probe_frame:
    .asciz "mdns_build_probe_frame"
_mdns_name_build_probe_frame_empty:
    .asciz "mdns_build_probe_frame_empty"
_mdns_name_conflict_match:
    .asciz "mdns_conflict_match"
_mdns_name_conflict_other_name:
    .asciz "mdns_conflict_other_name"
_mdns_name_conflict_query_qr0:
    .asciz "mdns_conflict_query_qr0"
_mdns_name_conflict_no_answer:
    .asciz "mdns_conflict_no_answer"
_mdns_name_conflict_short:
    .asciz "mdns_conflict_short"
_mdns_name_conflict_compressed_name:
    .asciz "mdns_conflict_compressed_name"
_mdns_name_conflict_with_question:
    .asciz "mdns_conflict_with_question"
_mdns_name_build_announce:
    .asciz "mdns_build_announce"
_mdns_name_build_announce_frame:
    .asciz "mdns_build_announce_frame"
_mdns_name_build_announce_empty:
    .asciz "mdns_build_announce_empty"
_mdns_name_state_initial:
    .asciz "mdns_state_initial"
_mdns_name_state_advance_one:
    .asciz "mdns_state_advance_one"
_mdns_name_state_full_sequence:
    .asciz "mdns_state_full_sequence"
_mdns_name_state_first_send_is_probe:
    .asciz "mdns_state_first_send_is_probe"
_mdns_name_state_fourth_send_is_announce:
    .asciz "mdns_state_fourth_send_is_announce"
_mdns_name_state_live_noop:
    .asciz "mdns_state_live_noop"
_mdns_name_dispatch_drops_in_probe:
    .asciz "mdns_dispatch_drops_in_probe"
_mdns_name_dispatch_responds_in_announce:
    .asciz "mdns_dispatch_responds_in_announce"
_mdns_name_dispatch_panics_on_conflict:
    .asciz "mdns_dispatch_panics_on_conflict"

/* Synthetic A query for "qemu.local". DNS header (12 bytes) +
 * question.
 *   id=0x1234, flags=0x0000, qd=1, an=ns=ar=0
 *   QNAME = [4]"qemu" [5]"local" [0] = 12 bytes
 *   QTYPE = 0x0001 (A)
 *   QCLASS = 0x0001 (IN)
 * Total = 12 + 12 + 4 = 28 bytes. */
.balign 4
_mdns_q_qemu_a:
    /* Header */
    .byte 0x12, 0x34       /* id */
    .byte 0x00, 0x00       /* flags */
    .byte 0x00, 0x01       /* qd */
    .byte 0x00, 0x00       /* an */
    .byte 0x00, 0x00       /* ns */
    .byte 0x00, 0x00       /* ar */
    /* QNAME */
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    /* QTYPE = A */
    .byte 0x00, 0x01
    /* QCLASS = IN */
    .byte 0x00, 0x01
.equ _mdns_q_qemu_a_len, (. - _mdns_q_qemu_a)

/* Synthetic A query for "other.local" — same shape, different name. */
.balign 4
_mdns_q_other_a:
    .byte 0x12, 0x34
    .byte 0x00, 0x00
    .byte 0x00, 0x01
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 5
    .ascii "other"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01
    .byte 0x00, 0x01
.equ _mdns_q_other_a_len, (. - _mdns_q_other_a)

/* AAAA query for "qemu.local" — type 28 (0x001C). */
.balign 4
_mdns_q_qemu_aaaa:
    .byte 0x12, 0x34
    .byte 0x00, 0x00
    .byte 0x00, 0x01
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x1C       /* QTYPE = AAAA */
    .byte 0x00, 0x01
.equ _mdns_q_qemu_aaaa_len, (. - _mdns_q_qemu_aaaa)


/* Synthetic ETH+IP+UDP+DNS frame: a sender at 10.0.0.5 / MAC
 * de:ad:be:ef:01:23 sending an mDNS A query for "qemu.local" to
 * the IPv4 mDNS multicast group 224.0.0.251 / 01:00:5e:00:00:fb.
 * Layout: 14 (ETH) + 20 (IP) + 8 (UDP) + 28 (DNS) = 70 bytes. */
.balign 4
_mdns_dispatch_in_frame:
    /* Eth: dst=01:00:5e:00:00:fb, src=de:ad:be:ef:01:23, type=0x0800 */
    .byte 0x01, 0x00, 0x5e, 0x00, 0x00, 0xfb
    .byte 0xde, 0xad, 0xbe, 0xef, 0x01, 0x23
    .byte 0x08, 0x00
    /* IP: ver/IHL=0x45, TOS=0, totlen=56 (IP+UDP+DNS),
     * id=0, flags/frag=0, ttl=255, proto=17 (UDP),
     * checksum=0xd0b4 (computed: ~one's-complement-sum over the
     * other 9 16-bit words; ip_handle validates this).
     * src=10.0.0.5, dst=224.0.0.251. */
    .byte 0x45, 0x00
    .byte 0x00, 0x38
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0xff, 0x11
    .byte 0xd0, 0xb4
    .byte 0x0a, 0x00, 0x00, 0x05
    .byte 0xe0, 0x00, 0x00, 0xfb
    /* UDP: sport=5353, dport=5353, len=36 (UDP+DNS), checksum=0. */
    .byte 0x14, 0xe9
    .byte 0x14, 0xe9
    .byte 0x00, 0x24
    .byte 0x00, 0x00
    /* DNS: id=0x1234, flags=0, qd=1, an=ns=ar=0,
     *      QNAME=[4]"qemu"[5]"local"[0], QTYPE=A, QCLASS=IN. */
    .byte 0x12, 0x34
    .byte 0x00, 0x00
    .byte 0x00, 0x01
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01
    .byte 0x00, 0x01
.equ _mdns_dispatch_in_len, (. - _mdns_dispatch_in_frame)

/* Same shape but query for "other.local" — should not produce
 * a reply when net_hostname is "qemu". */
.balign 4
_mdns_dispatch_in_other:
    .byte 0x01, 0x00, 0x5e, 0x00, 0x00, 0xfb
    .byte 0xde, 0xad, 0xbe, 0xef, 0x01, 0x23
    .byte 0x08, 0x00
    .byte 0x45, 0x00
    .byte 0x00, 0x39
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0xff, 0x11
    .byte 0x00, 0x00
    .byte 0x0a, 0x00, 0x00, 0x05
    .byte 0xe0, 0x00, 0x00, 0xfb
    .byte 0x14, 0xe9
    .byte 0x14, 0xe9
    .byte 0x00, 0x25
    .byte 0x00, 0x00
    .byte 0x12, 0x34
    .byte 0x00, 0x00
    .byte 0x00, 0x01
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 5
    .ascii "other"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01
    .byte 0x00, 0x01
.equ _mdns_dispatch_in_other_len, (. - _mdns_dispatch_in_other)


/* Synthetic mDNS announce: a foreign host is claiming "qemu.local".
 *   Header: id=0, flags=0x8400 (QR=1, AA=1), QDCOUNT=0, ANCOUNT=1.
 *   Answer: NAME=[4]"qemu"[5]"local"[0], TYPE=A, CLASS=IN|cache-flush,
 *           TTL=120, RDLENGTH=4, RDATA=192.168.1.42.
 * Total length = 12 (hdr) + 12 (name) + 14 (rest of RR) = 38. */
.balign 4
_mdns_conflict_resp:
    .byte 0x00, 0x00       /* id */
    .byte 0x84, 0x00       /* flags: QR=1 AA=1 */
    .byte 0x00, 0x00       /* QDCOUNT=0 */
    .byte 0x00, 0x01       /* ANCOUNT=1 */
    .byte 0x00, 0x00       /* NSCOUNT=0 */
    .byte 0x00, 0x00       /* ARCOUNT=0 */
    /* Answer */
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01       /* TYPE = A */
    .byte 0x80, 0x01       /* CLASS = IN | cache-flush */
    .byte 0x00, 0x00, 0x00, 0x78   /* TTL = 120 */
    .byte 0x00, 0x04       /* RDLENGTH */
    .byte 0xc0, 0xa8, 0x01, 0x2a   /* RDATA = 192.168.1.42 */
.equ _mdns_conflict_resp_len, (. - _mdns_conflict_resp)

/* Same shape, different hostname ("other.local"). Should not flag. */
.balign 4
_mdns_conflict_other_resp:
    .byte 0x00, 0x00
    .byte 0x84, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x01
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 5
    .ascii "other"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01
    .byte 0x80, 0x01
    .byte 0x00, 0x00, 0x00, 0x78
    .byte 0x00, 0x04
    .byte 0xc0, 0xa8, 0x01, 0x2a
.equ _mdns_conflict_other_resp_len, (. - _mdns_conflict_other_resp)

/* Header-only response: QR=1, AA=1, ANCOUNT=0. */
.balign 4
_mdns_conflict_empty:
    .byte 0x00, 0x00
    .byte 0x84, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    .byte 0x00, 0x00
.equ _mdns_conflict_empty_len, (. - _mdns_conflict_empty)

/* Response with the answer NAME encoded as a compression pointer
 * back to a question section that holds "qemu.local". v1 does NOT
 * follow pointers; mdns_check_conflict must return 0 here even
 * though semantically this DOES advertise our name.
 *   Header: QR=1, AA=1, QDCOUNT=1, ANCOUNT=1
 *   Question: QNAME=[4]"qemu"[5]"local"[0], QTYPE=A, QCLASS=IN
 *   Answer:   NAME=0xC0 0x0C (pointer → question's QNAME at off 12),
 *             TYPE=A, CLASS=IN|cache-flush, TTL=120, RDLEN=4,
 *             RDATA=192.168.1.42
 * Total = 12 + 16 (question) + 2 + 10 + 4 = 44. */
.balign 4
_mdns_conflict_ptr_resp:
    .byte 0x00, 0x00
    .byte 0x84, 0x00
    .byte 0x00, 0x01      /* QDCOUNT=1 */
    .byte 0x00, 0x01      /* ANCOUNT=1 */
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    /* Question */
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01
    .byte 0x00, 0x01
    /* Answer */
    .byte 0xc0, 0x0c      /* NAME = pointer to offset 12 */
    .byte 0x00, 0x01
    .byte 0x80, 0x01
    .byte 0x00, 0x00, 0x00, 0x78
    .byte 0x00, 0x04
    .byte 0xc0, 0xa8, 0x01, 0x2a
.equ _mdns_conflict_ptr_resp_len, (. - _mdns_conflict_ptr_resp)

/* Response with both a question and an answer for "qemu.local",
 * answer NAME inlined as direct labels (not a pointer). Exercises
 * the QDCOUNT skip path then matches our hostname. Expect return 1. */
.balign 4
_mdns_conflict_with_q:
    .byte 0x00, 0x00
    .byte 0x84, 0x00
    .byte 0x00, 0x01      /* QDCOUNT=1 */
    .byte 0x00, 0x01      /* ANCOUNT=1 */
    .byte 0x00, 0x00
    .byte 0x00, 0x00
    /* Question for qemu.local */
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01
    .byte 0x00, 0x01
    /* Answer for qemu.local (inlined, not compressed) */
    .byte 4
    .ascii "qemu"
    .byte 5
    .ascii "local"
    .byte 0
    .byte 0x00, 0x01
    .byte 0x80, 0x01
    .byte 0x00, 0x00, 0x00, 0x78
    .byte 0x00, 0x04
    .byte 0xc0, 0xa8, 0x01, 0x2a
.equ _mdns_conflict_with_q_len, (. - _mdns_conflict_with_q)


.section .bss
.balign 8
_mdns_resp_buf:
    .space 256

.balign 8
_mdns_save_buf:
    .space 80                   /* 64 hostname + 4 len + 4 ip + 8 pad */

/* Writable scratch frame for mdns_dispatch — copied from .rodata
 * synthetic frames at test setup, then mdns_dispatch rewrites in
 * place. ETH_FRAME_MAX is 1514; round to a power of two. */
.balign 8
_mdns_frame_buf:
    .space 256

/* State-machine test fixtures. */
.balign 8
_mdns_send_count:
    .space 4
.balign 8
_mdns_last_frame:
    .space 8                    /* captured frame ptr */
    .space 8                    /* captured len (4) + pad */

.balign 8
_mdns_test_tpool:
    .space 520                  /* 8 + 8*32 = 264 minimum; 520 = TPOOL_DEFAULT_SIZE */

.balign 8
_mdns_panic_count:
    .space 4
