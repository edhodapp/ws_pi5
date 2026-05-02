/*
 * Weak default for test_platform_drivers — overridden by
 * tests/pi/test_pi_all.S
 * when the platform's test objects are linked.
 */
.weak test_platform_drivers

.section .text._start

.global _start
.global test_count
.global fail_count

_start:
    /* Only let core 0 proceed */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

    /* Drop from EL2 to EL1 if needed (Pi 4 / QEMU 10 boots at EL2) */
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    .Lel1_ready

    mrs     x0, HCR_EL2
    orr     x0, x0, #(1 << 31)
    msr     HCR_EL2, x0
    mov     x0, #3
    msr     CNTHCTL_EL2, x0
    msr     CNTVOFF_EL2, xzr
    mov     x0, #0x33FF
    msr     CPTR_EL2, x0
    mov     x0, #0x3C5
    msr     SPSR_EL2, x0
    adr     x0, .Lel1_ready
    msr     ELR_EL2, x0
    eret

.Lel1_ready:
    /* Set up stack */
    ldr     x0, =_stack_top
    mov     sp, x0

    /* Zero BSS */
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.ge    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    /* --- MMU setup: identity map, Normal RAM + Device peripherals --- */

    /* MAIR: attr0 = Normal WB (0xFF), attr1 = Device-nGnRnE (0x00) */
    mov     x0, #0xFF
    msr     MAIR_EL1, x0

    /* TCR: T0SZ=32 (4 GB VA), 4KB granule, inner shareable, WB cache */
    ldr     x0, =0x80803520
    msr     TCR_EL1, x0

    /* Level 1: single entry → level 2 table */
    ldr     x0, =__mmu_l1_table
    ldr     x1, =__mmu_l2_table
    orr     x1, x1, #0x3           /* table descriptor: valid + table */
    str     x1, [x0]

    /* Level 2: 512 × 2MB block entries covering 0x00000000 - 0x3FFFFFFF */
    ldr     x0, =__mmu_l2_table
    mov     x1, #0                 /* physical address */
    mov     x2, #0x701             /* Normal: AF | SH=inner | AttrIdx=0 | block */
    mov     x3, #0x405             /* Device: AF | AttrIdx=1 | block */
    mov     w4, #0

.Lfill_normal:
    orr     x5, x1, x2
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #504               /* 504 = 0x3F000000 / 2MB (peripheral boundary) */
    b.lt    .Lfill_normal

