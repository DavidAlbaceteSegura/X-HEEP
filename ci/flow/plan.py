# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Test plan: the selected tests with their resolved parameters.

Written by the planning step (run_flow.py --plan) and read by every test job
(run_flow.py --from-plan), so that all jobs run exactly what was planned,
whatever happens to the regression file in between. It also holds the matrix
a CI server uses to start one job per test.
"""

import dataclasses
import json
from pathlib import Path
from typing import Dict, List, Tuple

from .config import BuildCfg, ConfigError, FlowCfg, SimCfg, SimulatorCfg, SwCfg, TestCfg

PLAN_VERSION = 1


def write(
    path: Path, cfg: FlowCfg, tests: List[TestCfg], selection: Dict, git_commit: str
) -> None:
    data = {
        "version": PLAN_VERSION,
        "regression": cfg.name,
        "config_file": str(cfg.path),
        "git_commit": git_commit,
        "selection": selection,
        "build": dataclasses.asdict(cfg.build),
        "tests": [dataclasses.asdict(t) for t in tests],
        # One entry per test job: {job name: {variables}}
        "matrix": {_job_name(t.name): {"TEST_NAME": t.name} for t in tests},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2))


def load(path: Path) -> Tuple[FlowCfg, List[TestCfg]]:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    if data.get("version") != PLAN_VERSION:
        raise ConfigError(f"{path}: unsupported plan version {data.get('version')}")

    b = data["build"]
    build = BuildCfg(**{**b, "simulator": SimulatorCfg(**b["simulator"])})
    tests = [
        TestCfg(**{**t, "sw": SwCfg(**t["sw"]), "sim": SimCfg(**t["sim"])})
        for t in data["tests"]
    ]
    cfg = FlowCfg(
        name=data["regression"],
        path=Path(data["config_file"]),
        build=build,
        tests=tests,
    )
    return cfg, tests


def _job_name(test: str) -> str:
    """CI job names only allow letters, digits and underscores."""
    return "".join(c if c.isalnum() else "_" for c in test)
