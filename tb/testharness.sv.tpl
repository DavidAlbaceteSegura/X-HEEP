// Copyright 2022 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

`ifdef USE_UPF
import UPF::*;
`endif

<%!
  from pads.pin import Input, Output, Inout
%>
<%
  user_peripheral_domain = xheep.get_user_peripheral_domain()
  xif = xheep.xif()
  # Digital pads, in the same order as tb_pads_pkg
  tb_pads = [pad for pad in xheep.get_padring().pad_list
             if any(isinstance(pin, (Input, Output, Inout)) for pin in pad.pins)]
  # Pull direction of every pad. Keep in sync with tb_pads_pkg.sv.tpl.
  def is_pullup(pad):
      return any(pin.name in ("i2c_scl", "i2c_sda", "uart_rx", "uart_tx", "jtag_tms", "jtag_trst")
                 or "_cs" in pin.name for pin in pad.pins)
  pad_net = {}
  n_pu = n_pd = 0
  for idx, pad in enumerate(tb_pads):
      if is_pullup(pad):
          pad_net[idx] = f"pad_pu[{n_pu}]"
          n_pu += 1
      else:
          pad_net[idx] = f"pad_pd[{n_pd}]"
          n_pd += 1
  def pin_net(name):
      for idx, pad in enumerate(tb_pads):
          if any(pin.name == name for pin in pad.pins):
              return pad_net[idx]
      raise ValueError(f"pin {name} not in the pad configuration")
  pad_conns = []
  for idx, p in enumerate(tb_pads):
      has_in = any(isinstance(pin, Input) for pin in p.pins)
      has_out = any(isinstance(pin, Output) for pin in p.pins)
      has_inout = any(isinstance(pin, Inout) for pin in p.pins)
      suffix = "io" if has_inout or (has_in and has_out) else ("i" if has_in else "o")
      pad_conns.append(f".{p.pins[0].rtl_name()}{suffix}({pad_net[idx]})")
%>

// X-HEEP seen from its pads.
//
// X-HEEP only talks to the testbench through its pads: they are connected to
// the protocol drivers (vdrivers) by vinterconnect. Every other port of
// x_heep_system (external bus, peripheral and DMA ports, interrupts, CV-X-IF)
// is tied off here. The power-switch acknowledges are looped back with a
// delay so that power gating completes.
//
// clk, rst, boot_select and exit_valid are pads too: tb_top drives and
// observes them through this module's ports.

module testharness #(
    parameter CLK_FREQUENCY = 'd100_000  // kHz
) (
    input  wire clk_i,
    input  wire rst_ni,
    input  wire boot_select_i,
    output wire exit_valid_o
);

  `include "tb_util.svh"

  import core_v_mini_mcu_pkg::*;

  localparam int unsigned SWITCH_ACK_LATENCY = 15;
  localparam int unsigned EXT_DOMAINS_RND = core_v_mini_mcu_pkg::EXTERNAL_DOMAINS == 0 ? 1 :
      core_v_mini_mcu_pkg::EXTERNAL_DOMAINS;

  // ---------------------------------------------------------------------------
  // Pads
  // ---------------------------------------------------------------------------
  // Split by pull direction (see tb_pads_pkg), connected to the drivers by
  // vinterconnect.
  wire [tb_pads_pkg::NUM_PU_PADS-1:0] pad_pu;
  wire [tb_pads_pkg::NUM_PD_PADS-1:0] pad_pd;

  assign ${pin_net("clk")} = clk_i;
  assign ${pin_net("rst")} = rst_ni;
  assign ${pin_net("boot_select")} = boot_select_i;
  assign exit_valid_o = ${pin_net("exit_valid")};

  // ---------------------------------------------------------------------------
  // Tied-off interfaces
  // ---------------------------------------------------------------------------
  // CV-X-IF: no coprocessor is attached
% if xif != None:
  if_xif #(
      .X_NUM_RS   (${xif.x_num_rs}),
      .X_ID_WIDTH (${xif.x_id_width}),
      .X_MEM_WIDTH(${xif.x_mem_width}),
      .X_RFR_WIDTH(${xif.x_rfr_width}),
      .X_RFW_WIDTH(${xif.x_rfw_width}),
      .X_MISA     (${xif.x_misa})
  ) ext_if ();
% else:
  if_xif ext_if ();
% endif

  // Power switch emulation: each acknowledge follows its switch after
  // SWITCH_ACK_LATENCY cycles
  logic cpu_switch_n, periph_switch_n;
  logic [EXT_DOMAINS_RND-1:0] ext_switch_n;
  logic [SWITCH_ACK_LATENCY:0] cpu_switch_ack_n, periph_switch_ack_n;
  logic [SWITCH_ACK_LATENCY:0][EXT_DOMAINS_RND-1:0] ext_switch_ack_n;

  always_ff @(posedge clk_i) begin : power_switch_emulation
    cpu_switch_ack_n    <= {cpu_switch_ack_n[SWITCH_ACK_LATENCY-1:0], cpu_switch_n};
    periph_switch_ack_n <= {periph_switch_ack_n[SWITCH_ACK_LATENCY-1:0], periph_switch_n};
    ext_switch_ack_n    <= {ext_switch_ack_n[SWITCH_ACK_LATENCY-1:0], ext_switch_n};
  end

`ifdef USE_UPF
  initial begin
    $display("%t: All Power Supply ON", $time);
    supply_on("VDD", 1.2);
    supply_on("VSS", 0);
  end
