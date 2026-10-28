// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// JTAG master driver.
//
// Bit-bangs the RISC-V debug transport module (riscv-dbg dmi_jtag) to load a
// firmware image through the debug module System Bus Access (SBA) and then
// releases the boot ROM loop by writing soc_ctrl.BOOT_EXIT_LOOP.
//
// Plusargs:
//   +jtag_tck_ns=<n>   TCK period in ns (default 100)
//   +jtag_verify       read back every word written by load_firmware()

module vdrv_jtag (
    output logic tck_o,
    output logic tms_o,
    output logic tdi_o,
    output logic trst_no,
    input  logic tdo_i
);

  import tb_pkg::*;

  localparam string NAME = "JTAG";

  // dmi_jtag instruction register
  localparam int unsigned IR_LEN = 5;
  localparam logic [IR_LEN-1:0] IR_IDCODE = 5'h01;
  localparam logic [IR_LEN-1:0] IR_DTMCS = 5'h10;
  localparam logic [IR_LEN-1:0] IR_DMIACCESS = 5'h11;

  // DMI: {addr[6:0], data[31:0], op[1:0]}
  localparam int unsigned DMI_ABITS = 7;
  localparam int unsigned DMI_LEN = DMI_ABITS + 32 + 2;
  localparam logic [1:0] DMI_NOP = 2'd0;
  localparam logic [1:0] DMI_READ = 2'd1;
  localparam logic [1:0] DMI_WRITE = 2'd2;
  localparam logic [1:0] DMI_BUSY = 2'd3;

  // Debug module registers
  localparam logic [DMI_ABITS-1:0] DM_DMCONTROL = 7'h10;
  localparam logic [DMI_ABITS-1:0] DM_SBCS = 7'h38;
  localparam logic [DMI_ABITS-1:0] DM_SBADDRESS0 = 7'h39;
  localparam logic [DMI_ABITS-1:0] DM_SBDATA0 = 7'h3C;

  // sbcs fields
  localparam logic [31:0] SBCS_BUSYERROR = 32'h1 << 22;
  localparam logic [31:0] SBCS_BUSY = 32'h1 << 21;
  localparam logic [31:0] SBCS_READONADDR = 32'h1 << 20;
  localparam logic [31:0] SBCS_ACCESS32 = 32'h2 << 17;
  localparam logic [31:0] SBCS_AUTOINCR = 32'h1 << 16;
  localparam logic [31:0] SBCS_ERROR = 32'h7 << 12;

  real tck_half_ns = 50.0;
  int unsigned idle_cycles = 1;
  int unsigned read_wait_cycles = 8;
  logic [IR_LEN-1:0] cur_ir = '1;
  bit dmi_sticky_busy = 1'b0;

  logic bfm_tck = 1'b0, bfm_tms = 1'b0, bfm_tdi = 1'b0, bfm_trst_n = 1'b0;

  initial begin
    int unsigned tck_ns;
    if ($value$plusargs("jtag_tck_ns=%d", tck_ns)) tck_half_ns = real'(tck_ns) / 2.0;
  end

  // ---------------------------------------------------------------------------
  // Pin drivers
  // ---------------------------------------------------------------------------
  assign tck_o   = bfm_tck;
  assign tms_o   = bfm_tms;
  assign tdi_o   = bfm_tdi;
  assign trst_no = bfm_trst_n;

  // ---------------------------------------------------------------------------
  // TAP level
  // ---------------------------------------------------------------------------
  // One TCK cycle: TMS/TDI change on the falling edge, TDO is sampled on the
  // rising edge.
  task automatic tick(input logic tms, input logic tdi, output logic tdo);
    bfm_tms = tms;
    bfm_tdi = tdi;
    #(tck_half_ns * 1ns);
    bfm_tck = 1'b1;
    tdo = tdo_i;
    #(tck_half_ns * 1ns);
    bfm_tck = 1'b0;
  endtask

  task automatic tap_reset();
    logic unused;
    bfm_trst_n = 1'b0;
    repeat (2) tick(1'b1, 1'b0, unused);
    bfm_trst_n = 1'b1;
    // Test-Logic-Reset, then Run-Test/Idle
    repeat (5) tick(1'b1, 1'b0, unused);
    tick(1'b0, 1'b0, unused);
    cur_ir = IR_IDCODE;
  endtask

  // From Run-Test/Idle, back to Run-Test/Idle
  task automatic shift_ir(input logic [IR_LEN-1:0] ir);
    logic unused;
    tick(1'b1, 1'b0, unused);  // Select-DR
    tick(1'b1, 1'b0, unused);  // Select-IR
    tick(1'b0, 1'b0, unused);  // Capture-IR
    tick(1'b0, 1'b0, unused);  // Shift-IR
    for (int i = 0; i < IR_LEN; i++) tick(i == IR_LEN - 1, ir[i], unused);  // last: Exit1-IR
    tick(1'b1, 1'b0, unused);  // Update-IR
    tick(1'b0, 1'b0, unused);  // Run-Test/Idle
    cur_ir = ir;
  endtask

  // From Run-Test/Idle, back to Run-Test/Idle. LSB first.
  task automatic shift_dr(input logic [63:0] din, input int unsigned len, output logic [63:0] dout);
    logic unused;
    dout = '0;
    tick(1'b1, 1'b0, unused);  // Select-DR
    tick(1'b0, 1'b0, unused);  // Capture-DR
    tick(1'b0, 1'b0, unused);  // Shift-DR
    for (int i = 0; i < len; i++) tick(i == len - 1, din[i], dout[i]);  // last: Exit1-DR
    tick(1'b1, 1'b0, unused);  // Update-DR
    tick(1'b0, 1'b0, unused);  // Run-Test/Idle
    repeat (idle_cycles) tick(1'b0, 1'b0, unused);
  endtask

  task automatic read_idcode(output logic [31:0] idcode);
    logic [63:0] dout;
    shift_ir(IR_IDCODE);
    shift_dr('0, 32, dout);
    idcode = dout[31:0];
  endtask

  // ---------------------------------------------------------------------------
  // DMI level
  // ---------------------------------------------------------------------------
  task automatic dtmcs_access(input logic [31:0] wdata, output logic [31:0] rdata);
    logic [63:0] dout;
    if (cur_ir != IR_DTMCS) shift_ir(IR_DTMCS);
    shift_dr({32'h0, wdata}, 32, dout);
    rdata = dout[31:0];
  endtask

  task automatic dmi_reset();
    logic [31:0] unused;
    dtmcs_access(32'h1 << 16, unused);  // dmireset
    dmi_sticky_busy = 1'b0;
  endtask

  // Single DMI scan. The returned data/status belong to the previous access.
  task automatic dmi_scan(input logic [DMI_ABITS-1:0] addr, input logic [31:0] wdata,
                          input logic [1:0] op, output logic [31:0] rdata,
                          output logic [1:0] status);
    logic [63:0] dout;
    if (cur_ir != IR_DMIACCESS) shift_ir(IR_DMIACCESS);
    shift_dr({23'h0, addr, wdata, op}, DMI_LEN, dout);
    rdata  = dout[33:2];
    status = dout[1:0];
    if (status == DMI_BUSY) dmi_sticky_busy = 1'b1;
  endtask

  // Posted write: its status is checked by the next scan.
  task automatic dmi_write(input logic [DMI_ABITS-1:0] addr, input logic [31:0] wdata);
    logic [31:0] unused;
    logic [ 1:0] status;
    dmi_scan(addr, wdata, DMI_WRITE, unused, status);
  endtask

  // The read result crosses back to the TCK domain, so wait in Run-Test/Idle
  // before collecting it. Capturing too early makes the DTM report busy (and
  // ignore every access until dmireset): retry with a longer wait.
  task automatic dmi_read(input logic [DMI_ABITS-1:0] addr, output logic [31:0] rdata);
    logic [1:0] status;
    logic unused;
    for (int attempt = 0; attempt < 4; attempt++) begin
      dmi_scan(addr, '0, DMI_READ, rdata, status);
      repeat (read_wait_cycles) tick(1'b0, 1'b0, unused);
      dmi_scan('0, '0, DMI_NOP, rdata, status);
      if (status == 2'd0) return;
      dmi_reset();
      read_wait_cycles = read_wait_cycles * 2;
      tb_debug(NAME, $sformatf("DMI read busy, waiting %0d cycles", read_wait_cycles));
    end
    tb_error(NAME, $sformatf("DMI read of 0x%02h failed", addr));
  endtask

  // Waits for all posted accesses to complete and reports DMI errors.
  task automatic dmi_sync(output bit ok);
    logic [31:0] unused;
    logic [ 1:0] status;
    dmi_scan('0, '0, DMI_NOP, unused, status);
    ok = !dmi_sticky_busy && status != 2'd2;
  endtask

  // ---------------------------------------------------------------------------
  // System bus access
  // ---------------------------------------------------------------------------
  task automatic sba_setup(input logic [31:0] extra);
    dmi_write(DM_SBCS, SBCS_ACCESS32 | SBCS_BUSYERROR | SBCS_ERROR | extra);
  endtask

  task automatic sba_check(output bit ok);
    logic [31:0] sbcs;
    dmi_read(DM_SBCS, sbcs);
    ok = (sbcs & (SBCS_BUSYERROR | SBCS_ERROR | SBCS_BUSY)) == 0;
    if (!ok) tb_error(NAME, $sformatf("system bus access error, sbcs=0x%08h", sbcs));
  endtask

  task automatic sba_write32(input logic [31:0] addr, input logic [31:0] data);
    sba_setup('0);
    dmi_write(DM_SBADDRESS0, addr);
    dmi_write(DM_SBDATA0, data);
  endtask

  task automatic sba_read32(input logic [31:0] addr, output logic [31:0] data);
    sba_setup(SBCS_READONADDR);
    dmi_write(DM_SBADDRESS0, addr);
    dmi_read(DM_SBDATA0, data);
  endtask

  // ---------------------------------------------------------------------------
  // Firmware loading
  // ---------------------------------------------------------------------------
  task automatic connect(output bit ok);
    logic [31:0] idcode, dtmcs;
    tap_reset();
    read_idcode(idcode);
    tb_info(NAME, $sformatf("IDCODE 0x%08h", idcode));
    dtmcs_access('0, dtmcs);
    if (dtmcs[9:4] != 6'(DMI_ABITS)) begin
      tb_error(NAME, $sformatf("unexpected DMI abits %0d (dtmcs=0x%08h)", dtmcs[9:4], dtmcs));
      ok = 1'b0;
      return;
    end
    if (32'(dtmcs[14:12]) + 1 > idle_cycles) idle_cycles = 32'(dtmcs[14:12]) + 1;
    // Activate the debug module
    dmi_write(DM_DMCONTROL, 32'h0);
    dmi_write(DM_DMCONTROL, 32'h1);
    dmi_sync(ok);
    if (!ok) tb_error(NAME, "debug module does not respond");
  endtask

  task automatic write_words(ref logic [31:0] words[int unsigned], output bit ok);
    int unsigned addr, next_addr;
    bit ok_sba;
    sba_setup(SBCS_AUTOINCR);
    next_addr = '1;
    if (words.first(addr) != 0) begin
      do begin
        if (addr != next_addr) dmi_write(DM_SBADDRESS0, addr);
        dmi_write(DM_SBDATA0, words[addr]);
        next_addr = addr + 4;
      end while (words.next(
          addr
      ) != 0);
    end
    dmi_sync(ok);
    sba_check(ok_sba);
    ok = ok && ok_sba;
  endtask

  task automatic verify_words(ref logic [31:0] words[int unsigned], output bit ok);
    int unsigned addr, n_err = 0;
    logic [31:0] rdata;
    if (words.first(addr) != 0) begin
      do begin
        sba_read32(addr, rdata);
        if (rdata !== words[addr]) begin
          n_err++;
          if (n_err <= 10)
            tb_error(
                NAME, $sformatf(
                "readback mismatch @0x%08h: got 0x%08h, expected 0x%08h", addr, rdata, words[addr]
                ));
        end
      end while (words.next(
          addr
      ) != 0);
    end
    ok = n_err == 0;
  endtask

  // Loads 'file' through SBA and releases the boot ROM loop.
  task automatic load_firmware(input string file, output bit ok);
    logic [7:0] bytes[int unsigned];
    logic [31:0] words[int unsigned];
    int unsigned addr;
    int n;

    ok = 1'b0;
    n  = read_hex(file, bytes);
    if (n <= 0) begin
      tb_error(NAME, $sformatf("cannot read firmware '%s'", file));
      return;
    end
    if (bytes.first(addr) != 0) begin
      do begin
        if (!words.exists(addr & ~32'h3)) words[addr&~32'h3] = '0;
        words[addr&~32'h3][8*(addr%4)+:8] = bytes[addr];
      end while (bytes.next(
          addr
      ) != 0);
    end
    tb_info(NAME, $sformatf("loading %0d bytes (%0d words) from %s", n, words.num(), file));

    connect(ok);
    if (!ok) return;

    // Retry with more idle cycles if the DMI reported busy
    for (int attempt = 0; attempt < 3; attempt++) begin
      write_words(words, ok);
      if (ok) break;
      tb_warn(NAME, $sformatf("DMI busy with %0d idle cycles, retrying", idle_cycles));
      dmi_reset();
      idle_cycles = idle_cycles * 2 + 1;
    end
    if (!ok) return;

    if ($test$plusargs("jtag_verify")) begin
      verify_words(words, ok);
      if (!ok) return;
      tb_info(NAME, "readback OK");
    end

    tb_info(NAME, "firmware loaded, releasing boot loop");
    sba_write32(
        core_v_mini_mcu_pkg::SOC_CTRL_START_ADDRESS +
                    32'(soc_ctrl_reg_pkg::SOC_CTRL_BOOT_EXIT_LOOP_OFFSET),
        32'h1);
    dmi_sync(ok);
    if (!ok) tb_error(NAME, "failed to write BOOT_EXIT_LOOP");
  endtask

endmodule
