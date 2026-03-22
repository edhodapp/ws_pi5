/*
 * test_bp_all.S — Aggregate all BeaglePlay platform-specific driver tests
 *
 * Provides test_platform_drivers (overrides weak default in test_main.S).
 * Called once from the shared test runner.
 */

.section .text

.global test_platform_drivers
test_platform_drivers:
    stp     x29, x30, [sp, #-16]!

    /* CPSW MDIO */
    bl      test_mdio_init_success
    bl      test_mdio_init_timeout
    bl      test_mdio_read_success
    bl      test_mdio_read_timeout
    bl      test_mdio_read_nack
    bl      test_mdio_write_success
    bl      test_mdio_write_timeout
    bl      test_mdio_link_up
    bl      test_mdio_link_down
    bl      test_mdio_phy_alive
    bl      test_mdio_phy_not_alive
    bl      test_mdio_read_field_encoding
    bl      test_mdio_write_field_encoding

    ldp     x29, x30, [sp], #16
    ret