`endif

  // ---------------------------------------------------------------------------
  // X-HEEP
  // ---------------------------------------------------------------------------
  x_heep_system x_heep_system_i (
      .hart_id_i                                   ('0),
      .xheep_instance_id_i                         ('0),
      .intr_vector_ext_i                           ('0),
      .intr_ext_peripheral_i                       (1'b0),
      .ext_xbar_master_req_i                       ('0),
      .ext_xbar_master_resp_o                      (),
      .ext_core_instr_req_o                        (),
      .ext_core_instr_resp_i                       ('0),
      .ext_core_data_req_o                         (),
      .ext_core_data_resp_i                        ('0),
      .ext_debug_master_req_o                      (),
      .ext_debug_master_resp_i                     ('0),
      .ext_dma_read_req_o                          (),
      .ext_dma_read_resp_i                         ('0),
      .ext_dma_write_req_o                         (),
      .ext_dma_write_resp_i                        ('0),
      .ext_dma_addr_req_o                          (),
      .ext_dma_addr_resp_i                         ('0),
      .hw_fifo_req_o                               (),
      .hw_fifo_resp_i                              ('0),
      .ext_ao_peripheral_req_i                     ('0),
      .ext_ao_peripheral_resp_o                    (),
      .ext_peripheral_slave_req_o                  (),
      .ext_peripheral_slave_resp_i                 ('0),
      .cpu_subsystem_powergate_switch_no           (cpu_switch_n),
      .cpu_subsystem_powergate_switch_ack_ni       (cpu_switch_ack_n[SWITCH_ACK_LATENCY]),
      .peripheral_subsystem_powergate_switch_no    (periph_switch_n),
      .peripheral_subsystem_powergate_switch_ack_ni(periph_switch_ack_n[SWITCH_ACK_LATENCY]),
      .external_subsystem_powergate_switch_no      (ext_switch_n),
      .external_subsystem_powergate_switch_ack_ni  (ext_switch_ack_n[SWITCH_ACK_LATENCY]),
      .external_subsystem_powergate_iso_no         (),
      .external_subsystem_rst_no                   (),
      .external_ram_banks_set_retentive_no         (),
      .external_subsystem_clkgate_en_no            (),
      // Read by tb_top through the hierarchy
      .exit_value_o                                (),
% if user_peripheral_domain.contains_peripheral('serial_link_reg'):
      .serial_link_direct_write_req_o              (),
      .serial_link_direct_write_resp_i             ('0),
% endif
      .ext_dma_slot_tx_i                           ('0),
      .ext_dma_slot_rx_i                           ('0),
      .ext_dma_stop_i                              ('0),
      .hw_fifo_done_i                              ('0),
      .xif_compressed_if                           (ext_if),
      .xif_issue_if                                (ext_if),
      .xif_commit_if                               (ext_if),
      .xif_mem_if                                  (ext_if),
      .xif_mem_result_if                           (ext_if),
      .xif_result_if                               (ext_if),
      .dma_done_o                                  (),
      // Pads
% for conn in pad_conns:
      ${conn}${"" if loop.last else ","}
% endfor
  );

  // ---------------------------------------------------------------------------
  // Testbench drivers
  // ---------------------------------------------------------------------------
  logic jtag_tck, jtag_tms, jtag_tdi, jtag_trst_n, jtag_tdo;
  logic uart_to_dut, uart_from_dut;
  logic flash_sck, flash_csb;
  logic [3:0] flash_sd_to_drv, flash_sd_from_drv, flash_sd_oe;
  logic spi_sck, spi_csb;
  logic [3:0] spi_sd_to_drv, spi_sd_from_drv, spi_sd_oe;
  logic spi2_sck, spi2_csb;
  logic [3:0] spi2_sd_to_drv, spi2_sd_from_drv, spi2_sd_oe;
  logic [31:0] gpio_to_drv, gpio_from_drv, gpio_oe;
  logic i2c_scl, i2c_sda, i2c_sda_oe;
  logic i2s_sck, i2s_ws, i2s_sd_rx;
  logic pdm_clk, pdm_data;

  vdrivers #(
      .CLK_FREQUENCY(CLK_FREQUENCY)
  ) vdrivers_i (
      .clk_i,
      .rst_ni,
      .jtag_tck_o  (jtag_tck),
      .jtag_tms_o  (jtag_tms),
      .jtag_tdi_o  (jtag_tdi),
      .jtag_trst_no(jtag_trst_n),
      .jtag_tdo_i  (jtag_tdo),
      .uart_rx_i   (uart_from_dut),
      .uart_tx_o   (uart_to_dut),
      .flash_sck_i (flash_sck),
      .flash_csb_i (flash_csb),
      .flash_sd_i  (flash_sd_to_drv),
      .flash_sd_o  (flash_sd_from_drv),
      .flash_sd_oe (flash_sd_oe),
      .spi_sck_i   (spi_sck),
      .spi_csb_i   (spi_csb),
      .spi_sd_i    (spi_sd_to_drv),
      .spi_sd_o    (spi_sd_from_drv),
      .spi_sd_oe   (spi_sd_oe),
      .spi2_sck_i  (spi2_sck),
      .spi2_csb_i  (spi2_csb),
      .spi2_sd_i   (spi2_sd_to_drv),
      .spi2_sd_o   (spi2_sd_from_drv),
      .spi2_sd_oe  (spi2_sd_oe),
      .gpio_i      (gpio_to_drv),
      .gpio_o      (gpio_from_drv),
      .gpio_oe     (gpio_oe),
      .i2c_scl_i   (i2c_scl),
      .i2c_sda_i   (i2c_sda),
      .i2c_sda_oe_o(i2c_sda_oe),
      .i2s_sck_i   (i2s_sck),
      .i2s_ws_i    (i2s_ws),
      .i2s_sd_o    (i2s_sd_rx),
      .pdm_clk_i   (pdm_clk),
      .pdm_data_o  (pdm_data)
  );

  vinterconnect vinterconnect_i (
      .pad_pu_io    (pad_pu),
      .pad_pd_io    (pad_pd),
      .jtag_tck_i   (jtag_tck),
      .jtag_tms_i   (jtag_tms),
      .jtag_tdi_i   (jtag_tdi),
      .jtag_trst_ni (jtag_trst_n),
      .jtag_tdo_o   (jtag_tdo),
      .uart_rx_o    (uart_from_dut),
      .uart_tx_i    (uart_to_dut),
      .flash_sck_o  (flash_sck),
      .flash_csb_o  (flash_csb),
      .flash_sd_o   (flash_sd_to_drv),
      .flash_sd_i   (flash_sd_from_drv),
      .flash_sd_oe_i(flash_sd_oe),
      .spi_sck_o    (spi_sck),
      .spi_csb_o    (spi_csb),
      .spi_sd_o     (spi_sd_to_drv),
      .spi_sd_i     (spi_sd_from_drv),
      .spi_sd_oe_i  (spi_sd_oe),
      .spi2_sck_o   (spi2_sck),
      .spi2_csb_o   (spi2_csb),
      .spi2_sd_o    (spi2_sd_to_drv),
      .spi2_sd_i    (spi2_sd_from_drv),
      .spi2_sd_oe_i (spi2_sd_oe),
      .gpio_o       (gpio_to_drv),
      .gpio_i       (gpio_from_drv),
      .gpio_oe_i    (gpio_oe),
      .i2c_scl_o    (i2c_scl),
      .i2c_sda_o    (i2c_sda),
      .i2c_sda_oe_i (i2c_sda_oe),
      .i2s_sck_o    (i2s_sck),
      .i2s_ws_o     (i2s_ws),
      .i2s_sd_rx_i  (i2s_sd_rx),
      .pdm_clk_o    (pdm_clk),
      .pdm_data_i   (pdm_data)
  );

endmodule  // testharness
