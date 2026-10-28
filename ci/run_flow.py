#!/usr/bin/env python3
# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Runs an X-HEEP regression described by an hjson file.

    python ci/run_flow.py ci/regressions/smoke.hjson
    python ci/run_flow.py ci/regressions/smoke.hjson --tags smoke,gpio+nightly --exclude-tags slow
    python ci/run_flow.py ci/regressions/smoke.hjson --test hello_jtag --waves
    python ci/run_flow.py ci/regressions/smoke.hjson --list

Exit status: 0 if every selected test passed, 1 if any failed, 2 on a
configuration error.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from flow import config, log  # noqa: E402
from flow.runner import Runner  # noqa: E402

REPO = Path(__file__).resolve().parent.parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("config", type=Path, help="regression hjson file")
    parser.add_argument("--tags", help="select by tags: a,b = a or b, a+b = a and b")
    parser.add_argument("--exclude-tags", help="drop tests with any of these tags (comma separated)")
    parser.add_argument("--test", action="append", dest="tests", metavar="NAME",
                        help="run only this test (repeatable)")
    parser.add_argument("--list", action="store_true", help="list the selected tests and exit")
    parser.add_argument("--out", type=Path, help="output directory (default build/flow/<regression>)")
    parser.add_argument("--waves", action="store_true", help="dump waveforms for every test")
    parser.add_argument("--skip-build", action="store_true",
                        help="reuse the existing build (no mcu-gen, no elaboration)")
    parser.add_argument("-v", "--verbose", action="store_true", help="show the commands being run")
    args = parser.parse_args()

    try:
        cfg = config.load(args.config)
        tests = config.select(cfg.tests, args.tags, args.exclude_tags, args.tests)
    except config.ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2

    if not tests:
        print("no test selected", file=sys.stderr)
        return 2
    if args.list:
        for t in tests:
            print(f"{t.name:<30} {','.join(t.tags)}")
        return 0

    out_dir = (args.out or REPO / "build" / "flow" / cfg.name).resolve()
    logger = log.setup(out_dir / "run.log", args.verbose)
    logger.info("regression %s: %d test(s) on %s, output in %s",
                cfg.name, len(tests), cfg.build.simulator.name, out_dir)

    try:
        runner = Runner(cfg, tests, REPO, out_dir, waves=args.waves, skip_build=args.skip_build)
    except config.ConfigError as exc:
        logger.error("configuration error: %s", exc)
        return 2
    results = runner.run()
    return 0 if all(r.status.passed for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
