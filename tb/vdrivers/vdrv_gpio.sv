// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// GPIO driver.
//
// Plusargs:
//   +gpio_loop=<out>:<in>[,...]   drive GPIO <in> with the value of GPIO <out>
//                                 (default 30:31, as used by example_gpio_intr)
//   +gpio_drive=<mask>:<value>    statically drive the GPIOs in <mask> (hex)
//   +gpio_expect_toggle=<mask>    the test fails if a GPIO in <mask> (hex)
//                                 never toggles
//   +gpio_monitor                 log every edge seen on the GPIOs
// Directed tests can also use set()/release_pin()/wait_value().

module vdrv_gpio (
    input  logic        rst_ni,
    input  logic [31:0] gpio_i,  // value seen on the pads
    output logic [31:0] gpio_o,
    output logic [31:0] gpio_oe
);

  import tb_pkg::*;

  localparam string NAME = "GPIO";

  // Loopback map: loop_src[i] >= 0 means GPIO i is driven by GPIO loop_src[i]
  int loop_src[32];
  logic [31:0] loop_en = '0;
  logic [31:0] static_mask = '0, static_val = '0;
  logic [31:0] task_mask = '0, task_val = '0;
  logic [31:0] toggled;
  logic [31:0] gpio_q;

  initial begin
    string arg, toks[$];
    int src, dst;
    toggled = '0;
    foreach (loop_src[i]) loop_src[i] = -1;
    if (!$value$plusargs("gpio_loop=%s", arg)) arg = "30:31";
    split_list(arg, toks);
    foreach (toks[i]) begin
      if ($sscanf(
              toks[i], "%d:%d", src, dst
          ) != 2 || src < 0 || src > 31 || dst < 0 || dst > 31) begin
        tb_error(NAME, $sformatf("bad +gpio_loop entry '%s'", toks[i]));
      end else begin
        loop_src[dst] = src;
        loop_en[dst]  = 1'b1;
        tb_debug(NAME, $sformatf("loopback GPIO %0d -> GPIO %0d", src, dst));
      end
    end
    if ($value$plusargs("gpio_drive=%s", arg)) begin
      if ($sscanf(arg, "%h:%h", static_mask, static_val) != 2)
        tb_error(NAME, $sformatf("bad +gpio_drive '%s'", arg));
    end
  end

  always_comb begin
    for (int i = 0; i < 32; i++) begin
      gpio_oe[i] = 1'b0;
      gpio_o[i]  = 1'b0;
      if (task_mask[i]) begin
        gpio_oe[i] = 1'b1;
        gpio_o[i]  = task_val[i];
      end else if (static_mask[i]) begin
        gpio_oe[i] = 1'b1;
        gpio_o[i]  = static_val[i];
      end else if (loop_en[i]) begin
        gpio_oe[i] = 1'b1;
        gpio_o[i]  = gpio_i[loop_src[i]];
      end
    end
  end

  // Edge monitor
  always @(gpio_i) begin
    if (rst_ni === 1'b1) begin
      toggled |= gpio_i ^ gpio_q;
      if ($test$plusargs("gpio_monitor"))
        for (int i = 0; i < 32; i++)
        if (gpio_i[i] !== gpio_q[i]) tb_info(NAME, $sformatf("GPIO %0d -> %b", i, gpio_i[i]));
    end
    gpio_q = gpio_i;
  end

  // ---------------------------------------------------------------------------
  // Directed test API
  // ---------------------------------------------------------------------------
  function automatic void set(logic [4:0] idx, logic val);
    task_mask[idx] = 1'b1;
    task_val[idx]  = val;
  endfunction

  function automatic void release_pin(logic [4:0] idx);
    task_mask[idx] = 1'b0;
  endfunction

  task automatic wait_value(input logic [4:0] idx, input logic val);
    wait (gpio_i[idx] === val);
  endtask

  function automatic void final_check();
    logic [31:0] expect_mask;
    if ($value$plusargs("gpio_expect_toggle=%h", expect_mask) && (expect_mask & ~toggled) != 0)
      tb_error(NAME, $sformatf("GPIOs never toggled: 0x%08h", expect_mask & ~toggled));
    tb_debug(NAME, $sformatf("toggled GPIOs: 0x%08h", toggled));
  endfunction

endmodule
