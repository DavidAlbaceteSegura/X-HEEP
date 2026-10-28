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

## Split flow (CI)

The build, the test selection and the tests can run in separate jobs:

```bash
# 1. Build: mcu-gen + elaboration, packs the model in <out>/build/sim-build.tar.gz
python ci/run_flow.py ci/regressions/smoke.hjson --build-only
# 2. Plan: selected tests with their resolved parameters, plus the CI matrix
python ci/run_flow.py ci/regressions/smoke.hjson --tags smoke --plan plan.json
# 3. Test (one job per test): runs the planned test on the restored model
python ci/run_flow.py --from-plan plan.json --test hello_jtag --use-build sim-build.tar.gz
```

A test job runs mcu-gen (the sw compilation needs its generated headers) but
does not elaborate. It refuses a bundle built for another configuration,
simulator or set of defines, and warns if it was built at another commit.

### Azure Pipelines

`ci/azure/regression.yml` implements the split flow in three stages:

| Stage | Job(s) | Keeps |
|---|---|---|
| mcu-gen & elaboration | `build` | artifact `sim-build` (elaborated model), `build-logs` |
| test planning | `plan` (runs in parallel with the build) | artifact `test-plan` (`plan.json`) |
| test run | `load_plan`, then one `test` job per planned test, in parallel | `test-<name>` artifacts, one test result per job |

The matrix of the test jobs comes from `load_plan`, in the same stage, which
reads the kept plan: Azure only builds a matrix from a job of the same stage.
The pipeline takes the regression file, tags, excluded tags, agent pool and
maximum parallel jobs as run parameters. The agents need the RISC-V toolchain
(`RISCV_XHEEP`) and the simulator; `ci/azure/setup.yml` checks out the
repository and creates the Python environment.

Not tested on Azure yet. Re-running a single failed test job can fail on
publishing an artifact that already exists for that run.

## Simulators

Backends live in `ci/flow/simulators/`, one module per simulator, registered in
`__init__.py`. Available: `verilator`, `xcelium` (not tested yet). With
Xcelium, plusarg values cannot contain spaces.
