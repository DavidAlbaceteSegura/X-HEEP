// Copyright 2026 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// SPI memory driver: a SPI NOR flash (see yosys_spiflash.sv) selected by
// csb_i. Used as the boot flash on the spi_flash pads and as a generic SPI
// target on the spi_host and spi2 pads.

module vdrv_spi_mem #(
    parameter string NAME = "SPI_MEM"
) (
    input  logic       sck_i,
    input  logic       csb_i,
    input  logic [3:0] sd_i,
    output logic [3:0] sd_o,
    output logic [3:0] sd_oe
);

  import tb_pkg::*;

  spiflash flash_i (
      .csb  (csb_i),
      .clk  (sck_i),
      .io_i (sd_i),
      .io_o (sd_o),
      .io_oe(sd_oe)
  );

  // Clears the memory and loads a byte-wise hex file into it
  task automatic load(input string file);
    for (int i = 0; i < 16 * 1024 * 1024; i++) flash_i.memory[i] = 8'h00;
    $readmemh(file, flash_i.memory);
    tb_info(NAME, $sformatf("loaded %s", file));
  endtask

endmodule
