/*
 * test_pi_all.S — Aggregate all Pi platform-specific driver tests
 *
 * Provides test_platform_drivers (overrides weak default in test_main.S).
 * Called once from the shared test runner.
 */

.section .text

.global test_platform_drivers
test_platform_drivers:
    stp     x29, x30, [sp, #-16]!

    /* GPIO */
    bl      test_gpio_pin4_alt4
    bl      test_gpio_pin5_alt4
    bl      test_gpio_pin14_output
    bl      test_gpio_no_clobber
    bl      test_gpio_pin0_input

    /* Mailbox */
    bl      test_mailbox
    bl      test_mbox_response_fail

    /* DWC2 USB host */
    bl      test_dwc2
    bl      test_dwc2_timeout
    bl      test_dwc2_mbox_fail
    bl      test_dwc2_xfer_timeout

    /* USB enumeration */
    bl      test_usb_enum
    bl      test_usb_xfer_setup_fail
    bl      test_usb_xfer_data_fail
    bl      test_usb_xfer_status_fail
    bl      test_usb_enum_set_addr_fail
    bl      test_usb_enum_get_full_fail
    bl      test_usb_xfer_out_data

    /* USB descriptor parsing */
    bl      test_parse_bulk_eps
    bl      test_parse_no_bulk
    bl      test_parse_zero_blength
    bl      test_get_config_desc
    bl      test_parse_overrun
    bl      test_gcd_pass1_fail
    bl      test_gcd_pass2_fail
    bl      test_gcd_clamp

    /* CDC-ECM */
    bl      test_cdc_ecm_init
    bl      test_cdc_ecm_enum_fail
    bl      test_cdc_ecm_cfg_fail
    bl      test_cdc_ecm_no_bulk
    bl      test_cdc_ecm_set_cfg_fail

    /* USB bulk transfers */
    bl      test_bulk_xfer_out
    bl      test_bulk_xfer_in
    bl      test_bulk_xfer_fail

    /* ECM activate/send/recv */
    bl      test_ecm_activate
    bl      test_ecm_activate_fail
    bl      test_ecm_send
    bl      test_ecm_recv

    /* Boot/main integration */
    bl      test_main_success
    bl      test_main_dwc2_fail
    bl      test_main_ecm_init_fail
    bl      test_main_ecm_activate_fail

    ldp     x29, x30, [sp], #16
    ret
