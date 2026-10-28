// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// I2C target driver.
//
// Register-file target with a 256-byte address space, shared by every
// address it answers to. A write sets the register pointer with its first
// byte and stores the following ones; a read returns data from the pointer.
// The pointer auto-increments. The driver only pulls SDA low (open drain);
// pull-ups are in vinterconnect.
//
// Plusargs:
//   +i2c_addr=<hex>[,<hex>...]   7-bit target addresses (default 48,6b,50)
//   +i2c_mem=<file>              initial register contents ($readmemh)
//   +i2c_expect_txn=<n>          the test fails with fewer than <n> transfers
//                                addressed to this target

module vdrv_i2c (
    input  logic rst_ni,
    input  logic scl_i,
    input  logic sda_i,
    output logic sda_oe_o  // 1: pull SDA low
);

  import tb_pkg::*;

  localparam string NAME = "I2C";

  typedef enum int {
    IDLE,
    ADDR,
    ADDR_ACK,
    WR_DATA,
    WR_ACK,
    RD_DATA,
    RD_ACK
  } state_e;

  logic [7:0] regs[256];
  bit addr_match[128];
  state_e state;
  logic [7:0] shreg;
  int unsigned bit_cnt;
  logic [7:0] ptr;
  bit first_byte, is_read, master_ack;
  int unsigned n_txn;
  // Hold time after SCL falls before changing SDA
  realtime hold = 5ns;

  initial begin
    string arg, toks[$], mem_file;
    int a;
    sda_oe_o = 1'b0;
    state = IDLE;
    ptr = '0;
    n_txn = 0;
    foreach (regs[i]) regs[i] = 8'(i);
    if (!$value$plusargs("i2c_addr=%s", arg)) arg = "48,6b,50";
    split_list(arg, toks);
    foreach (toks[i]) begin
      if ($sscanf(toks[i], "%h", a) != 1 || a < 0 || a > 127)
        tb_error(NAME, $sformatf("bad +i2c_addr entry '%s'", toks[i]));
      else addr_match[a] = 1'b1;
    end
    if ($value$plusargs("i2c_mem=%s", mem_file)) $readmemh(mem_file, regs);
  end

  // START / repeated START: SDA falls while SCL is high
  always @(negedge sda_i) begin
    if (rst_ni === 1'b1 && scl_i === 1'b1) begin
      state = ADDR;
      bit_cnt = 0;
      sda_oe_o = 1'b0;
    end
  end

  // STOP: SDA rises while SCL is high
  always @(posedge sda_i) begin
    if (rst_ni === 1'b1 && scl_i === 1'b1) begin
      if (state != IDLE) tb_debug(NAME, "STOP");
      state = IDLE;
      sda_oe_o = 1'b0;
    end
  end

  // Sample on the rising edge of SCL
  always @(posedge scl_i) begin
    case (state)
      ADDR, WR_DATA: begin
        shreg = {shreg[6:0], sda_i};
        bit_cnt++;
      end
      RD_DATA: bit_cnt++;
      RD_ACK:  master_ack = (sda_i === 1'b0);
      default: ;
    endcase
  end

  // Drive on the falling edge of SCL
  always @(negedge scl_i) begin
    #(hold);
    case (state)
      ADDR:
      if (bit_cnt == 8) begin
        is_read = shreg[0];
        if (addr_match[shreg[7:1]]) begin
          n_txn++;
          tb_debug(NAME, $sformatf("%s 0x%02h", is_read ? "read from" : "write to", shreg[7:1]));
          sda_oe_o = 1'b1;  // ACK
          state = ADDR_ACK;
        end else begin
          tb_debug(NAME, $sformatf("NACK address 0x%02h", shreg[7:1]));
          state = IDLE;
        end
      end
      ADDR_ACK: begin
        if (is_read) begin
          shreg = regs[ptr];
          sda_oe_o = !shreg[7];
          bit_cnt = 0;
          state = RD_DATA;
        end else begin
          sda_oe_o = 1'b0;
          bit_cnt = 0;
          first_byte = 1'b1;
          state = WR_DATA;
        end
      end
      WR_DATA:
      if (bit_cnt == 8) begin
        if (first_byte) begin
          ptr = shreg;
          first_byte = 1'b0;
        end else begin
          tb_debug(NAME, $sformatf("reg[0x%02h] <= 0x%02h", ptr, shreg));
          regs[ptr] = shreg;
          ptr++;
        end
        sda_oe_o = 1'b1;  // ACK
        state = WR_ACK;
      end
      WR_ACK: begin
        sda_oe_o = 1'b0;
        bit_cnt = 0;
        state = WR_DATA;
      end
      RD_DATA:
      if (bit_cnt == 8) begin
        tb_debug(NAME, $sformatf("reg[0x%02h] => 0x%02h", ptr, regs[ptr]));
        ptr++;
        sda_oe_o = 1'b0;  // release for the master ACK
        state = RD_ACK;
      end else begin
        sda_oe_o = !shreg[7-bit_cnt];
      end
      RD_ACK: begin
        if (master_ack) begin
          shreg = regs[ptr];
          sda_oe_o = !shreg[7];
          bit_cnt = 0;
          state = RD_DATA;
        end else begin
          state = IDLE;
        end
      end
      default: ;
    endcase
  end

  function automatic void final_check();
    int unsigned expect_txn;
    if ($value$plusargs("i2c_expect_txn=%d", expect_txn) && n_txn < expect_txn)
      tb_error(NAME, $sformatf("%0d transfers addressed, expected at least %0d", n_txn, expect_txn
               ));
    tb_debug(NAME, $sformatf("%0d transfers addressed", n_txn));
  endfunction

endmodule
