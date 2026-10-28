# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Test results.

The testbench decides whether a simulation passed: tb_top prints
"[TB] RESULT: <PASS|FAIL> code=<n> ..." (see tb/tb_pkg.sv, result_e) and
exits with a non-zero status on failure. The flow only adds the failures the
testbench cannot report: build and compile errors, simulations killed by the
wall-clock timeout, and simulations that ended without a result line.
"""

import enum
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, Optional, Tuple

from .proc import ProcResult


class Status(str, enum.Enum):
    PASS = "PASS"
    # Reported by the testbench (tb_pkg::result_e)
    SW_FAIL = "SW_FAIL"
    DRIVER_FAIL = "DRIVER_FAIL"
    TIMEOUT = "TIMEOUT"
    CONFIG_ERROR = "CONFIG_ERROR"
    BOOT_FAIL = "BOOT_FAIL"
    # Reported by the flow
    BUILD_FAIL = "BUILD_FAIL"  # mcu-gen or elaboration failed
    COMPILE_FAIL = "COMPILE_FAIL"  # sw compilation failed
    HANG = "HANG"  # killed by the flow's wall-clock timeout
    ERROR = "ERROR"  # simulation ended without a valid result line
    NOT_RUN = "NOT_RUN"

    @property
    def passed(self) -> bool:
        return self is Status.PASS


# tb_pkg::result_e codes
_TB_CODES = {
    0: Status.PASS,
    1: Status.SW_FAIL,
    2: Status.DRIVER_FAIL,
    3: Status.TIMEOUT,
    4: Status.CONFIG_ERROR,
    5: Status.BOOT_FAIL,
}

_RESULT_RE = re.compile(r"\[TB\] RESULT: (PASS|FAIL) code=(\d+)(.*)")
_SW_EXIT_RE = re.compile(r"sw_exit=(\S+)")
_ERROR_RE = re.compile(r"\] \[(\w+)\] ERROR: (.*)")


@dataclass
class TestResult:
    name: str
    status: Status = Status.NOT_RUN
    message: str = ""
    sw_exit: Optional[str] = None
    durations_s: Dict[str, float] = field(default_factory=dict)
    out_dir: Optional[Path] = None
    log_tail: str = ""

    @property
    def duration_s(self) -> float:
        return sum(self.durations_s.values())

    def to_dict(self) -> dict:
        d = asdict(self)
        d["status"] = self.status.value
        d["out_dir"] = str(self.out_dir) if self.out_dir else None
        d["duration_s"] = round(self.duration_s, 2)
        return d


def classify_simulation(proc: ProcResult) -> Tuple[Status, str, Optional[str]]:
    """Turns a finished simulation into (status, message, sw_exit)."""
    if proc.timed_out:
        return (
            Status.HANG,
            f"killed after {proc.duration_s:.0f} s by the flow timeout",
            None,
        )

    try:
        text = proc.log_file.read_text(errors="replace")
    except OSError as exc:
        return Status.ERROR, f"cannot read the simulation log: {exc}", None

    match = _RESULT_RE.search(text)
    if not match:
        return (
            Status.ERROR,
            f"no '[TB] RESULT' line (simulator exit code {proc.returncode})",
            None,
        )

    code = int(match.group(2))
    status = _TB_CODES.get(code, Status.ERROR)
    sw_exit = _SW_EXIT_RE.search(match.group(3))
    sw_exit = sw_exit.group(1) if sw_exit else ("0" if status.passed else None)

    # The testbench result and the process status must agree
    if status.passed and proc.returncode != 0:
        return (
            Status.ERROR,
            f"result PASS but simulator exit code {proc.returncode}",
            sw_exit,
        )

    if status.passed:
        return status, "", sw_exit
    first_error = _ERROR_RE.search(text)
    detail = f"{first_error.group(1)}: {first_error.group(2)}" if first_error else ""
    message = match.group(0).strip()
    return status, message + (f" | {detail}" if detail else ""), sw_exit
