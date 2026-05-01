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

.section .text

/* Set net_hostname to "qemu" / len 4 / net_our_ip to 10.0.2.15.
 * Caller must have already saved these via _mdns_test_save. */
_mdns_test_set_state:
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
