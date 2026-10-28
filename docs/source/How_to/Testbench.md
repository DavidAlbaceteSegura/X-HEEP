# Use the SoC testbench

The testbench in `tb/` tests X-HEEP from its pads: the firmware runs on the CPU and talks to testbench drivers (JTAG, UART, SPI, GPIO, I2C, ...) through the real pins. This page shows how to run a test, pick the boot mode, connect the pads a test needs and read the result. See [Simulate](Simulate.md) for the full list of plusargs.

## Quick start

```bash
make mcu-gen
make verilator-build
make app PROJECT=hello_world
make verilator-run
```

The run ends with one result line:

```
[TB] RESULT: PASS code=0 errors=0 warnings=0
```

What the firmware prints over the UART is in `uart0.log` in the simulation folder (`build/openhwgroup.org_systems_core-v-mini-mcu_<version>/sim-verilator`).

## How it is organized

```
tb_top                      clock, reset, simulation flow, verdict
└── testharness             X-HEEP, connected through its pads only
    ├── x_heep_system       DUT
    ├── vinterconnect       connects DUT pads to the drivers (+tb_route)
    └── vdrivers            protocol drivers
        ├── jtag_i          JTAG master (loads firmware through the debug module)
        ├── uart_i          UART receiver/transmitter -> uart0.log
        ├── flash_i         boot SPI flash
        ├── spi_mem_i       SPI memory on the spi_host pads
        ├── spi2_mem_i      SPI memory on the spi2 pads
        ├── gpio_drv_i      GPIO loopback/drive/monitor
        ├── i2c_i           I2C target (register file)
        ├── i2s_mic_i       I2S microphone
        └── pdm_mic_i       PDM microphone
```

`tb_top` runs the whole flow from a single `initial` block: load the flash, reset, boot, wait for the firmware to exit, ask every driver for its verdict, then print the result and end the simulation.

## Choose how the firmware is loaded

Use `BOOT=<mode>` with `make`, or `+boot=<mode>` on the simulator command line.

| Mode | What happens | When to use it |
|------|--------------|----------------|
| `backdoor` (default) | The testbench writes the firmware straight into the SRAM. | Day-to-day runs; fastest. |
| `jtag` | The JTAG driver writes the firmware through the debug module, like a real debugger, then starts the CPU. | Testing the debug path. Slower (about 1 minute for `hello_world`). Add `SIM_ARGS="+jtag_verify"` to read every word back. |
| `flash` | The CPU boots from the SPI flash driver. | Testing flash boot. Compile the app with `LINKER=flash_load` or `LINKER=flash_exec`. |

```bash
make verilator-run BOOT=jtag
make app PROJECT=hello_world LINKER=flash_load && make verilator-run BOOT=flash
```

## Connect the pads your test needs

JTAG, UART and the boot flash are always connected. Every other pad is left unconnected (only a pull-up or pull-down) unless a *route* connects it to a driver. Select routes with `TB_ROUTE`:

```bash
make verilator-run TB_ROUTE=gpio
make verilator-run TB_ROUTE=i2c,gpio
```

| Route | Connects | Driver behavior |
|-------|----------|-----------------|
| `gpio` | every GPIO pad not used by another route | Loops GPIO 30 back to GPIO 31 by default |
| `i2c` | `i2c_scl`, `i2c_sda` | I2C target answering addresses 0x48, 0x6B and 0x50 |
| `spi_host` | `spi_*` | SPI NOR flash model |
| `spi2` | `spi2_*` | SPI NOR flash model |
| `spi_slave` | `spi_*` and `spi_slave_*` | SPI host looped back to the debug SPI slave |
| `i2s` | `i2s_*` | I2S microphone |
| `pdm2pcm` | `pdm2pcm_*` | PDM microphone |

Many of these pads are shared with GPIOs. If two routes need the same pad, the test stops with a configuration error. `gpio` only takes the GPIO pads the other routes left free, so it can be combined with anything.

If your app uses a pad, it needs its route. Without it the firmware usually waits forever and the test ends in a timeout. In a regression file, set it with `sim: { tb_route: "..." }` (see `ci/README.md`).

## Configure a driver

Drivers read their own plusargs. Pass them with `SIM_ARGS`:

```bash
make verilator-run TB_ROUTE=gpio SIM_ARGS="+gpio_loop=8:9,30:31 +gpio_expect_toggle=100"
make verilator-run TB_ROUTE=i2c SIM_ARGS="+i2c_addr=48 +i2c_expect_txn=2"
make verilator-run SIM_ARGS="+uart_expect=hello"
```

| Driver | Plusargs |
|--------|----------|
| UART | `+uart_echo` (print lines to the log), `+uart_expect=<text>` (fail if never printed), `+uart_send=<text>` (send to the firmware after boot), `+uart_baud=<n>` |
| GPIO | `+gpio_loop=<out>:<in>,...`, `+gpio_drive=<mask>:<value>` (hex), `+gpio_expect_toggle=<mask>` (hex), `+gpio_monitor` |
| I2C | `+i2c_addr=<hex>,...`, `+i2c_mem=<file>` (initial register values), `+i2c_expect_txn=<n>` |
| JTAG | `+jtag_verify`, `+jtag_tck_ns=<n>` |

Use the `expect` plusargs to make the testbench check the firmware from the outside: the test fails even if the firmware returns 0.

## Read the result

A test passes only if the firmware exits with 0 **and** no driver reported an error. On failure the simulator exits with a non-zero status, and the result line gives the reason:

| Code | Name | Meaning |
|------|------|---------|
| 0 | `PASS` | Firmware returned 0, no driver errors |
| 1 | `SW_FAIL` | Firmware returned a non-zero value (`sw_exit=` shows it) |
| 2 | `DRIVER_FAIL` | A driver reported an error, e.g. a missed `+uart_expect` |
| 3 | `TIMEOUT` | The firmware did not exit within `MAX_SIM_TIME` |
| 4 | `CONFIG_ERROR` | Unknown route or boot mode, conflicting routes, no firmware |
| 5 | `BOOT_FAIL` | The JTAG driver could not load the firmware |

The lines above the result tell you which check failed, for example:

```
[   103065 ns] [UART] ERROR: expected text 'goodbye' was not received
[TB] RESULT: FAIL code=2 (DRIVER_FAIL) sw_exit=0 errors=1 warnings=0
```

## Useful options

- `MAX_SIM_TIME=<cycles>` (or `750us`, `2ms`, ...): stop with a timeout instead of running forever.
- `SIM_ARGS="+waves"`: dump `waveform.fst` (Verilator) or `waveform.vcd`.
- `SIM_ARGS="+verbose"`: more messages from the testbench and the drivers.

## Add a driver

1. Write the driver in `tb/vdrivers/` with plain input/output/output-enable signals: no tristates, `vinterconnect` handles them. Report problems with `tb_pkg::tb_error()` and add a `final_check()` function for end-of-test checks.
2. Instantiate it in `tb/vdrivers/vdrivers.sv` and call its `final_check()` from `vdrivers.final_check()`.
3. If it needs shared pads, add a route to `tb_pkg::route_e` (and `route_name()`), list its pads in `vinterconnect.route_pads()` and connect them in the `always_comb` block of `vinterconnect`.
4. Add the file to the `tb-drivers` fileset in `tb/x-heep-tb-utils.core`.

## Limitations

- X-HEEP is reached only through its pads: its bus, peripheral and DMA ports, external interrupts and CV-X-IF are tied off. Apps that use external bus devices or coprocessors cannot run in this testbench.
- The I2C, SPI memory (`spi_host`, `spi2`) and PDM routes have not been tested end to end with an app yet.
