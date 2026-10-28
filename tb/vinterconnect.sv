// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Testbench pad interconnect.
//
// Connects the X-HEEP pads to the drivers in vdrivers. Dedicated pads (JTAG, UART,
// boot flash) are always connected. Shared pads are connected at run time
// according to +tb_route=<route>[,<route>...] (see tb_pkg::route_e); a pad
// claimed by two routes is a configuration error. The GPIO route takes every
// GPIO pad left unclaimed by the other routes.
//
// Every pad has a pull-up or pull-down so that undriven pads have a defined
// value: pull-ups on I2C, UART, JTAG TMS/TRST and chip selects, pull-downs
// elsewhere. The pads come in two nets, one per pull direction (see
// tb_pads_pkg).

module vinterconnect
  import tb_pads_pkg::*;
(
    inout wire [NUM_PU_PADS-1:0] pad_pu_io,
    inout wire [NUM_PD_PADS-1:0] pad_pd_io,

    // JTAG driver
    input  logic jtag_tck_i,
    input  logic jtag_tms_i,
    input  logic jtag_tdi_i,
    input  logic jtag_trst_ni,
    output logic jtag_tdo_o,

    // UART driver
    output logic uart_rx_o,  // DUT uart_tx
    input  logic uart_tx_i,  // DUT uart_rx

    // Boot flash driver
    output logic       flash_sck_o,
    output logic       flash_csb_o,
    output logic [3:0] flash_sd_o,
    input  logic [3:0] flash_sd_i,
    input  logic [3:0] flash_sd_oe_i,

    // SPI target on the spi_host pads
    output logic       spi_sck_o,
    output logic       spi_csb_o,
    output logic [3:0] spi_sd_o,
    input  logic [3:0] spi_sd_i,
    input  logic [3:0] spi_sd_oe_i,

    // SPI target on the spi2 pads
    output logic       spi2_sck_o,
    output logic       spi2_csb_o,
    output logic [3:0] spi2_sd_o,
    input  logic [3:0] spi2_sd_i,
    input  logic [3:0] spi2_sd_oe_i,

    // GPIO driver
    output logic [31:0] gpio_o,
    input  logic [31:0] gpio_i,
    input  logic [31:0] gpio_oe_i,

    // I2C driver
    output logic i2c_scl_o,
    output logic i2c_sda_o,
    input  logic i2c_sda_oe_i,

    // I2S microphone driver
    output logic i2s_sck_o,
    output logic i2s_ws_o,
    input  logic i2s_sd_rx_i,

    // PDM microphone driver
    output logic pdm_clk_o,
    input  logic pdm_data_i
);

  import tb_pkg::*;

  localparam string NAME = "VINTERCONNECT";

  // Pads at index < 0 are not part of the pad configuration. pidx() keeps the
  // index in range for the (dead) code that references them.
  function automatic int pidx(int p);
    return p < 0 ? 0 : p;
  endfunction

  `define PAD_DRV(PAD, VAL, OE) \
    if ((PAD) >= 0) begin pad_o[pidx(PAD)] = (VAL); pad_oe[pidx(PAD)] = (OE); end
  `define PAD_IN(PAD, DFLT) (((PAD) >= 0) ? pad_v[pidx(PAD)] : (DFLT))

  // ---------------------------------------------------------------------------
  // Pulls
  // ---------------------------------------------------------------------------
  for (genvar k = 0; k < NUM_PU_PADS; k++) begin : gen_pullup
    pullup (pad_pu_io[k]);
  end

  for (genvar k = 0; k < NUM_PD_PADS; k++) begin : gen_pulldown
    pulldown (pad_pd_io[k]);
  end

  // ---------------------------------------------------------------------------
  // Routing table
  // ---------------------------------------------------------------------------
  route_mask_t route;
  int owner[NUM_PADS];
  logic [31:0] gpio_routed;

  function automatic void route_pads(route_e r, ref int pads[$]);
    case (r)
      ROUTE_I2C: pads = '{PAD_I2C_SCL, PAD_I2C_SDA};
      ROUTE_SPI_HOST:
      pads = '{
          PAD_SPI_SCK,
          PAD_SPI_CS_0,
          PAD_SPI_CS_1,
          PAD_SPI_SD_0,
          PAD_SPI_SD_1,
          PAD_SPI_SD_2,
          PAD_SPI_SD_3
      };
      ROUTE_SPI2:
      pads = '{
          PAD_SPI2_SCK,
          PAD_SPI2_CS_0,
          PAD_SPI2_CS_1,
          PAD_SPI2_SD_0,
          PAD_SPI2_SD_1,
          PAD_SPI2_SD_2,
          PAD_SPI2_SD_3
      };
      ROUTE_SPI_SLAVE:
      pads = '{
          PAD_SPI_SCK,
          PAD_SPI_CS_0,
          PAD_SPI_SD_0,
          PAD_SPI_SD_1,
          PAD_SPI_SLAVE_SCK,
          PAD_SPI_SLAVE_CS,
          PAD_SPI_SLAVE_MISO,
          PAD_SPI_SLAVE_MOSI
      };
      ROUTE_I2S: pads = '{PAD_I2S_SCK, PAD_I2S_WS, PAD_I2S_SD_RX, PAD_I2S_SD_TX};
      ROUTE_PDM2PCM: pads = '{PAD_PDM2PCM_PDM, PAD_PDM2PCM_CLK};
      default: pads.delete();
    endcase
  endfunction

  initial begin
    int pads[$];
    string routed = "";
    route = get_routes();
    foreach (owner[k]) owner[k] = -1;
    for (int r = 0; r < NUM_ROUTES; r++) begin
      if (!route[r] || r == ROUTE_GPIO) continue;
      routed = {routed, " ", route_name(route_e'(r))};
      route_pads(route_e'(r), pads);
      foreach (pads[i]) begin
        if (pads[i] < 0) begin
          tb_error(NAME, $sformatf(
                   "route %s uses a pad missing from the pad configuration", route_name(route_e'(r))
                   ));
        end else if (owner[pads[i]] >= 0) begin
          tb_error(NAME, $sformatf(
                   "pad %s claimed by routes %s and %s",
                   PAD_NAME[pads[i]],
                   route_name(
                       route_e'(owner[pads[i]])
                   ),
                   route_name(
                       route_e'(r)
                   )
                   ));
        end else begin
          owner[pads[i]] = r;
        end
      end
    end
    gpio_routed = '0;
    if (route[ROUTE_GPIO]) begin
      routed = {routed, " gpio"};
      for (int g = 0; g < 32; g++) begin
        if (GPIO_PAD[g] >= 0 && owner[pidx(GPIO_PAD[g])] < 0) begin
          owner[pidx(GPIO_PAD[g])] = ROUTE_GPIO;
          gpio_routed[g] = 1'b1;
        end
      end
    end
    tb_info(NAME, $sformatf("routes:%s", routed.len() > 0 ? routed : " none"));
    if (route[ROUTE_GPIO])
      tb_info(NAME, $sformatf("GPIOs routed to the GPIO driver: 0x%08h", gpio_routed));
  end

  // ---------------------------------------------------------------------------
  // Pad drivers
  // ---------------------------------------------------------------------------
  logic [NUM_PADS-1:0] pad_o, pad_oe, pad_v;

  for (genvar k = 0; k < NUM_PADS; k++) begin : gen_pad_drv
    if (PAD_PULLUP[k]) begin : gen_pu
      assign pad_pu_io[PAD_GRP_IDX[k]] = pad_oe[k] ? pad_o[k] : 1'bz;
      assign pad_v[k] = pad_pu_io[PAD_GRP_IDX[k]];
    end else begin : gen_pd
      assign pad_pd_io[PAD_GRP_IDX[k]] = pad_oe[k] ? pad_o[k] : 1'bz;
      assign pad_v[k] = pad_pd_io[PAD_GRP_IDX[k]];
    end
  end

  /* verilator lint_off UNOPTFLAT */
  always_comb begin
    pad_o  = '0;
    pad_oe = '0;

    // JTAG
    `PAD_DRV(PAD_JTAG_TCK, jtag_tck_i, 1'b1)
    `PAD_DRV(PAD_JTAG_TMS, jtag_tms_i, 1'b1)
    `PAD_DRV(PAD_JTAG_TDI, jtag_tdi_i, 1'b1)
    `PAD_DRV(PAD_JTAG_TRST, jtag_trst_ni, 1'b1)
    jtag_tdo_o = `PAD_IN(PAD_JTAG_TDO, 1'b0);

    // UART
    `PAD_DRV(PAD_UART_RX, uart_tx_i, 1'b1)
    uart_rx_o = `PAD_IN(PAD_UART_TX, 1'b1);

    // Boot flash
    flash_sck_o = `PAD_IN(PAD_SPI_FLASH_SCK, 1'b0);
    flash_csb_o = `PAD_IN(PAD_SPI_FLASH_CS_0, 1'b1);
    flash_sd_o = {
      `PAD_IN(PAD_SPI_FLASH_SD_3, 1'b0),
      `PAD_IN(PAD_SPI_FLASH_SD_2, 1'b0),
      `PAD_IN(PAD_SPI_FLASH_SD_1, 1'b0),
      `PAD_IN(PAD_SPI_FLASH_SD_0, 1'b0)
    };
    `PAD_DRV(PAD_SPI_FLASH_SD_0, flash_sd_i[0], flash_sd_oe_i[0])
    `PAD_DRV(PAD_SPI_FLASH_SD_1, flash_sd_i[1], flash_sd_oe_i[1])
    `PAD_DRV(PAD_SPI_FLASH_SD_2, flash_sd_i[2], flash_sd_oe_i[2])
    `PAD_DRV(PAD_SPI_FLASH_SD_3, flash_sd_i[3], flash_sd_oe_i[3])

    // SPI host -> SPI memory
    spi_sck_o = 1'b0;
    spi_csb_o = 1'b1;
    spi_sd_o  = '0;
    if (route[ROUTE_SPI_HOST]) begin
      spi_sck_o = `PAD_IN(PAD_SPI_SCK, 1'b0);
      spi_csb_o = `PAD_IN(PAD_SPI_CS_0, 1'b1);
      spi_sd_o = {
        `PAD_IN(PAD_SPI_SD_3, 1'b0),
        `PAD_IN(PAD_SPI_SD_2, 1'b0),
        `PAD_IN(PAD_SPI_SD_1, 1'b0),
        `PAD_IN(PAD_SPI_SD_0, 1'b0)
      };
      `PAD_DRV(PAD_SPI_SD_0, spi_sd_i[0], spi_sd_oe_i[0])
      `PAD_DRV(PAD_SPI_SD_1, spi_sd_i[1], spi_sd_oe_i[1])
      `PAD_DRV(PAD_SPI_SD_2, spi_sd_i[2], spi_sd_oe_i[2])
      `PAD_DRV(PAD_SPI_SD_3, spi_sd_i[3], spi_sd_oe_i[3])
    end

    // SPI2 -> SPI memory
    spi2_sck_o = 1'b0;
    spi2_csb_o = 1'b1;
    spi2_sd_o  = '0;
    if (route[ROUTE_SPI2]) begin
      spi2_sck_o = `PAD_IN(PAD_SPI2_SCK, 1'b0);
      spi2_csb_o = `PAD_IN(PAD_SPI2_CS_0, 1'b1);
      spi2_sd_o = {
        `PAD_IN(PAD_SPI2_SD_3, 1'b0),
        `PAD_IN(PAD_SPI2_SD_2, 1'b0),
        `PAD_IN(PAD_SPI2_SD_1, 1'b0),
        `PAD_IN(PAD_SPI2_SD_0, 1'b0)
      };
      `PAD_DRV(PAD_SPI2_SD_0, spi2_sd_i[0], spi2_sd_oe_i[0])
      `PAD_DRV(PAD_SPI2_SD_1, spi2_sd_i[1], spi2_sd_oe_i[1])
      `PAD_DRV(PAD_SPI2_SD_2, spi2_sd_i[2], spi2_sd_oe_i[2])
      `PAD_DRV(PAD_SPI2_SD_3, spi2_sd_i[3], spi2_sd_oe_i[3])
    end

    // SPI host looped back to the debug SPI slave
    if (route[ROUTE_SPI_SLAVE]) begin
      `PAD_DRV(PAD_SPI_SLAVE_SCK, `PAD_IN(PAD_SPI_SCK, 1'b0), 1'b1)
      `PAD_DRV(PAD_SPI_SLAVE_CS, `PAD_IN(PAD_SPI_CS_0, 1'b1), 1'b1)
      `PAD_DRV(PAD_SPI_SLAVE_MOSI, `PAD_IN(PAD_SPI_SD_0, 1'b0), 1'b1)
      `PAD_DRV(PAD_SPI_SD_1, `PAD_IN(PAD_SPI_SLAVE_MISO, 1'b0), 1'b1)
    end

    // I2C (open drain, pulled up)
    i2c_scl_o = 1'b1;
    i2c_sda_o = 1'b1;
    if (route[ROUTE_I2C]) begin
      i2c_scl_o = `PAD_IN(PAD_I2C_SCL, 1'b1);
      i2c_sda_o = `PAD_IN(PAD_I2C_SDA, 1'b1);
      `PAD_DRV(PAD_I2C_SDA, 1'b0, i2c_sda_oe_i)
    end

    // I2S
    i2s_sck_o = 1'b0;
    i2s_ws_o  = 1'b0;
    if (route[ROUTE_I2S]) begin
      i2s_sck_o = `PAD_IN(PAD_I2S_SCK, 1'b0);
      i2s_ws_o  = `PAD_IN(PAD_I2S_WS, 1'b0);
      `PAD_DRV(PAD_I2S_SD_RX, i2s_sd_rx_i, 1'b1)
    end

    // PDM
    pdm_clk_o = 1'b0;
    if (route[ROUTE_PDM2PCM]) begin
      pdm_clk_o = `PAD_IN(PAD_PDM2PCM_CLK, 1'b0);
      `PAD_DRV(PAD_PDM2PCM_PDM, pdm_data_i, 1'b1)
    end

    // GPIO: every GPIO pad not claimed by another route
    for (int g = 0; g < 32; g++) begin
      gpio_o[g] = 1'b0;
      if (gpio_routed[g]) begin
        gpio_o[g] = pad_v[pidx(GPIO_PAD[g])];
        pad_o[pidx(GPIO_PAD[g])] = gpio_i[g];
        pad_oe[pidx(GPIO_PAD[g])] = gpio_oe_i[g];
      end
    end
  end
  /* verilator lint_on UNOPTFLAT */

  `undef PAD_DRV
  `undef PAD_IN

endmodule
