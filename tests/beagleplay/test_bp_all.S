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

    /* CPSW Port / ALE */
    bl      test_nu_init_ctl_reg
    bl      test_nu_init_stat_ptype
    bl      test_port_init_host_maxlen
    bl      test_port_init_host_flowid
    bl      test_port_init_ext_maxlen
    bl      test_port_init_ext_mac
    bl      test_macsl_reset_success
    bl      test_macsl_reset_timeout
    bl      test_macsl_config_1000
    bl      test_macsl_config_100
    bl      test_macsl_config_10
    bl      test_macsl_config_unknown
    bl      test_ale_init_ctl
    bl      test_ale_init_port_modes
    bl      test_port_init_mac_encoding

    ldp     x29, x30, [sp], #16
    ret
