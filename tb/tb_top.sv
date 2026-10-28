// Copyright 2022 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// X-HEEP testbench top. Generates clock and reset and runs the simulation
// flow: boot, wait for the firmware to exit, collect the driver verdicts and
// end the simulation with a single result line:
//
//   [TB] RESULT: PASS code=0
//   [TB] RESULT: FAIL code=<n> (<reason>) ...
//
// where <n> is a tb_pkg::result_e. The simulator exits with a non-zero status
// on failure.
//
// Plusargs:
//   +firmware=<hex>            firmware image (objcopy -O verilog)
//   +boot=backdoor|jtag|flash  boot mode (default backdoor)
//   +boot_sel=0|1              legacy: 0 = backdoor, 1 = flash
//   +flash_hex=<hex>           boot flash contents (default: +firmware)
//   +max_sim_time=<n>[unit]    timeout, in cycles or with ps/ns/us/ms/s suffix
//   +drain_cycles=<n>          cycles run after the firmware exits (default 100)
//   +tb_route=<route>,...      pad routes, see vinterconnect
//   +waves                     dump waveforms
//   +verbose                   more logging
// Each driver documents its own plusargs (tb/vdrivers).

module tb_top;

  import tb_pkg::*;

  localparam string NAME = "TB";
  localparam int unsigned CLK_FREQUENCY_KHz = 100_000;
  localparam realtime CLK_PERIOD = (1.0e6 / CLK_FREQUENCY_KHz) * 1ns;
  localparam int unsigned RESET_CYCLES = 50;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic boot_sel = 1'b0;
  wire exit_valid;
  logic [31:0] exit_value;

  longint unsigned cycles;
  bit test_ended = 1'b0;
  // Firmware exit, latched when exit_valid is first seen
  bit sw_exited = 1'b0;
  logic [31:0] sw_exit_value;

  // ---------------------------------------------------------------------------
  // Clock, cycle counter, waves
  // ---------------------------------------------------------------------------
  initial begin : clock_gen
    cycles = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  always @(posedge clk) cycles <= cycles + 1;

  initial begin : waves
    $timeformat(-9, 0, " ns", 12);
    if ($test$plusargs("waves") || $test$plusargs("vcd")) begin
`ifdef VERILATOR
      $dumpfile("waveform.fst");
`else
      $dumpfile("waveform.vcd");
