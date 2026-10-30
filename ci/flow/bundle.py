# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Bundles: let a job reuse what another job (e.g. on another CI agent)
produced instead of redoing it.

- mcu-gen.tar.gz: the files written by mcu-gen (see generated_files).
- sim-build.tar.gz: the elaborated model, i.e. the files the simulator needs
  at run time (see Simulator.bundle_paths).

A bundle holds its files at their path in the repository, plus
build_info.json. It is extracted at the same place, so relative paths used by
the testbench and the sw build keep working.
"""

import json
import os
import subprocess
import tarfile
from pathlib import Path
from typing import List

from . import log

_log = log.get("bundle")
_INFO = "build_info.json"

# Never part of the generated sources: VCS, Python env, build outputs
_SKIP_DIRS = {".git", ".venv", "__pycache__"}
_SKIP_PATHS = ("build", "sw/build")


def pack(repo: Path, paths: List[Path], build_info: dict, out_file: Path) -> None:
    out_file.parent.mkdir(parents=True, exist_ok=True)
    info_file = out_file.parent / _INFO
    info_file.write_text(json.dumps(build_info, indent=2))
    with tarfile.open(out_file, "w:gz") as tar:
        for path in paths:
            tar.add(path, arcname=str(path.relative_to(repo)))
        tar.add(info_file, arcname=_INFO)
    _log.info("bundle: %s (%.1f MB)", out_file, out_file.stat().st_size / 1e6)


def unpack(bundle: Path, repo: Path) -> dict:
    """Extracts the bundle into the repository and returns its build_info."""
    with tarfile.open(bundle, "r:gz") as tar:
        members = [m for m in tar.getmembers() if m.name != _INFO]
        # Safe extraction filter, when this Python has it (>= 3.12)
        kwargs = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
        tar.extractall(repo, members=members, **kwargs)
        info = json.load(tar.extractfile(_INFO))
    _log.info(
        "restored %d file(s) from %s (commit %s)",
        len(members),
        bundle,
        info.get("git_commit"),
    )
    return info


def generated_files(repo: Path, since: float) -> List[Path]:
    """Files written by a generator started at time `since`: untracked (or
    ignored) files and modified tracked files, newer than `since`. Tracked
    files rewritten with the same content (e.g. by the formatters) are left
    out."""

    def git(*args: str) -> set:
        out = subprocess.run(
            ["git", *args], cwd=repo, capture_output=True, text=True, check=True
        ).stdout
        return set(out.splitlines())

    tracked = git("ls-files")
    modified = git("ls-files", "--modified")
    found = []
    for root, dirs, files in os.walk(repo):
        rel_root = Path(root).relative_to(repo)
        dirs[:] = [
            d
            for d in dirs
            if d not in _SKIP_DIRS and str(rel_root / d) not in _SKIP_PATHS
        ]
        for name in files:
            path = Path(root) / name
            rel = str(rel_root / name)
            if (
                rel not in tracked or rel in modified
            ) and path.lstat().st_mtime >= since:
                found.append(path)
    return sorted(found)
