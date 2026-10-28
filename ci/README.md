# Regression flow

`ci/run_flow.py` runs a regression described by an hjson file: mcu-gen and
elaboration once, then for every selected test the software compilation and
the simulation. CI (Jenkins, Azure, ...) only calls it and publishes
`junit.xml` and the output folder.

```bash
python ci/run_flow.py ci/regressions/smoke.hjson                  # everything
python ci/run_flow.py ci/regressions/smoke.hjson --tags smoke     # by tag
python ci/run_flow.py ci/regressions/smoke.hjson --tags gpio,spi  # gpio OR spi
python ci/run_flow.py ci/regressions/smoke.hjson --tags boot+jtag # boot AND jtag
python ci/run_flow.py ci/regressions/smoke.hjson --exclude-tags jtag
python ci/run_flow.py ci/regressions/smoke.hjson --test hello_jtag --waves
python ci/run_flow.py ci/regressions/smoke.hjson --list           # show the selection only
python ci/run_flow.py ci/regressions/smoke.hjson --skip-build     # reuse the last build
```

Exit status: 0 when every selected test passed, 1 when one failed, 2 on a
configuration error.

## Regression file

See `ci/regressions/smoke.hjson` and the docstring of `ci/flow/config.py`.

- `build`: the hardware, built once per run: `x_heep_cfg`, `pads_cfg`,
  `defines` (passed to the elaboration of every simulator) and
  `simulator: { name, build_args, run_args }`.
- `defaults`: merged into every test. Objects merge (the test wins), lists add up.
- `tests`: `name`, `tags`, `timeout_s` (wall clock), `sw` (`project`, `linker`,
  `compiler`, `compiler_prefix`, `arch`, `defines`) and `sim` (`boot`,
  `tb_route`, `max_sim_time`, `plusargs`, `waves`).

Defines: `true` defines the name, `false` removes an inherited define, a
number or string gives `NAME=value`. Unknown keys are rejected.

## Pass/fail

The testbench decides: `tb_top` prints `[TB] RESULT: ... code=<n>`. The flow
maps it to a status and adds only what the testbench cannot see:

| Status | Meaning |
|---|---|
| `PASS` | firmware exited with 0, no driver error |
| `SW_FAIL`, `DRIVER_FAIL`, `TIMEOUT`, `CONFIG_ERROR`, `BOOT_FAIL` | testbench result codes 1 to 5 |
| `BUILD_FAIL` | mcu-gen or elaboration failed, no test ran |
| `COMPILE_FAIL` | `make app` failed |
| `HANG` | killed by the test's `timeout_s` |
| `ERROR` | the simulation ended without a result line |

## Output

Default `build/flow/<regression>/`:

```
run.log  summary.json  junit.xml
build/   mcugen.log  setup.log  build.log  build_info.json
<test>/  app.log  main.elf  main.hex  main.map  sim.log  uart0.log  result.json  [waveform.*]
```

## Simulators

Backends live in `ci/flow/simulators/`, one module per simulator, registered in
`__init__.py`. Available: `verilator`, `xcelium` (not tested yet). With
Xcelium, plusarg values cannot contain spaces.
