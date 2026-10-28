// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Shared testbench definitions: boot modes, pad routes, test verdict and the
// scoreboard every driver reports to. The flow itself lives in tb_top.

package tb_pkg;

  // ---------------------------------------------------------------------------
  // Boot modes (+boot=<name>)
  // ---------------------------------------------------------------------------
  typedef enum int {
    BOOT_BACKDOOR,  // firmware preloaded into SRAM by the testbench (fast)
    BOOT_JTAG,      // firmware loaded by the JTAG driver through the debug module
    BOOT_FLASH      // firmware held by the SPI flash driver, CPU boots from flash
  } boot_mode_e;

  // ---------------------------------------------------------------------------
  // Pad routes (+tb_route=<name>[,<name>...])
  // Each route connects a group of DUT pads to a driver in vinterconnect.
  // The GPIO route takes every GPIO pad not claimed by another route.
  // ---------------------------------------------------------------------------
  typedef enum int {
    ROUTE_GPIO,
    ROUTE_I2C,
    ROUTE_SPI_HOST,
    ROUTE_SPI2,
    ROUTE_SPI_SLAVE,
    ROUTE_I2S,
    ROUTE_PDM2PCM
  } route_e;

  localparam int unsigned NUM_ROUTES = 7;
  typedef logic [NUM_ROUTES-1:0] route_mask_t;

  // ---------------------------------------------------------------------------
  // Test verdict. Printed as "[TB] RESULT: <PASS|FAIL> code=<n> ..."
  // ---------------------------------------------------------------------------
  typedef enum int {
    RES_PASS       = 0,
    RES_SW_FAIL    = 1,  // firmware exited with a non-zero value
    RES_DRV_FAIL   = 2,  // a driver reported errors
    RES_TIMEOUT    = 3,  // firmware did not exit before the cycle limit
    RES_CONFIG_ERR = 4,  // wrong plusargs or testbench setup
    RES_BOOT_FAIL  = 5   // firmware could not be loaded
  } result_e;

  // ---------------------------------------------------------------------------
  // Scoreboard
  // ---------------------------------------------------------------------------
  int unsigned err_cnt = 0;
  int unsigned warn_cnt = 0;
  // Set by tb_top once the firmware is loaded and the CPU released. Drivers
  // with stimulus of their own wait on it.
  bit boot_done = 1'b0;

  function automatic bit verbose();
    return $test$plusargs("verbose");
  endfunction

  function automatic void tb_info(string src, string msg);
    $display("[%t] [%s] %s", $realtime, src, msg);
  endfunction

  function automatic void tb_debug(string src, string msg);
    if (verbose()) $display("[%t] [%s] %s", $realtime, src, msg);
  endfunction

  function automatic void tb_warn(string src, string msg);
    warn_cnt++;
    $display("[%t] [%s] WARNING: %s", $realtime, src, msg);
  endfunction

  function automatic void tb_error(string src, string msg);
    err_cnt++;
    $display("[%t] [%s] ERROR: %s", $realtime, src, msg);
  endfunction

  // ---------------------------------------------------------------------------
  // Plusarg helpers
  // ---------------------------------------------------------------------------
  function automatic string route_name(route_e r);
    case (r)
      ROUTE_GPIO:      return "gpio";
      ROUTE_I2C:       return "i2c";
      ROUTE_SPI_HOST:  return "spi_host";
      ROUTE_SPI2:      return "spi2";
      ROUTE_SPI_SLAVE: return "spi_slave";
      ROUTE_I2S:       return "i2s";
      ROUTE_PDM2PCM:   return "pdm2pcm";
      default:         return "?";
    endcase
  endfunction

  // Splits a comma separated plusarg value into its tokens.
  function automatic void split_list(string s, ref string toks[$]);
    string tok = "";
    toks.delete();
    for (int i = 0; i < s.len(); i++) begin
      if (s[i] == ",") begin
        if (tok.len() > 0) toks.push_back(tok);
        tok = "";
      end else begin
        tok = {tok, s.substr(i, i)};
      end
    end
    if (tok.len() > 0) toks.push_back(tok);
  endfunction

  // Parses +tb_route. Unknown names are reported and ignored.
  function automatic route_mask_t get_routes();
    string arg, toks[$];
    route_mask_t mask = '0;
    bit found;
    if (!$value$plusargs("tb_route=%s", arg)) return '0;
    split_list(arg, toks);
    foreach (toks[i]) begin
      found = 1'b0;
      for (int r = 0; r < NUM_ROUTES; r++) begin
        if (toks[i] == route_name(route_e'(r))) begin
          mask[r] = 1'b1;
          found   = 1'b1;
        end
      end
      if (!found) tb_error("TB", $sformatf("unknown route '%s' in +tb_route", toks[i]));
    end
    return mask;
  endfunction

  // Reads a byte-wise Verilog hex file (objcopy -O verilog) into a sparse
  // byte array. Returns the number of bytes read, or -1 if the file can't be
  // opened.
  function automatic int read_hex(string file, ref logic [7:0] mem[int unsigned]);
    int fd, n;
    string tok;
    int unsigned addr = 0;
    fd = $fopen(file, "r");
    if (fd == 0) return -1;
    while (!$feof(
        fd
    )) begin
      n = $fscanf(fd, "%s", tok);
      if (n != 1) break;
      if (tok[0] == "@") begin
        addr = tok.substr(1, tok.len() - 1).atohex();
      end else begin
        mem[addr] = 8'(tok.atohex());
        addr++;
      end
    end
    $fclose(fd);
    return mem.num();
  endfunction

endpackage
