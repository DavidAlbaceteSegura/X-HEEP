# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Software compilation of one test (make app)."""

import shutil
from pathlib import Path
from typing import List

from . import proc
from .config import SwCfg, define_items

# Files copied from sw/build into the test's output folder
_OUTPUTS = ("main.elf", "main.hex", "main.map")


def define_flags(cfg: SwCfg) -> List[str]:
    return [f"-D{name}" if val is None else f"-D{name}={val}" for name, val in define_items(cfg.defines)]


def compile_app(
    repo: Path, cfg: SwCfg, out_dir: Path, timeout_s: float
) -> proc.ProcResult:
    """Builds cfg.project and copies its outputs to out_dir. The firmware
    to simulate is out_dir/main.hex."""
    cmd = [
        "make",
        "app",
        f"PROJECT={cfg.project}",
        f"LINKER={cfg.linker}",
        f"COMPILER={cfg.compiler}",
        f"COMPILER_PREFIX={cfg.compiler_prefix}",
    ]
    if cfg.arch:
        cmd.append(f"ARCH={cfg.arch}")
    flags = define_flags(cfg)
    if flags:
        # Not applied to coremark, which has its own flags in sw/CMakeLists.txt
        cmd.append(f"COMPILER_FLAGS={' '.join(flags)}")

    result = proc.run(cmd, out_dir / "app.log", repo, timeout_s)
    if result.ok:
        for name in _OUTPUTS:
            src = repo / "sw" / "build" / name
            if src.exists():
                shutil.copy2(src, out_dir / name)
    return result
