// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Testbench drivers for the X-HEEP pad protocols.
//
// Every driver is always instantiated. Which ones actually see the DUT pads
// is decided at run time by vinterconnect (+tb_route). Drivers expose plain
// input/output/output-enable signals; tristate resolution happens in
// vinterconnect.
//
// tb_top talks to the drivers through hierarchical calls:
//   jtag_i.load_firmware()  - JTAG boot
//   flash_i.load()          - flash boot / flash contents
//   final_check()           - collects the driver verdicts at end of test

module vdrivers #(
    parameter int unsigned CLK_FREQUENCY = 'd100_000  // kHz
) (
    input logic clk_i,
    input logic rst_ni,

    // JTAG
    output logic jtag_tck_o,
    output logic jtag_tms_o,
    output logic jtag_tdi_o,
    output logic jtag_trst_no,
    input  logic jtag_tdo_i,

    // UART
    input  logic uart_rx_i,  // DUT uart_tx
    output logic uart_tx_o,  // DUT uart_rx

    // Boot SPI flash
    input  logic       flash_sck_i,
    input  logic       flash_csb_i,
    input  logic [3:0] flash_sd_i,
    output logic [3:0] flash_sd_o,
    output logic [3:0] flash_sd_oe,

    // SPI target on the spi_host pads
    input  logic       spi_sck_i,
    input  logic       spi_csb_i,
    input  logic [3:0] spi_sd_i,
    output logic [3:0] spi_sd_o,
    output logic [3:0] spi_sd_oe,

    // SPI target on the spi2 pads
    input  logic       spi2_sck_i,
    input  logic       spi2_csb_i,
    input  logic [3:0] spi2_sd_i,
    output logic [3:0] spi2_sd_o,
    output logic [3:0] spi2_sd_oe,

    // GPIO
    input  logic [31:0] gpio_i,
    output logic [31:0] gpio_o,
    output logic [31:0] gpio_oe,

    // I2C
    input  logic i2c_scl_i,
    input  logic i2c_sda_i,
    output logic i2c_sda_oe_o,

    // I2S microphone
    input  logic i2s_sck_i,
    input  logic i2s_ws_i,
    output logic i2s_sd_o,

    // PDM microphone
    input  logic pdm_clk_i,
    output logic pdm_data_o
);

  vdrv_jtag jtag_i (
      .tck_o  (jtag_tck_o),
      .tms_o  (jtag_tms_o),
      .tdi_o  (jtag_tdi_o),
      .trst_no(jtag_trst_no),
      .tdo_i  (jtag_tdo_i)
  );

  vdrv_uart #(
      .CLK_FREQUENCY(CLK_FREQUENCY)
  ) uart_i (
      .rst_ni,
      .rx_i(uart_rx_i),
      .tx_o(uart_tx_o)
  );

  vdrv_spi_mem #(
      .NAME("FLASH")
  ) flash_i (
      .sck_i(flash_sck_i),
      .csb_i(flash_csb_i),
      .sd_i (flash_sd_i),
      .sd_o (flash_sd_o),
      .sd_oe(flash_sd_oe)
  );

  vdrv_spi_mem #(
      .NAME("SPI_HOST_MEM")
  ) spi_mem_i (
      .sck_i(spi_sck_i),
      .csb_i(spi_csb_i),
      .sd_i (spi_sd_i),
      .sd_o (spi_sd_o),
      .sd_oe(spi_sd_oe)
  );

  vdrv_spi_mem #(
      .NAME("SPI2_MEM")
  ) spi2_mem_i (
      .sck_i(spi2_sck_i),
      .csb_i(spi2_csb_i),
      .sd_i (spi2_sd_i),
      .sd_o (spi2_sd_o),
      .sd_oe(spi2_sd_oe)
  );

  vdrv_gpio gpio_drv_i (
      .rst_ni,
      .gpio_i,
      .gpio_o,
      .gpio_oe
  );

  vdrv_i2c i2c_i (
      .rst_ni,
      .scl_i   (i2c_scl_i),
      .sda_i   (i2c_sda_i),
      .sda_oe_o(i2c_sda_oe_o)
  );

  i2s_microphone i2s_mic_i (
      .rst_ni,
      .i2s_sck_i(i2s_sck_i),
      .i2s_ws_i (i2s_ws_i),
      .i2s_sd_o (i2s_sd_o)
  );

  pdm2pcm_dummy pdm_mic_i (
      .clk_i,
      .rst_ni,
      .pdm_clk_i (pdm_clk_i),
      .pdm_data_o(pdm_data_o)
  );

  // Called by tb_top at the end of the test. Errors go to the tb_pkg
  // scoreboard.
  function automatic void final_check();
    uart_i.final_check();
    gpio_drv_i.final_check();
    i2c_i.final_check();
  endfunction

endmodule
