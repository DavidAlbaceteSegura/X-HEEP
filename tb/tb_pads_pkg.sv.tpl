// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Testbench view of the X-HEEP pad ring: one index per digital pad of
// x_heep_system, plus the pad index of every pin (muxed pins share the index
// of their pad). Generated from the pad configuration, do not edit.

<%!
    from pads.pin import Input, Output, Inout
%>
<%
    tb_pads = []
    for pad in xheep.get_padring().pad_list:
        if any(isinstance(pin, (Input, Output, Inout)) for pin in pad.pins):
            tb_pads.append(pad)
    pin_pad = {}
    for idx, pad in enumerate(tb_pads):
        for pin in pad.pins:
            pin_pad[pin.name] = idx
    # Pins referenced by vinterconnect. They get an index of -1 when they are
    # not part of the pad configuration so that the testbench still compiles.
    known_pins = ["clk", "rst", "boot_select", "exit_valid",
                  "jtag_tck", "jtag_tms", "jtag_trst", "jtag_tdi", "jtag_tdo",
                  "uart_rx", "uart_tx",
                  "spi_flash_sck", "spi_flash_cs_0", "spi_flash_cs_1",
                  "spi_flash_sd_0", "spi_flash_sd_1", "spi_flash_sd_2", "spi_flash_sd_3",
                  "spi_sck", "spi_cs_0", "spi_cs_1",
                  "spi_sd_0", "spi_sd_1", "spi_sd_2", "spi_sd_3",
                  "spi_slave_sck", "spi_slave_cs", "spi_slave_miso", "spi_slave_mosi",
                  "pdm2pcm_pdm", "pdm2pcm_clk",
                  "i2s_sck", "i2s_ws", "i2s_sd_rx", "i2s_sd_tx",
                  "spi2_cs_0", "spi2_cs_1", "spi2_sck",
                  "spi2_sd_0", "spi2_sd_1", "spi2_sd_2", "spi2_sd_3",
                  "i2c_scl", "i2c_sda",
                  "ddr_rcv_clk", "ddr_snd_clk",
                  "ddr_rcv_0", "ddr_rcv_1", "ddr_rcv_2", "ddr_rcv_3",
                  "ddr_snd_0", "ddr_snd_1", "ddr_snd_2", "ddr_snd_3"] + \
                 [f"gpio_{i}" for i in range(32)]
    all_pins = list(pin_pad.keys()) + [p for p in known_pins if p not in pin_pad]
    # Pull direction of every pad. Keep in sync with testharness.sv.tpl.
    def is_pullup(pad):
        return any(pin.name in ("i2c_scl", "i2c_sda", "uart_rx", "uart_tx", "jtag_tms", "jtag_trst")
                   or "_cs" in pin.name for pin in pad.pins)
    pullup = [is_pullup(pad) for pad in tb_pads]
    grp_idx = []
    n_pu = n_pd = 0
    for pu in pullup:
        grp_idx.append(n_pu if pu else n_pd)
        if pu:
            n_pu += 1
        else:
            n_pd += 1
%>
package tb_pads_pkg;

  localparam int unsigned NUM_PADS = ${len(tb_pads)};

  // Pad index of every pin
% for name in all_pins:
  localparam int PAD_${name.upper()} = ${pin_pad.get(name, -1)};
% endfor

  // Pad index of GPIO n (-1 if the GPIO is not bonded out)
  localparam int GPIO_PAD[32] = '{
% for i in range(32):
      ${pin_pad.get(f"gpio_{i}", -1)}${"" if loop.last else ","}
% endfor
  };

  // Pads are split in two nets, one per pull direction (Verilator does not
  // support mixed pulls on the same net). PAD_GRP_IDX is the index of the pad
  // in its net.
  localparam int unsigned NUM_PU_PADS = ${n_pu};
  localparam int unsigned NUM_PD_PADS = ${n_pd};
  localparam bit PAD_PULLUP[NUM_PADS] = '{${", ".join("1" if pu else "0" for pu in pullup)}};
  localparam int PAD_GRP_IDX[NUM_PADS] = '{${", ".join(str(i) for i in grp_idx)}};

  // Pad names, for logging
  localparam string PAD_NAME[NUM_PADS] = '{
% for pad in tb_pads:
      "${"/".join(pin.name for pin in pad.pins)}"${"" if loop.last else ","}
% endfor
  };

endpackage
