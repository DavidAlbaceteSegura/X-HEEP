#!/usr/bin/env python3
# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Runs an X-HEEP regression described by an hjson file.

All in one:
    python ci/run_flow.py ci/regressions/smoke.hjson
    python ci/run_flow.py ci/regressions/smoke.hjson --tags smoke,gpio+nightly --exclude-tags slow
    python ci/run_flow.py ci/regressions/smoke.hjson --test hello_jtag --waves
    python ci/run_flow.py ci/regressions/smoke.hjson --list

Split across CI jobs (mcu-gen, elaboration, plan, one job per test):
    python ci/run_flow.py ci/regressions/smoke.hjson --gen-only
    python ci/run_flow.py ci/regressions/smoke.hjson --build-only --use-gen mcu-gen.tar.gz
    python ci/run_flow.py ci/regressions/smoke.hjson --tags smoke --plan plan.json
    python ci/run_flow.py --from-plan plan.json --test hello_jtag --compile-only --use-gen mcu-gen.tar.gz
    python ci/run_flow.py --from-plan plan.json --test hello_jtag --sim-only --use-build sim-build.tar.gz

Exit status: 0 if every selected test passed (or the step succeeded), 1 if a
test or the build failed, 2 on a configuration error.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from flow import config, log, plan  # noqa: E402
from flow.runner import Runner, git_commit  # noqa: E402

REPO = Path(__file__).resolve().parent.parent


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("config", type=Path, nargs="?", help="regression hjson file")
    sel = parser.add_argument_group("test selection")
    sel.add_argument("--tags", help="select by tags: a,b = a or b, a+b = a and b")
    sel.add_argument(
        "--exclude-tags", help="drop tests with any of these tags (comma separated)"
    )
    sel.add_argument(
        "--test",
        action="append",
        dest="tests",
        metavar="NAME",
        help="run only this test (repeatable)",
    )
    sel.add_argument(
        "--list", action="store_true", help="list the selected tests and exit"
    )
    split = parser.add_argument_group("split flow (CI)")
    split.add_argument(
        "--gen-only",
        action="store_true",
        help="mcu-gen only, packs the generated files in <out>/build/mcu-gen.tar.gz",
    )
    split.add_argument(
        "--build-only",
        action="store_true",
        help="mcu-gen + elaboration only, packs the model in <out>/build/sim-build.tar.gz",
    )
    split.add_argument(
        "--plan",
        type=Path,
        metavar="FILE",
        help="write the selected tests and the CI matrix to FILE and exit",
    )
    split.add_argument(
        "--from-plan",
        type=Path,
        metavar="FILE",
        help="take the tests from a plan instead of the hjson",
    )
    split.add_argument(
        "--use-gen",
        type=Path,
        metavar="BUNDLE",
        help="restore the generated files from a mcu-gen.tar.gz instead of running mcu-gen",
    )
    split.add_argument(
        "--use-build",
        type=Path,
        metavar="BUNDLE",
        help="restore the model from a sim-build.tar.gz instead of elaborating",
    )
    split.add_argument(
        "--compile-only",
        action="store_true",
        help="compile the tests' sw, leave the simulation to --sim-only",
    )
    split.add_argument(
        "--sim-only",
        action="store_true",
        help="simulate the firmware a --compile-only run left in the output folder",
    )
    run = parser.add_argument_group("run")
    run.add_argument(
        "--out", type=Path, help="output directory (default build/flow/<regression>)"
    )
    run.add_argument(
        "--waves", action="store_true", help="dump waveforms for every test"
    )
    run.add_argument(
        "--skip-build",
        action="store_true",
        help="reuse the existing local build (no mcu-gen, no elaboration)",
    )
    run.add_argument(
        "-v", "--verbose", action="store_true", help="show the commands being run"
    )
    args = parser.parse_args()

    if bool(args.config) == bool(args.from_plan):
        parser.error("give either a regression hjson or --from-plan")
    if args.from_plan and (args.tags or args.exclude_tags or args.plan):
        parser.error(
            "--from-plan only takes --test: the selection was made by the plan"
        )
    steps = ("gen_only", "build_only", "plan", "compile_only", "sim_only")
    if sum(bool(getattr(args, s)) for s in steps) > 1:
        parser.error(
            "--gen-only, --build-only, --plan, --compile-only and --sim-only are exclusive"
        )
    if args.gen_only and (args.use_gen or args.use_build or args.skip_build):
        parser.error(
            "--gen-only cannot be combined with --use-gen, --use-build or --skip-build"
        )
    if args.build_only and (args.use_build or args.skip_build):
        parser.error("--build-only cannot be combined with --use-build or --skip-build")
    if args.compile_only and args.use_build:
        parser.error("--compile-only does not simulate, it takes no --use-build")
    if args.sim_only and args.use_gen:
        parser.error("--sim-only does not compile, it takes no --use-gen")
    if args.skip_build and (args.use_gen or args.use_build):
        parser.error("--skip-build cannot be combined with --use-gen or --use-build")
    return args


def main() -> int:
    args = _parse_args()

    try:
        if args.from_plan:
            cfg, tests = plan.load(args.from_plan)
            tests = config.select(tests, names=args.tests)
        else:
            cfg = config.load(args.config)
            tests = config.select(cfg.tests, args.tags, args.exclude_tags, args.tests)
    except config.ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2

    if not tests and not (args.gen_only or args.build_only):
        print("no test selected", file=sys.stderr)
        return 2
    if args.list:
        for t in tests:
            print(f"{t.name:<30} {','.join(t.tags)}")
        return 0
    if args.plan:
        selection = {
            "tags": args.tags,
            "exclude_tags": args.exclude_tags,
            "tests": args.tests,
        }
        plan.write(args.plan, cfg, tests, selection, git_commit(REPO))
        print(
            f"plan with {len(tests)} test(s) written to {args.plan}: {', '.join(t.name for t in tests)}"
        )
        return 0

    out_dir = (args.out or REPO / "build" / "flow" / cfg.name).resolve()
    logger = log.setup(out_dir / "run.log", args.verbose)

    try:
        runner = Runner(
            cfg,
            tests,
            REPO,
            out_dir,
            waves=args.waves,
            skip_build=args.skip_build,
            use_gen=args.use_gen,
            use_build=args.use_build,
            compile_sw=not args.sim_only,
            simulate=not args.compile_only,
        )
    except config.ConfigError as exc:
        logger.error("configuration error: %s", exc)
        return 2

    if args.gen_only:
        logger.info("regression %s: mcu-gen only, output in %s", cfg.name, out_dir)
        return 0 if runner.gen_only() else 1
    if args.build_only:
        logger.info(
            "regression %s: build only on %s, output in %s",
            cfg.name,
            cfg.build.simulator.name,
            out_dir,
        )
        return 0 if runner.build_only() else 1

    logger.info(
        "regression %s: %d test(s) on %s, output in %s",
        cfg.name,
        len(tests),
        cfg.build.simulator.name,
        out_dir,
    )
    results = runner.run()
    return 0 if all(r.status.ok for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
