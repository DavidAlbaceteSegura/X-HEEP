#  Execute Code from FLASH

## Boot Procedure

The microcontroller has a boot rom where the RISC-V CPU jumps to
at reset time.
The boot rom contains code for two different booting modes:

1. JTAG
2. SPI Flash Loading

These two modes are mainly controlled by input pin `boot_sel_i`.

| `boot_sel_i` | `boot procedure`     |
| ------------ | -------------------- |
| 0			   | JTAG                 |
| 1			   | SPI Flash Loading    |


On the FPGA, such inputs are mapped to two switch buttons.
Below, a description of the three modes is provided.

### JTAG Boot Procedure

In this boot procedure, when the CPU enters the boot rom,
it loops until the memory-mapped `BOOT_EXIT_LOOP` flag of `soc_ctrl` is set.
An external JTAG debugger must load the memory through the debug module,
then set the flag. The CPU then jumps to the `boot_address`, a memory-mapped
register that is set to 0x180 at reset time, which is also the boot address
specified in the entry point of the linker scripts.

To use this mode, when targeting ASICs or FPGA bitstreams,
make sure you have the `boot_sel_i` input (e.g., a switch) set to 0,
and connect the JTAG cable to the microcontroller.

In simulation the testbench preloads the memories and sets the flag by
default (`+boot=backdoor`), because a JTAG transfer is slow. To simulate the
actual JTAG procedure, run with `+boot=jtag` (`make verilator-run BOOT=jtag`):
the testbench JTAG driver then loads the firmware through the debug module and
sets the flag, as an external debugger would. See [Testbench](Testbench.md).


### SPI Flash Loading Boot Procedure

In this boot procedure, when the CPU enters the boot rom, it uses the OpenTitan SPI (SPI host) to copy the first 1KB content of the FLASH (starting at address 0) to the RAM (starting at address 0). Then, the CPU jumps to the entry point at 0x00000180 (in RAM) and executes the start function of the crt0 file (which is contained inside the 1KB copied in RAM). This function checks if the code is completely copied (i.e., less or equal to 1 KB); in this case, it jumps to the main function, or, if more code needs to be copied, it uses the OpenTitan SPI to copy the remaining bytes of code.

To use this mode, when targeting ASICs or FPGA bitstreams,
make sure you have the `boot_sel_i` input (e.g., a switch) set to 1.

Make sure to compile your SW using the link_flash_load.ld linker script.

In this repository, we provide two examples to try, one for FPGA/ASIC
only, which toggles a GPIO forever (in simulation, this would never finish),
and the hello_world example.

To use the link_flash_load.ld linker script, do:

```
make app LINKER=flash_load
or
make app PROJECT=gpio_pmw LINKER=flash_load
```
Then, when launching the simulation, pass the argument `boot=flash`
(or the legacy `boot_sel=1`) to set the `boot_sel_i` input to `1`.

```
make run PLUSARGS="c firmware=../../../sw/build/main.hex boot=flash"
```

If you are using FPGAs or ASIC, make sure to program the FLASH first (while in simulation, the FLASH model will load the binary by itself).

Still as experimental and in draft mode, we also developed an HW peripheral that can be used to automatically control reading and writing operations from/to the FLASH, avoiding the execution of long software procedures.
Such peripheral is called `w25q128jw_controller`. Once stable and tested further, this peripheral will replace the software functions as well as the `yosys` SPI module. In addition, the two booting modes that use the FLASH will be unified. Such peripheral has been only tested in simulation.