`endif
      $dumpvars(0, tb_top);
    end
  end

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  testharness #(
      .CLK_FREQUENCY(CLK_FREQUENCY_KHz)
  ) testharness_i (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .boot_select_i(boot_sel),
      .exit_valid_o (exit_valid)
  );

  // The exit value is not a pad: read it from soc_ctrl through the hierarchy
  assign exit_value = testharness_i.x_heep_system_i.exit_value_o;

  // ---------------------------------------------------------------------------
  // Plusargs
  // ---------------------------------------------------------------------------
  function automatic boot_mode_e get_boot_mode();
    string arg;
    if ($value$plusargs("boot=%s", arg)) begin
      case (arg)
        "backdoor": return BOOT_BACKDOOR;
        "jtag":     return BOOT_JTAG;
        "flash":    return BOOT_FLASH;
        default:    tb_error(NAME, $sformatf("unknown boot mode '%s'", arg));
      endcase
    end else if ($value$plusargs("boot_sel=%s", arg)) begin
      if (arg == "1") return BOOT_FLASH;
      if (arg != "0") tb_error(NAME, $sformatf("unknown +boot_sel=%s", arg));
    end
    return BOOT_BACKDOOR;
  endfunction

  // +max_sim_time=<n>[ps|ns|us|ms|s], in clock cycles without suffix.
  // Returns 0 when there is no limit.
  function automatic longint unsigned get_max_cycles();
    string arg, unit;
    longint unsigned n;
    int i;
    realtime t;
    if (!$value$plusargs("max_sim_time=%s", arg)) return 0;
    i = 0;
    while (i < arg.len() && arg[i] >= "0" && arg[i] <= "9") i++;
    n = 64'(arg.substr(0, i - 1).atoi());
    unit = i < arg.len() ? arg.substr(i, arg.len() - 1) : "";
    case (unit)
      "":        return n;
      "p", "ps": t = n * 1ps;
      "n", "ns": t = n * 1ns;
      "u", "us": t = n * 1us;
      "m", "ms": t = n * 1ms;
      "s":       t = n * 1s;
      default: begin
        tb_error(NAME, $sformatf("unsupported suffix '%s' for +max_sim_time", unit));
        return 0;
      end
    endcase
    return longint'(t / CLK_PERIOD);
  endfunction

  function automatic string boot_name(boot_mode_e b);
    case (b)
      BOOT_BACKDOOR: return "backdoor";
      BOOT_JTAG:     return "jtag";
      default:       return "flash";
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // End of test
  // ---------------------------------------------------------------------------
  function automatic string result_name(result_e r);
    case (r)
      RES_PASS:       return "PASS";
      RES_SW_FAIL:    return "SW_FAIL";
      RES_DRV_FAIL:   return "DRIVER_FAIL";
      RES_TIMEOUT:    return "TIMEOUT";
      RES_CONFIG_ERR: return "CONFIG_ERROR";
      default:        return "BOOT_FAIL";
    endcase
  endfunction

  // Collects the verdicts and ends the simulation. 'res' is RES_PASS when the
  // firmware exited; the final result then depends on its exit value and on
  // the driver errors.
  task automatic end_test(input result_e res);
    if (test_ended) return;
    test_ended = 1'b1;

    testharness_i.vdrivers_i.final_check();
    if (res == RES_PASS) begin
      if (sw_exit_value != 0) res = RES_SW_FAIL;
      else if (err_cnt != 0) res = RES_DRV_FAIL;
    end

    $display("[%s] Simulation finished after %0d clock cycles", NAME, cycles);
    // Kept for the scripts that parse the firmware exit value
    if (sw_exited) $display("Program Finished with value %0d", sw_exit_value);
    if (res == RES_PASS) begin
      $display("[%s] RESULT: PASS code=0 errors=0 warnings=%0d", NAME, warn_cnt);
      $finish;
    end else begin
      $display("[%s] RESULT: FAIL code=%0d (%s) sw_exit=%0s errors=%0d warnings=%0d", NAME, res,
               result_name(res), sw_exited ? $sformatf("%0d", sw_exit_value) : "none", err_cnt,
               warn_cnt);
      $fatal(1, "[%s] test failed", NAME);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Simulation flow
  // ---------------------------------------------------------------------------
  longint unsigned max_cycles;

  initial begin : tb_flow
    string firmware, flash_hex;
    boot_mode_e boot;
    int unsigned drain_cycles;
    bit ok;

    // Configuration
    if (!$value$plusargs("firmware=%s", firmware)) firmware = "";
    boot = get_boot_mode();
    max_cycles = get_max_cycles();
    if (!$value$plusargs("flash_hex=%s", flash_hex)) flash_hex = firmware;
    if (!$value$plusargs("drain_cycles=%d", drain_cycles)) drain_cycles = 100;

    tb_info(NAME, $sformatf("firmware: %s", firmware.len() > 0 ? firmware : "none"));
    tb_info(NAME, $sformatf("boot: %s", boot_name(boot)));
    if (max_cycles > 0) tb_info(NAME, $sformatf("timeout: %0d cycles", max_cycles));
    if (firmware.len() == 0) tb_error(NAME, "no +firmware given");
    if (err_cnt != 0) end_test(RES_CONFIG_ERR);

    boot_sel = (boot == BOOT_FLASH);
    if (flash_hex.len() > 0) testharness_i.load_flash_hex(flash_hex);

    // Reset
    rst_n = 1'b0;
    repeat (RESET_CYCLES) @(posedge clk);
    #(CLK_PERIOD * 0.1);
    rst_n = 1'b1;
    tb_debug(NAME, "reset released");
    repeat (RESET_CYCLES) @(posedge clk);

    // Boot
    case (boot)
      BOOT_BACKDOOR: begin
        testharness_i.tb_loadHEX(firmware);
        @(posedge clk);
        testharness_i.tb_set_exit_loop();
        tb_info(NAME, "firmware loaded by backdoor");
      end
      BOOT_JTAG: begin
        testharness_i.vdrivers_i.jtag_i.load_firmware(firmware, ok);
        if (!ok) end_test(RES_BOOT_FAIL);
      end
      default: tb_info(NAME, "booting from flash");
    endcase
    tb_pkg::boot_done = 1'b1;

    // Run
    wait (exit_valid === 1'b1);
    sw_exited = 1'b1;
    sw_exit_value = exit_value;
    tb_info(NAME, $sformatf("firmware exited with %0d", sw_exit_value));
    repeat (drain_cycles) @(posedge clk);
    end_test(RES_PASS);
  end

  initial begin : watchdog
    wait (rst_n === 1'b1);
    if (max_cycles != 0) begin
      wait (cycles >= max_cycles);
      tb_error(NAME, $sformatf("timeout after %0d cycles", cycles));
      end_test(RES_TIMEOUT);
    end
  end

endmodule  // tb_top
