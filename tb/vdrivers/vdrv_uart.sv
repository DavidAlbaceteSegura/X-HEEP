// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// UART driver (8N1).
//
// Receives what the DUT transmits and writes it to uart0.log, and can send
// bytes to the DUT.
//
// Plusargs:
//   +uart_baud=<n>        baud rate (default: CLK_FREQUENCY / 20)
//   +uart_echo            also print received lines to the simulator log
//   +uart_expect=<text>   the test fails if <text> is never received
//   +uart_send=<text>     sent to the DUT once the firmware is booted

module vdrv_uart #(
    parameter int unsigned CLK_FREQUENCY = 'd100_000,   // kHz
    parameter string       LOG_FILE      = "uart0.log"
) (
    input logic rst_ni,
    input logic rx_i,  // from DUT uart_tx
    output logic tx_o  // to DUT uart_rx
);

  import tb_pkg::*;

  localparam string NAME = "UART";

  real bit_ns = 20.0 * 1.0e6 / real'(CLK_FREQUENCY);
  int log_fd;
  string line = "";
  string rx_text = "";
  int unsigned n_rx = 0;
  int unsigned n_frame_err = 0;

  initial begin
    int unsigned baud;
    tx_o = 1'b1;
    if ($value$plusargs("uart_baud=%d", baud)) bit_ns = 1.0e9 / real'(baud);
    log_fd = $fopen(LOG_FILE, "w");
    if (log_fd == 0) tb_error(NAME, $sformatf("cannot open %s", LOG_FILE));
  end

  // ---------------------------------------------------------------------------
  // Receiver
  // ---------------------------------------------------------------------------
  initial begin : rx_proc
    logic [7:0] data;
    wait (rst_ni === 1'b1);
    forever begin
      @(negedge rx_i);
      #(bit_ns * 0.5 * 1ns);
      if (rx_i !== 1'b0) continue;  // glitch, not a start bit
      for (int i = 0; i < 8; i++) begin
        #(bit_ns * 1ns);
        data[i] = rx_i;
      end
      #(bit_ns * 1ns);
      if (rx_i !== 1'b1) begin
        n_frame_err++;
        tb_warn(NAME, "framing error");
      end
      rx_byte(data);
    end
  end

  function automatic void rx_byte(logic [7:0] data);
    n_rx++;
    if (log_fd != 0) begin
      $fwrite(log_fd, "%c", data);
      $fflush(log_fd);
    end
    rx_text = {rx_text, string'(data)};
    if (data == 8'h0A) begin
      if ($test$plusargs("uart_echo")) tb_info(NAME, line);
      line = "";
    end else if (data != 8'h0D) begin
      line = {line, string'(data)};
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Transmitter
  // ---------------------------------------------------------------------------
  task automatic send_byte(input logic [7:0] data);
    tx_o = 1'b0;
    #(bit_ns * 1ns);
    for (int i = 0; i < 8; i++) begin
      tx_o = data[i];
      #(bit_ns * 1ns);
    end
    tx_o = 1'b1;
    #(bit_ns * 1ns);
  endtask

  task automatic send_string(input string s);
    for (int i = 0; i < s.len(); i++) send_byte(s[i]);
  endtask

  initial begin : tx_proc
    string s;
    if ($value$plusargs("uart_send=%s", s)) begin
      wait (tb_pkg::boot_done);
      tb_info(NAME, $sformatf("sending '%s'", s));
      send_string(s);
    end
  end

  // ---------------------------------------------------------------------------
  // End of test checks
  // ---------------------------------------------------------------------------
  function automatic bit contains(string haystack, string needle);
    if (needle.len() == 0) return 1'b1;
    for (int i = 0; i + needle.len() <= haystack.len(); i++)
    if (haystack.substr(i, i + needle.len() - 1) == needle) return 1'b1;
    return 1'b0;
  endfunction

  function automatic void final_check();
    string expect_s;
    if (line.len() > 0 && $test$plusargs("uart_echo")) tb_info(NAME, line);
    if ($value$plusargs("uart_expect=%s", expect_s) && !contains(rx_text, expect_s))
      tb_error(NAME, $sformatf("expected text '%s' was not received", expect_s));
    if (n_frame_err > 0) tb_error(NAME, $sformatf("%0d framing errors", n_frame_err));
    tb_debug(NAME, $sformatf("%0d bytes received", n_rx));
    if (log_fd != 0) $fclose(log_fd);
    log_fd = 0;
  endfunction

endmodule
