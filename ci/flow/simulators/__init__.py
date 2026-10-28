# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Simulator backends, by the name used in the hjson."""

from pathlib import Path
from typing import Dict, Type

from ..config import ConfigError, SimulatorCfg
from .base import Simulator
from .verilator import Verilator
from .xcelium import Xcelium

REGISTRY: Dict[str, Type[Simulator]] = {cls.name: cls for cls in (Verilator, Xcelium)}


def create(repo: Path, cfg: SimulatorCfg) -> Simulator:
    try:
        return REGISTRY[cfg.name](repo, cfg)
    except KeyError:
        raise ConfigError(
            f"unknown simulator '{cfg.name}', available: {sorted(REGISTRY)}"
        ) from None
