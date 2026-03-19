.section .text._start

.global _start
.global test_count
.global fail_count

_start:
    /* Only let core 0 proceed */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbnz    x0, .Lpark

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

    bl      uart_init

    ldr     x0, =msg_test_start
    bl      uart_puts

    /* === Run test suites === */
    bl      test_example
    bl      test_vmio_queue
    bl      test_vmio_engine
    bl      test_mailbox
    bl      test_mbox_response_fail
    bl      test_dwc2
    bl      test_dwc2_timeout
    bl      test_usb_enum
    bl      test_dwc2_mbox_fail
    bl      test_dwc2_xfer_timeout
    bl      test_usb_xfer_setup_fail
    bl      test_usb_xfer_data_fail
    bl      test_usb_xfer_status_fail
    bl      test_usb_enum_set_addr_fail
    bl      test_usb_enum_get_full_fail
    bl      test_usb_xfer_out_data
    bl      test_parse_bulk_eps
    bl      test_parse_no_bulk
    bl      test_parse_zero_blength
    bl      test_get_config_desc
    bl      test_parse_overrun
    bl      test_gcd_pass1_fail
    bl      test_gcd_pass2_fail
    bl      test_gcd_clamp
    bl      test_cdc_ecm_init
    bl      test_cdc_ecm_enum_fail
    bl      test_cdc_ecm_cfg_fail
    bl      test_cdc_ecm_no_bulk
    bl      test_cdc_ecm_set_cfg_fail
    bl      test_bulk_xfer_out
    bl      test_bulk_xfer_in
    bl      test_bulk_xfer_fail
    bl      test_ecm_activate
    bl      test_ecm_activate_fail
    bl      test_ecm_send
    bl      test_ecm_recv
    bl      test_main_success
    bl      test_main_dwc2_fail
    bl      test_main_ecm_init_fail
    bl      test_main_ecm_activate_fail
    bl      test_eth_type_arp
    bl      test_eth_type_short
    bl      test_eth_build_hdr
    bl      test_eth_mac_eq
    bl      test_arp_request_for_us
    bl      test_arp_request_other_ip
    bl      test_arp_reply_ignored
    bl      test_arp_truncated
    bl      test_ip_checksum
    bl      test_ip_checksum_carry
    bl      test_icmp_echo_reply
    bl      test_icmp_not_echo
    bl      test_icmp_short
    bl      test_ip_handle_icmp
    bl      test_ip_handle_short
    bl      test_ip_handle_bad_cksum
    bl      test_ip_handle_not_ours
    bl      test_ip_handle_unknown_proto
    bl      test_ip_handle_bad_ver
    bl      test_ip_handle_totlen_short
    bl      test_ip_handle_totlen_overrun
    bl      test_net_recv_arp
    bl      test_net_recv_icmp
    bl      test_net_recv_unknown
    bl      test_net_recv_short

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
