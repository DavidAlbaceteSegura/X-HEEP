# Automatic testing

X-HEEP is tested with a regression flow driven by hjson files (`ci/run_flow.py`). It runs locally and is meant to be called by the CI server (Jenkins, Azure, ...), which only has to run it and publish its reports.

## Regression flow

A regression file describes one hardware build (mcu-gen configuration, pads, elaboration defines, simulator) and a list of tests, each with its software compilation and simulation parameters and its tags. The flow runs mcu-gen and the elaboration once, then compiles and simulates every selected test:

```bash
python ci/run_flow.py ci/regressions/smoke.hjson                  # every test
python ci/run_flow.py ci/regressions/smoke.hjson --tags smoke     # tests tagged smoke
python ci/run_flow.py ci/regressions/smoke.hjson --tags gpio,spi  # gpio OR spi
python ci/run_flow.py ci/regressions/smoke.hjson --tags boot+jtag # boot AND jtag
python ci/run_flow.py ci/regressions/smoke.hjson --list           # show the selection only
```

The exit status is 0 when every selected test passed, 1 when one failed and 2 on a configuration error. Pass/fail comes from the testbench result line (see [Testbench](../How_to/Testbench.md)).

Reports and artifacts are written to `build/flow/<regression>/`: `summary.json`, `junit.xml` (for the CI test report), `run.log`, the build logs and one folder per test with its logs, firmware and UART output.

See `ci/README.md` for the regression file format, the result statuses and the supported simulators.

## In a CI pipeline

A pipeline needs three steps:

1. Check out the repository and set up the environment (e.g. the `x-heep-toolchain` Docker image, see `util/docker`).
2. Run `python ci/run_flow.py <regression>.hjson [--tags ...]`.
3. Publish `build/flow/<regression>/junit.xml` as test results (Jenkins `junit`, Azure `PublishTestResults@2`) and archive `build/flow/<regression>/`.

The following repository checks are not part of the regression flow. Add them to the pipeline as separate steps if you need them:

```bash
# Generated files are up to date
make mcu-gen && util/git-diff.py --error-msg "Found differences in generated files. Run mcu-gen and commit the changes."

# Vendored code is up to date
find hw/vendor hw/fpga sw/vendor util -maxdepth 2 -type f -name '*.vendor.hjson' | xargs -P8 -n1 util/vendor.py --verbose && \
  util/git-diff.py --error-msg "Found differences in vendored files." && util/check-vendor.py

# Python formatting
make format-python && util/git-diff.py --error-msg "Python files are not formatted."
```
