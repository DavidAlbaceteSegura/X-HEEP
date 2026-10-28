# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Verilator: tb_top is built as a standalone binary (--binary --timing)."""

from pathlib import Path
from typing import List, Optional, Sequence

from .. import proc
from .base import Simulator


class Verilator(Simulator):
    name = "verilator"
    tool = "verilator"
    waves_name = "waveform.fst"

    def define_flag(self, name: str, value: Optional[object]) -> List[str]:
        return [f"+define+{name}" if value is None else f"+define+{name}={value}"]

    def _elaborate(self, extra_args: List[str], log_file: Path, timeout_s: float) -> proc.ProcResult:
        # Edalize puts the verilator options in config.mk
        self._append_make_var(self.work_dir / "config.mk", "VERILATOR_OPTIONS", extra_args)
        return proc.run(["make", "binary"], log_file, self.work_dir, timeout_s)

    def run(self, plusargs: Sequence[str], log_file: Path, timeout_s: float) -> proc.ProcResult:
        cmd = ["./Vtb_top", *plusargs, *self.cfg.run_args]
        return proc.run(cmd, log_file, self.work_dir, timeout_s)
