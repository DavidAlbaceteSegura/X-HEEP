# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Elaborated build bundle: lets a test job reuse the model elaborated by
another job (e.g. on another CI agent) instead of rebuilding it.

The bundle holds the files the simulator needs at run time (see
Simulator.bundle_paths) at their path in the repository, plus
build_info.json. It is extracted at the same place, so relative paths used by
the testbench keep working.
"""

import json
import tarfile
from pathlib import Path
from typing import List

from . import log

_log = log.get("bundle")
_INFO = "build_info.json"


def pack(repo: Path, paths: List[Path], build_info: dict, out_file: Path) -> None:
    out_file.parent.mkdir(parents=True, exist_ok=True)
    info_file = out_file.parent / _INFO
    info_file.write_text(json.dumps(build_info, indent=2))
    with tarfile.open(out_file, "w:gz") as tar:
        for path in paths:
            tar.add(path, arcname=str(path.relative_to(repo)))
        tar.add(info_file, arcname=_INFO)
    _log.info("build bundle: %s (%.1f MB)", out_file, out_file.stat().st_size / 1e6)


def unpack(bundle: Path, repo: Path) -> dict:
    """Extracts the bundle into the repository and returns its build_info."""
    with tarfile.open(bundle, "r:gz") as tar:
        members = [m for m in tar.getmembers() if m.name != _INFO]
        # Safe extraction filter, when this Python has it (>= 3.12)
        kwargs = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
        tar.extractall(repo, members=members, **kwargs)
        info = json.load(tar.extractfile(_INFO))
    _log.info(
        "restored the %s build from %s (commit %s)",
        info["simulator"],
        bundle,
        info["git_commit"],
    )
    return info
