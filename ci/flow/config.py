# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Loads and validates a regression description (hjson).

    {
      build: {                          // one mcu-gen + elaboration per run
        x_heep_cfg: "configs/general.hjson"
        pads_cfg:   "configs/pad_cfg.py"
        compiler_prefix: "riscv32-corev-"   // toolchain for the boot ROM (optional)
        defines:    { NAME: value }     // elaboration defines
        simulator:  { name: "verilator", build_args: [], run_args: [] }
      }
      defaults: { timeout_s: 600, sw: {...}, sim: {...} }   // merged into every test
      tests: [
        { name: "...", tags: [...], timeout_s: 600,
          sw:  { project, linker, compiler, compiler_prefix, arch, defines },
          sim: { boot, tb_route, max_sim_time, plusargs, waves } }
      ]
    }

Define values: true -> NAME, false -> not defined (removes an inherited
define), number or string -> NAME=value.
Merging defaults into a test: dicts merge (the test wins), lists add up.
"""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import hjson


class ConfigError(Exception):
    pass


Defines = Dict[str, Any]


@dataclass
class SimulatorCfg:
    name: str
    build_args: List[str] = field(default_factory=list)
    run_args: List[str] = field(default_factory=list)


@dataclass
class BuildCfg:
    x_heep_cfg: str
    pads_cfg: str
    simulator: SimulatorCfg
    defines: Defines = field(default_factory=dict)
    # Toolchain used by the hardware build (boot ROM); None: same
    # auto-detection as the Makefile
    compiler_prefix: Optional[str] = None


@dataclass
class SwCfg:
    project: str
    linker: str = "on_chip"
    compiler: str = "gcc"
    compiler_prefix: str = "riscv32-corev-"
    arch: Optional[str] = None
    defines: Defines = field(default_factory=dict)


@dataclass
class SimCfg:
    boot: str = "backdoor"
    tb_route: List[str] = field(default_factory=list)
    max_sim_time: Optional[str] = None
    plusargs: List[str] = field(default_factory=list)
    waves: bool = False


@dataclass
class TestCfg:
    name: str
    sw: SwCfg
    sim: SimCfg
    tags: List[str] = field(default_factory=list)
    timeout_s: float = 600


@dataclass
class FlowCfg:
    name: str
    path: Path
    build: BuildCfg
    tests: List[TestCfg]


_SECTION_KEYS = {
    "top": {"build", "defaults", "tests"},
    "build": {"x_heep_cfg", "pads_cfg", "compiler_prefix", "defines", "simulator"},
    "simulator": {"name", "build_args", "run_args"},
    "defaults": {"timeout_s", "tags", "sw", "sim"},
    "test": {"name", "tags", "timeout_s", "sw", "sim"},
    "sw": {"project", "linker", "compiler", "compiler_prefix", "arch", "defines"},
    "sim": {"boot", "tb_route", "max_sim_time", "plusargs", "waves"},
}
_BOOT_MODES = {"backdoor", "jtag", "flash"}


def _check_keys(section: str, data: Dict[str, Any], where: str) -> None:
    if not isinstance(data, dict):
        raise ConfigError(f"{where}: expected an object")
    unknown = set(data) - _SECTION_KEYS[section]
    if unknown:
        raise ConfigError(
            f"{where}: unknown key(s) {sorted(unknown)}, "
            f"expected {sorted(_SECTION_KEYS[section])}"
        )


def _merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    """Dicts merge recursively (override wins), lists are concatenated."""
    out = dict(base)
    for key, val in override.items():
        if isinstance(val, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], val)
        elif isinstance(val, list) and isinstance(out.get(key), list):
            out[key] = out[key] + val
        else:
            out[key] = val
    return out


def _as_list(val: Any) -> List[str]:
    """Accepts "a,b" or ["a", "b"]."""
    if val is None:
        return []
    if isinstance(val, str):
        return [v.strip() for v in val.split(",") if v.strip()]
    return [str(v) for v in val]


def _check_defines(defines: Any, where: str) -> Defines:
    if not isinstance(defines, dict):
        raise ConfigError(f"{where}: defines must be an object")
    for name, val in defines.items():
        if val is None or isinstance(val, (dict, list)):
            raise ConfigError(
                f"{where}: define {name} must be true, false, a number or a string"
            )
    return dict(defines)


def define_items(defines: Defines):
    """Yields (name, value) for the active defines; value is None for a
    define without value."""
    for name, val in defines.items():
        if val is False:
            continue
        yield name, (None if val is True else val)


def _parse_test(raw: Dict[str, Any], where: str) -> TestCfg:
    _check_keys("test", raw, where)
    if "name" not in raw:
        raise ConfigError(f"{where}: missing 'name'")
    sw_raw = raw.get("sw", {})
    sim_raw = raw.get("sim", {})
    _check_keys("sw", sw_raw, f"{where}.sw")
    _check_keys("sim", sim_raw, f"{where}.sim")
    if "project" not in sw_raw:
        raise ConfigError(f"{where}.sw: missing 'project'")

    sw = SwCfg(**{k: v for k, v in sw_raw.items() if k != "defines"})
    sw.defines = _check_defines(sw_raw.get("defines", {}), f"{where}.sw")
    sim = SimCfg(**{k: v for k, v in sim_raw.items() if k != "tb_route"})
    sim.tb_route = _as_list(sim_raw.get("tb_route"))
    if isinstance(sim.plusargs, str):
        sim.plusargs = [sim.plusargs]
    if sim.boot not in _BOOT_MODES:
        raise ConfigError(f"{where}.sim: boot must be one of {sorted(_BOOT_MODES)}")
    if sim.boot == "flash" and sw.linker == "on_chip":
        raise ConfigError(f"{where}: boot 'flash' needs linker flash_load or flash_exec")

    return TestCfg(
        name=str(raw["name"]),
        sw=sw,
        sim=sim,
        tags=_as_list(raw.get("tags")),
        timeout_s=float(raw.get("timeout_s", 600)),
    )


def load(path: Path) -> FlowCfg:
    try:
        data = hjson.loads(path.read_text())
    except (OSError, hjson.HjsonDecodeError) as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    _check_keys("top", data, str(path))

    build_raw = data.get("build")
    if build_raw is None:
        raise ConfigError(f"{path}: missing 'build'")
    _check_keys("build", build_raw, "build")
    sim_raw = build_raw.get("simulator", {"name": "verilator"})
    if isinstance(sim_raw, str):
        sim_raw = {"name": sim_raw}
    _check_keys("simulator", sim_raw, "build.simulator")
    if "name" not in sim_raw:
        raise ConfigError("build.simulator: missing 'name'")
    build = BuildCfg(
        x_heep_cfg=build_raw.get("x_heep_cfg", "configs/general.hjson"),
        pads_cfg=build_raw.get("pads_cfg", "configs/pad_cfg.py"),
        simulator=SimulatorCfg(
            name=sim_raw["name"],
            build_args=_as_list(sim_raw.get("build_args")),
            run_args=_as_list(sim_raw.get("run_args")),
        ),
        defines=_check_defines(build_raw.get("defines", {}), "build"),
        compiler_prefix=build_raw.get("compiler_prefix"),
    )

    defaults = data.get("defaults", {})
    _check_keys("defaults", defaults, "defaults")
    tests = []
    for i, raw in enumerate(data.get("tests", [])):
        where = f"tests[{i}]" + (f" ({raw['name']})" if isinstance(raw, dict) and "name" in raw else "")
        _check_keys("test", raw, where)
        tests.append(_parse_test(_merge(defaults, raw), where))

    names = [t.name for t in tests]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise ConfigError(f"{path}: duplicate test names {dupes}")
    return FlowCfg(name=path.stem, path=path, build=build, tests=tests)


def select(
    tests: List[TestCfg],
    tags: Optional[str] = None,
    exclude_tags: Optional[str] = None,
    names: Optional[List[str]] = None,
) -> List[TestCfg]:
    """Selects tests by name and tags.

    tags: comma separated alternatives, each a '+' separated set of tags
    that must all be present, e.g. "smoke,gpio+nightly" selects tests tagged
    smoke, or tagged both gpio and nightly. exclude_tags: comma separated, a
    test with any of them is dropped."""
    selected = tests
    if names:
        unknown = set(names) - {t.name for t in tests}
        if unknown:
            raise ConfigError(f"unknown test(s) {sorted(unknown)}")
        selected = [t for t in selected if t.name in names]
    if tags:
        groups = [set(g.split("+")) for g in _as_list(tags)]
        selected = [t for t in selected if any(g <= set(t.tags) for g in groups)]
    if exclude_tags:
        excluded = set(_as_list(exclude_tags))
        selected = [t for t in selected if not excluded & set(t.tags)]
    return selected