.Lfill_device:
    orr     x5, x1, x3
    str     x5, [x0, x4, lsl #3]
    add     x1, x1, #0x200000
    add     w4, w4, #1
    cmp     w4, #512
    b.lt    .Lfill_device

    /* Set translation table base */
    ldr     x0, =__mmu_l1_table
    msr     TTBR0_EL1, x0
    isb

    /* Enable MMU + data cache + instruction cache */
    mrs     x0, SCTLR_EL1
    orr     x0, x0, #(1 << 0)     /* M: MMU enable */
    orr     x0, x0, #(1 << 2)     /* C: data cache */
    orr     x0, x0, #(1 << 12)    /* I: instruction cache */
    msr     SCTLR_EL1, x0
    isb

    bl      uart_init

    ldr     x0, =msg_test_start
    bl      uart_puts

    /* === Run test suites === */
    bl      test_example
    bl      test_vmio_queue
    bl      test_vmio_engine
    bl      test_http_output_fsa
    bl      test_store
    bl      test_platform_drivers
    bl      test_config_parse_valid
    bl      test_config_parse_bad_magic
    bl      test_config_parse_eof_midstream
    bl      test_config_parse_with_mac
    bl      test_config_parse_vectors
    bl      test_mdns_a_query_match
    bl      test_mdns_a_query_no_match
    bl      test_mdns_aaaa_query_drop
    bl      test_mdns_dispatch_a_match
    bl      test_mdns_dispatch_no_reply
    bl      test_mdns_net_recv_e2e
    bl      test_mdns_build_probe
    bl      test_mdns_build_probe_frame
    bl      test_mdns_build_probe_frame_empty
    bl      test_mdns_conflict_match
    bl      test_mdns_conflict_other_name
    bl      test_mdns_conflict_query_qr0
    bl      test_mdns_conflict_no_answer
    bl      test_mdns_conflict_short
    bl      test_mdns_conflict_compressed_name
    bl      test_mdns_conflict_with_question
    bl      test_mdns_build_announce
    bl      test_mdns_build_announce_frame
    bl      test_mdns_build_announce_empty
    bl      test_mdns_state_initial
    bl      test_mdns_state_advance_one
    bl      test_mdns_state_full_sequence
    bl      test_mdns_state_first_send_is_probe
    bl      test_mdns_state_fourth_send_is_announce
    bl      test_mdns_state_live_noop
    bl      test_mdns_dispatch_drops_in_probe
    bl      test_mdns_dispatch_responds_in_announce
    bl      test_mdns_dispatch_panics_on_conflict
    bl      test_dhcp_fsa_step_init_start
    bl      test_dhcp_fsa_step_no_handler
    bl      test_dhcp_fsa_step_oob_event
    bl      test_dhcp_fsa_step_oob_state
    bl      test_dhcp_fsa_step_panic_d_runs
    bl      test_dhcp_start_populates_ctx_and_fires
    bl      test_dhcp_start_sends_discover_broadcast
    bl      test_dhcp_retrans_cb_fires_retry
    bl      test_dhcp_retrans_cb_fires_giveup
    bl      test_dhcp_offer_drives_request
    bl      test_dhcp_ack_commits_lease
    bl      test_dhcp_build_discover_header
    bl      test_dhcp_build_discover_options
    bl      test_dhcp_build_request_selecting_has_50_and_54
    bl      test_dhcp_build_request_renewing_uses_ciaddr
    bl      test_dhcp_parse_offer_minimal
    bl      test_dhcp_parse_ack_minimal
    bl      test_dhcp_parse_nak
    bl      test_dhcp_parse_xid_mismatch
    bl      test_dhcp_parse_short
    bl      test_dhcp_parse_bad_magic
    bl      test_dhcp_parse_bad_op
    bl      test_dhcp_parse_offer_missing_server_id
    bl      test_eth_type_arp
    bl      test_eth_type_short
    bl      test_eth_build_hdr
    bl      test_eth_mac_eq
    bl      test_eth_type_long
    bl      test_eth_type_802_3
    bl      test_arp_request_for_us
    bl      test_arp_request_other_ip
    bl      test_arp_reply_learned
    bl      test_arp_truncated
    bl      test_arp_spa_zero
    bl      test_arp_spa_broadcast
    bl      test_arp_spa_multicast
    bl      test_arp_reply_not_gw
    bl      test_arp_reply_not_ours
    bl      test_arp_bad_oper
    bl      test_arp_build_request
    bl      test_arp_build_req_unicast
    bl      test_arp_gw_mac_cache
    bl      test_arp_non_gw_no_cache
    bl      test_arp_timer_cb_send
    bl      test_arp_timer_cb_no_send
    bl      test_arp_bad_htype
    bl      test_arp_bad_hlen
    bl      test_arp_timer_cb_rearm
    bl      test_ip_checksum
    bl      test_ip_checksum_carry
    bl      test_icmp_echo_reply
    bl      test_icmp_not_echo
    bl      test_icmp_short
    bl      test_icmp_echo_payload
    bl      test_icmp_echo_payload_odd
    bl      test_icmp_unknown_type
    bl      test_icmp_bad_checksum
    bl      test_icmp_send_error
    bl      test_icmp_send_loop_suppress
    bl      test_icmp_send_no_ctx
    bl      test_icmp_rate_allow
    bl      test_icmp_rate_deny
    bl      test_icmp_rate_refill
    bl      test_icmp_err_send_denied
    bl      test_icmp_err_bcast_dst
    bl      test_icmp_err_mcast_dst
    bl      test_ip_handle_icmp
    bl      test_ip_handle_short
    bl      test_ip_handle_bad_cksum
    bl      test_ip_handle_not_ours
    bl      test_ip_handle_unknown_proto
    bl      test_ip_handle_bad_ver
    bl      test_ip_handle_totlen_short
    bl      test_ip_handle_totlen_overrun
    bl      test_ip_handle_ttl_zero
    bl      test_ip_handle_martian_src_zero
    bl      test_ip_handle_martian_src_loopback
    bl      test_ip_handle_martian_src_loopback_high
    bl      test_ip_handle_martian_src_self
    bl      test_ip_handle_martian_src_bcast
    bl      test_ip_handle_martian_src_mcast
    bl      test_ip_handle_frag_dispatch
    bl      test_ip_handle_udp
    bl      test_net_recv_arp
    bl      test_net_recv_icmp
    bl      test_net_recv_unknown
    bl      test_net_recv_short
    bl      test_net_recv_wrong_mac
    bl      test_net_recv_perf
    bl      test_udp
    bl      test_timer
    bl      test_ntp
    bl      test_ip_reasm_two_frags
    bl      test_ip_reasm_timeout
    bl      test_ip_reasm_timeout_icmp
    bl      test_ip_reasm_timeout_no_frag0
    bl      test_ip_reasm_big_complete
    bl      test_ip_reasm_overlap
    bl      test_ip_reasm_nonaligned
    bl      test_ip_reasm_min_ttl
    bl      test_md5
    bl      test_tcp
    bl      test_http
    bl      test_hex_parse
    bl      test_rx_err_basic
    bl      test_rx_err_null_perf
    bl      test_rx_err_cidx_wrap
    bl      test_rx_err_ridx_wrap
    bl      test_rx_err_preserves_other
    bl      test_rx_err_fi_mask_covers

    /* === Print summary === */
    ldr     x0, =fail_count
    ldr     w0, [x0]
    cbnz    w0, .Ltests_failed

    ldr     x0, =msg_all_passed
    bl      uart_puts
    b       .Ldone

.Ltests_failed:
    ldr     x0, =msg_tests_failed
    bl      uart_puts

.Ldone:
    /* Spin forever — QEMU will be killed by timeout */
.Lpark:
    wfe
    b       .Lpark

/*
 * test_pass - Record a passing test and print result
 * x0: pointer to test name string
 * Clobbers: x0-x2, x19, x30
 */
.global test_pass
test_pass:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0

    /* Increment test count */
    ldr     x0, =test_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    ldr     x0, =msg_pass
    bl      uart_puts
    mov     x0, x19
    bl      uart_puts
    ldr     x0, =msg_newline
    bl      uart_puts

    ldp     x19, x30, [sp], #16
    ret

/*
 * test_fail - Record a failing test and print result
 * x0: pointer to test name string
 * Clobbers: x0-x2, x19, x30
 */
.global test_fail
test_fail:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0

    /* Increment test and fail counts */
    ldr     x0, =test_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    ldr     x0, =fail_count
    ldr     w1, [x0]
    add     w1, w1, #1
    str     w1, [x0]

    ldr     x0, =msg_fail
    bl      uart_puts
    mov     x0, x19
    bl      uart_puts
    ldr     x0, =msg_newline
    bl      uart_puts

    ldp     x19, x30, [sp], #16
    ret

.section .data
test_count:     .word 0
fail_count:     .word 0

.section .rodata
msg_test_start:  .asciz "=== Running tests ===\r\n"
msg_pass:        .asciz "PASS: "
msg_fail:        .asciz "FAIL: "
msg_newline:     .asciz "\r\n"
msg_all_passed:  .asciz "ALL TESTS PASSED\r\n"
msg_tests_failed: .asciz "TESTS FAILED\r\n"
