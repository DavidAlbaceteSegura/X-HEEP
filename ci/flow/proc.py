# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Runs external commands with their output written to a log file."""

import os
import shlex
import signal
import subprocess
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional, Sequence

from . import log

_log = log.get("proc")

# Commands run with the C locale so that tool output (e.g. readelf, parsed by
# the sw build) does not depend on the user's language.
_BASE_ENV = {"LC_ALL": "C", "LANG": "C"}


@dataclass
class ProcResult:
    cmd: str
    returncode: Optional[int]  # None if the command timed out
    duration_s: float
    log_file: Path

    @property
    def timed_out(self) -> bool:
        return self.returncode is None

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    def tail(self, lines: int = 30) -> str:
        """Last lines of the command output."""
        try:
            with open(self.log_file, errors="replace") as f:
                return "".join(deque(f, maxlen=lines))
        except OSError:
            return ""


def run(
    cmd: Sequence[str],
    log_file: Path,
    cwd: Path,
    timeout_s: Optional[float] = None,
    env: Optional[Mapping[str, str]] = None,
) -> ProcResult:
    """Runs cmd in cwd, with stdout and stderr written to log_file. On
    timeout the whole process group is killed."""
    cmd_str = shlex.join(str(c) for c in cmd)
    _log.debug("$ (cd %s && %s)", cwd, cmd_str)
    log_file.parent.mkdir(parents=True, exist_ok=True)
    full_env = {**os.environ, **_BASE_ENV, **(env or {})}

    start = time.monotonic()
    with open(log_file, "w") as out:
        out.write(f"$ (cd {cwd} && {cmd_str})\n")
        out.flush()
        proc = subprocess.Popen(
            [str(c) for c in cmd],
            cwd=cwd,
            env=full_env,
            stdout=out,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            returncode = proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            returncode = None
            out.write(f"\n[flow] killed after {timeout_s} s\n")
    return ProcResult(cmd_str, returncode, time.monotonic() - start, log_file)
