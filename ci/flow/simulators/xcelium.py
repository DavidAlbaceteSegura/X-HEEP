# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Cadence Xcelium.

xrun compiles, elaborates and simulates in one call. The build elaborates the
snapshot once (-elaborate); every test then simulates that snapshot (-R)
without recompiling.

Not tested yet: no Xcelium installation was available when this was written.
"""

import shlex
from pathlib import Path
from typing import List, Optional, Sequence

from .. import proc
from .base import Simulator


class Xcelium(Simulator):
    name = "xcelium"
    tool = "xcelium"
    waves_name = "waveform.vcd"

    # Variable appended to XRUN_OPTIONS in the generated Makefile, set on the
    # make command line to select the step
    _STEP_VAR = "FLOW_XRUN_STEP"

    def define_flag(self, name: str, value: Optional[object]) -> List[str]:
        return ["-define", name if value is None else f"{name}={value}"]

    def _elaborate(self, extra_args: List[str], log_file: Path, timeout_s: float) -> proc.ProcResult:
        self._append_make_var(
            self.work_dir / "Makefile", "XRUN_OPTIONS", [*extra_args, f"$({self._STEP_VAR})"]
        )
        return proc.run(
            ["make", "run", f"{self._STEP_VAR}=-elaborate"], log_file, self.work_dir, timeout_s
        )

    def run(self, plusargs: Sequence[str], log_file: Path, timeout_s: float) -> proc.ProcResult:
        # The edalize Makefile adds the '+' itself; values must not contain spaces
        plusargs_var = " ".join(p.lstrip("+") for p in plusargs)
        step = " ".join(["-R", *(shlex.quote(a) for a in self.cfg.run_args)])
        cmd = ["make", "run", f"PLUSARGS={plusargs_var}", f"{self._STEP_VAR}={step}"]
        return proc.run(cmd, log_file, self.work_dir, timeout_s)
