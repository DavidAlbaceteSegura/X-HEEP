# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Runs a regression: mcu-gen and elaboration once, then sw compile and
simulation of every selected test.

Every step can also run in its own job (e.g. across CI agents):
- gen_only() runs mcu-gen and packs the generated files into
  build/mcu-gen.tar.gz; use_gen=<bundle> restores them instead of running
  mcu-gen.
- build_only() elaborates and packs the model into build/sim-build.tar.gz;
  use_build=<bundle> restores it instead of elaborating.
- compile_sw=False / simulate=False split a test into its compilation and its
  simulation, run one after the other in the same output folder. A compiled
  test that is not simulated yet has the status COMPILED.

Output layout (out_dir):
    run.log  summary.json  junit.xml
    build/   mcugen.log setup.log build.log build_info.json
             [mcu-gen.tar.gz] [sim-build.tar.gz]
    <test>/  app.log main.elf main.hex sim.log uart0.log [waveform.*] result.json
"""

import datetime
import json
import os
import platform
import shutil
import subprocess
import time
from pathlib import Path
from typing import List, Optional, Tuple

from . import bundle, log, proc, report, sw
from .config import FlowCfg, TestCfg
from .results import Status, TestResult, classify_simulation
from .simulators import create as create_simulator

_log = log.get("runner")

BUILD_TIMEOUT_S = 3600
COMPILE_TIMEOUT_S = 600


class Runner:
    def __init__(
        self,
        cfg: FlowCfg,
        tests: List[TestCfg],
        repo: Path,
        out_dir: Path,
        waves: bool = False,
        skip_build: bool = False,
        use_gen: Optional[Path] = None,
        use_build: Optional[Path] = None,
        compile_sw: bool = True,
        simulate: bool = True,
    ):
        self.cfg = cfg
        self.tests = tests
        self.repo = repo
        self.out_dir = out_dir
        self.waves = waves
        self.skip_build = skip_build
        self.use_gen = use_gen
        self.use_build = use_build
        self.compile_sw = compile_sw
        self.simulate = simulate
        self.restored_info: dict = {}
        self.sim = create_simulator(repo, cfg.build.simulator)
        self.build_dir = out_dir / "build"

    # ---------------------------------------------------------------------
    def gen_only(self) -> bool:
        """mcu-gen, then packs the generated files for other jobs."""
        build_info = self._build_info()
        self.build_dir.mkdir(parents=True, exist_ok=True)
        started = time.time() - 1  # margin for coarse file timestamps
        gen_ok, _ = self._generate()
        build_info["gen_ok"] = gen_ok
        if gen_ok:
            bundle.pack(
                self.repo,
                bundle.generated_files(self.repo, started),
                build_info,
                self.build_dir / "mcu-gen.tar.gz",
            )
        (self.build_dir / "build_info.json").write_text(
            json.dumps(build_info, indent=2)
        )
        return gen_ok

    def build_only(self) -> bool:
        """mcu-gen (or its restored files) + elaboration, then packs the
        model for other jobs."""
        build_info = self._build_info()
        build_ok, _ = self._build()
        build_info["build_ok"] = build_ok
        if self.restored_info:
            build_info["restored_from"] = self.restored_info
        if build_ok:
            bundle.pack(
                self.repo,
                self.sim.bundle_paths(),
                build_info,
                self.build_dir / "sim-build.tar.gz",
            )
        (self.build_dir / "build_info.json").write_text(
            json.dumps(build_info, indent=2)
        )
        return build_ok

    def run(self) -> List[TestResult]:
        build_info = self._build_info()
        build_ok, build_msg = self._build()
        build_info["build_ok"] = build_ok
        if self.restored_info:
            build_info["restored_from"] = self.restored_info
        (self.build_dir / "build_info.json").write_text(
            json.dumps(build_info, indent=2)
        )

        results = []
        for i, test in enumerate(self.tests, 1):
            if not build_ok:
                results.append(TestResult(test.name, Status.BUILD_FAIL, build_msg))
                continue
            _log.info("[%d/%d] %s", i, len(self.tests), test.name)
            results.append(self._run_test(test))

        report.console(results, build_info)
        report.write_json(results, build_info, self.out_dir / "summary.json")
        # Tests waiting for their simulation are reported by the simulation
        done = [r for r in results if r.status is not Status.COMPILED]
        junit = self.out_dir / "junit.xml"
        reports = [self.out_dir / "summary.json"]
        if done:
            report.write_junit(done, build_info, junit)
            reports.append(junit)
        elif junit.exists():
            junit.unlink()
        _log.info("reports: %s", ", ".join(map(str, reports)))
        return results

    # ---------------------------------------------------------------------
    # Build: mcu-gen + elaboration
    # ---------------------------------------------------------------------
    def _build(self) -> Tuple[bool, str]:
        """Prepares what the selected steps need: the generated files for the
        sw compilation and the elaboration, the model for the simulation."""
        self.build_dir.mkdir(parents=True, exist_ok=True)

        if self.skip_build:
            _log.warning(
                "skipping mcu-gen and elaboration, reusing the existing %s build",
                self.sim.name,
            )
            return True, ""

        if self.compile_sw or (self.simulate and not self.use_build):
            ok, msg = self._generate()
            if not ok:
                return ok, msg
        if self.simulate:
            return self._model()
        return True, ""

    def _generate(self) -> Tuple[bool, str]:
        """mcu-gen, or the files another job generated."""
        b = self.cfg.build
        if self.use_gen:
            return self._restore(
                "mcu_gen",
                self.use_gen,
                {"x_heep_cfg": b.x_heep_cfg, "pads_cfg": b.pads_cfg},
                "gen_ok",
            )

        _log.info("mcu-gen: %s, %s", b.x_heep_cfg, b.pads_cfg)
        gen = proc.run(
            ["make", "mcu-gen", f"X_HEEP_CFG={b.x_heep_cfg}", f"PADS_CFG={b.pads_cfg}"],
            self.build_dir / "mcugen.log",
            self.repo,
            BUILD_TIMEOUT_S,
        )
        if not gen.ok:
            return self._build_failed("mcu-gen", gen)
        _log.info("mcu-gen done in %.0f s", gen.duration_s)
        return True, ""

    def _model(self) -> Tuple[bool, str]:
        """Elaboration, or the model another job elaborated."""
        b = self.cfg.build
        if self.use_build:
            return self._restore(
                "sim_build",
                self.use_build,
                {
                    "simulator": b.simulator.name,
                    "x_heep_cfg": b.x_heep_cfg,
                    "pads_cfg": b.pads_cfg,
                    "defines": b.defines,
                },
                "build_ok",
            )

        _log.info("elaboration with %s (this can take several minutes)", self.sim.name)
        build = self.sim.build(
            b.defines, self.build_dir, BUILD_TIMEOUT_S, self._build_env()
        )
        if not build.ok:
            return self._build_failed("elaboration", build)
        _log.info("elaboration done in %.0f s", build.duration_s)
        return True, ""

    def _restore(
        self, kind: str, path: Path, expected: dict, ok_key: str
    ) -> Tuple[bool, str]:
        """Restores a bundle made by another job (see bundle.py), which must
        match the hardware this run expects."""
        try:
            info = bundle.unpack(path, self.repo)
        except (OSError, KeyError, ValueError) as exc:
            _log.error("cannot restore %s: %s", path, exc)
            return False, f"cannot restore {path}: {exc}"
        self.restored_info[kind] = info
        mismatch = {
            k: (info.get(k), v) for k, v in expected.items() if info.get(k) != v
        }
        if mismatch:
            msg = f"{path.name} does not match the regression: {mismatch}"
            _log.error(msg)
            return False, msg
        if not info.get(ok_key):
            return False, f"{path.name} comes from a failed job"
        commit = git_commit(self.repo)
        if info.get("git_commit") != commit:
            _log.warning(
                "%s made at commit %s, running at %s",
                path.name,
                info.get("git_commit"),
                commit,
            )
        return True, ""

    def _build_env(self) -> dict:
        """Environment the Makefile exports to FuseSoC."""
        prefix = self.cfg.build.compiler_prefix or _detect_compiler_prefix()
        return {"COMPILER_PREFIX": prefix} if prefix else {}

    def _build_failed(self, step: str, result: proc.ProcResult) -> Tuple[bool, str]:
        reason = "timed out" if result.timed_out else f"exit code {result.returncode}"
        _log.error(
            "%s failed (%s), see %s\n%s", step, reason, result.log_file, result.tail(15)
        )
        return False, f"{step} failed ({reason}), see {result.log_file}"

    # ---------------------------------------------------------------------
    # One test: sw compile + simulation
    # ---------------------------------------------------------------------
    def _run_test(self, test: TestCfg) -> TestResult:
        out = self.out_dir / test.name
        if self.compile_sw:
            res = self._compile(test, out)
            if res.status is not Status.COMPILED or not self.simulate:
                return self._finish(res)
        else:
            res = self._compiled(test, out)
            if res.status is not Status.COMPILED:
                return self._finish(res)

        waves = self.waves or test.sim.waves
        plusargs = self._plusargs(test, out / "main.hex", waves)
        self.sim.clean_outputs()
        sim = self.sim.run(plusargs, out / "sim.log", test.timeout_s)
        res.durations_s["simulate"] = sim.duration_s
        res.status, res.message, res.sw_exit = classify_simulation(sim)
        if not res.status.passed:
            res.log_tail = sim.tail()

        self._collect(out, waves)
        return self._finish(res)

    def _compile(self, test: TestCfg, out: Path) -> TestResult:
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        res = TestResult(test.name, Status.COMPILED, out_dir=out)

        comp = sw.compile_app(self.repo, test.sw, out, COMPILE_TIMEOUT_S)
        res.durations_s["compile"] = comp.duration_s
        if not comp.ok:
            res.status = Status.COMPILE_FAIL
            res.message = f"make app failed, see {comp.log_file}"
            res.log_tail = comp.tail()
        return res

    def _compiled(self, test: TestCfg, out: Path) -> TestResult:
        """The result left by an earlier compile-only run of this test."""
        res = TestResult(test.name, out_dir=out)
        try:
            prev = json.loads((out / "result.json").read_text())
        except (OSError, json.JSONDecodeError):
            prev = {}
        if (
            prev.get("status") != Status.COMPILED.value
            or not (out / "main.hex").exists()
        ):
            res.message = f"no compiled firmware in {out}, compile the test first"
            return res
        res.status = Status.COMPILED
        res.durations_s = prev.get("durations_s", {})
        # Outputs of a previous simulation of this firmware
        for name in ("uart0.log", self.sim.waves_name):
            (out / name).unlink(missing_ok=True)
        return res

    def _plusargs(self, test: TestCfg, firmware: Path, waves: bool) -> List[str]:
        s = test.sim
        args = [f"+firmware={firmware.resolve()}", f"+boot={s.boot}"]
        if s.tb_route:
            args.append(f"+tb_route={','.join(s.tb_route)}")
        if s.max_sim_time:
            args.append(f"+max_sim_time={s.max_sim_time}")
        if waves:
            args.append("+waves")
        return args + list(s.plusargs)

    def _collect(self, out: Path, waves: bool) -> None:
        work = self.sim.work_dir
        uart = work / "uart0.log"
        if uart.exists():
            shutil.copy2(uart, out / "uart0.log")
        if waves and self.sim.waves_file.exists():
            shutil.move(str(self.sim.waves_file), out / self.sim.waves_name)

    def _finish(self, res: TestResult) -> TestResult:
        res.out_dir.mkdir(parents=True, exist_ok=True)
        (res.out_dir / "result.json").write_text(json.dumps(res.to_dict(), indent=2))
        line = f"    {res.status.value} in {res.duration_s:.1f} s"
        if res.status.ok:
            _log.info(line)
        else:
            _log.error("%s: %s", line, res.message)
        return res

    # ---------------------------------------------------------------------
    def _build_info(self) -> dict:
        b = self.cfg.build
        return {
            "regression": self.cfg.name,
            "config_file": str(self.cfg.path),
            "simulator": b.simulator.name,
            "x_heep_cfg": b.x_heep_cfg,
            "pads_cfg": b.pads_cfg,
            "compiler_prefix": self._build_env().get("COMPILER_PREFIX"),
            "defines": b.defines,
            "build_args": b.simulator.build_args,
            "run_args": b.simulator.run_args,
            "git_commit": git_commit(self.repo),
            "host": platform.node(),
            "date": datetime.datetime.now().isoformat(timespec="seconds"),
            "build_reused": self.skip_build,
            "steps": [
                s
                for s, on in (("compile", self.compile_sw), ("simulate", self.simulate))
                if on
            ],
        }


def _detect_compiler_prefix() -> Optional[str]:
    """Same rule as the Makefile: the prefix of the first *gcc in
    $RISCV_XHEEP/bin (e.g. 'riscv32-corev-')."""
    riscv = os.environ.get("RISCV_XHEEP")
    if not riscv:
        return None
    gccs = sorted(Path(riscv, "bin").glob("*elf-gcc"))
    return gccs[0].name[: -len("elf-gcc")] if gccs else None


def git_commit(repo: Path) -> Optional[str]:
    try:
        sha = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=repo,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            cwd=repo,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return f"{sha}{'-dirty' if dirty else ''}"
    except (OSError, subprocess.CalledProcessError):
        return None
