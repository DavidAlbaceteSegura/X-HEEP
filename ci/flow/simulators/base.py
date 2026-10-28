# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Simulator interface.

A backend knows how to elaborate the testbench once and how to run one
simulation on that build. It does not judge results: every simulator runs the
same tb_top, whose result line is parsed by results.classify_simulation().

Adding a simulator: subclass Simulator in a new module and register it in
simulators/__init__.py.
"""

import shutil
import sys
from abc import ABC, abstractmethod
from pathlib import Path
from typing import List, Mapping, Optional, Sequence

from .. import log, proc
from ..config import Defines, SimulatorCfg, define_items

CORE = "openhwgroup.org:systems:core-v-mini-mcu"


class Simulator(ABC):
    #: name used in the hjson (build.simulator.name)
    name: str = ""
    #: FuseSoC tool name
    tool: str = ""
    #: waveform file written by tb_top with +waves
    waves_name: str = "waveform.vcd"

    def __init__(self, repo: Path, cfg: SimulatorCfg):
        self.repo = repo
        self.cfg = cfg
        self.log = log.get(f"sim.{self.name}")

    # ---------------------------------------------------------------------
    # To be provided by each backend
    # ---------------------------------------------------------------------
    @abstractmethod
    def define_flag(self, name: str, value: Optional[object]) -> List[str]:
        """Command-line flags defining a macro for the whole elaboration."""

    @abstractmethod
    def _elaborate(self, extra_args: List[str], log_file: Path, timeout_s: float) -> proc.ProcResult:
        """Builds the simulation model in work_dir (FuseSoC setup is done)."""

    @abstractmethod
    def run(self, plusargs: Sequence[str], log_file: Path, timeout_s: float) -> proc.ProcResult:
        """Runs one simulation on the existing build. Plusargs include the
        leading '+'. Output files (uart0.log, waves) end up in work_dir."""

    # ---------------------------------------------------------------------
    # Common
    # ---------------------------------------------------------------------
    @property
    def work_dir(self) -> Path:
        """FuseSoC work root of this tool: build/<core>/sim-<tool>."""
        dirs = sorted(self.repo.glob(f"build/openhwgroup.org_systems_core-v-mini-mcu_*/sim-{self.tool}"))
        if not dirs:
            raise FileNotFoundError(f"no FuseSoC work directory for {self.tool}, run the build first")
        return dirs[-1]

    @property
    def waves_file(self) -> Path:
        return self.work_dir / self.waves_name

    def fusesoc(self, stage: str) -> List[str]:
        """FuseSoC command for one stage (--setup, --build or --run)."""
        exe = Path(sys.executable).parent / "fusesoc"
        fusesoc = str(exe) if exe.exists() else (shutil.which("fusesoc") or "fusesoc")
        return [fusesoc, "--cores-root", ".", "run", "--no-export", "--target=sim",
                f"--tool={self.tool}", f"--{stage}", CORE]

    def build(
        self, defines: Defines, log_dir: Path, timeout_s: float, env: Mapping[str, str]
    ) -> proc.ProcResult:
        """FuseSoC setup, then elaboration with the extra defines and the
        hjson build_args. env: variables the Makefile would export (the
        setup generates the boot ROM with the RISC-V toolchain)."""
        setup = proc.run(self.fusesoc("setup"), log_dir / "setup.log", self.repo, timeout_s, env)
        if not setup.ok:
            return setup
        extra = [flag for name, val in define_items(defines) for flag in self.define_flag(name, val)]
        extra += self.cfg.build_args
        if extra:
            self.log.info("extra elaboration options: %s", " ".join(extra))
        return self._elaborate(extra, log_dir / "build.log", timeout_s)

    def clean_outputs(self) -> None:
        """Removes per-run outputs so that a test never sees the previous one's."""
        for name in ("uart0.log", self.waves_name):
            path = self.work_dir / name
            if path.exists():
                path.unlink()

    @staticmethod
    def _append_make_var(makefile: Path, var: str, args: Sequence[str]) -> None:
        """Appends 'var += args' to a generated makefile."""
        if not args:
            return
        line = f"\n# Added by the regression flow\n{var} += {' '.join(args)}\n"
        with open(makefile, "a") as f:
            f.write(line)
