# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Reports: console summary, summary.json and junit.xml (Jenkins, Azure)."""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List

from . import log
from .results import Status, TestResult

_log = log.get("report")

_GREEN, _RED, _YELLOW, _RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def _color(status: Status) -> str:
    if not sys.stdout.isatty():
        return ""
    if status.passed:
        return _GREEN
    return _YELLOW if status in (Status.NOT_RUN, Status.COMPILED) else _RED


def console(results: List[TestResult], build_info: dict) -> None:
    name_w = max([len("Test")] + [len(r.name) for r in results])
    status_w = max(len(s.value) for s in Status)
    lines = [
        "",
        f"Regression {build_info['regression']} on {build_info['simulator']} "
        f"({build_info['x_heep_cfg']}, commit {build_info['git_commit']})",
        f"{'Test':<{name_w}}  {'Status':<{status_w}}  {'Time':>7}  Details",
        f"{'-' * name_w}  {'-' * status_w}  {'-' * 7}  {'-' * 40}",
    ]
    for r in results:
        color = _color(r.status)
        reset = _RESET if color else ""
        lines.append(
            f"{r.name:<{name_w}}  {color}{r.status.value:<{status_w}}{reset}  "
            f"{r.duration_s:>6.1f}s  {r.message}"
        )
    passed = sum(r.status.passed for r in results)
    compiled = sum(r.status is Status.COMPILED for r in results)
    lines.append("")
    lines.append(
        f"{passed}/{len(results)} tests passed"
        + (f", {compiled} compiled and waiting for simulation" if compiled else "")
    )
    _log.info("\n".join(lines))


def write_json(results: List[TestResult], build_info: dict, path: Path) -> None:
    data = {
        "build": build_info,
        "passed": sum(r.status.passed for r in results),
        "total": len(results),
        "tests": [r.to_dict() for r in results],
    }
    path.write_text(json.dumps(data, indent=2))


def write_junit(results: List[TestResult], build_info: dict, path: Path) -> None:
    failures = sum(
        not r.status.passed and r.status is not Status.NOT_RUN for r in results
    )
    skipped = sum(r.status is Status.NOT_RUN for r in results)
    suite = ET.Element(
        "testsuite",
        name=f"{build_info['regression']}.{build_info['simulator']}",
        tests=str(len(results)),
        failures=str(failures),
        skipped=str(skipped),
        time=f"{sum(r.duration_s for r in results):.2f}",
    )
    props = ET.SubElement(suite, "properties")
    for key, val in build_info.items():
        ET.SubElement(props, "property", name=key, value=str(val))

    for r in results:
        case = ET.SubElement(
            suite,
            "testcase",
            classname=f"{build_info['regression']}.{build_info['simulator']}",
            name=r.name,
            time=f"{r.duration_s:.2f}",
        )
        if r.status is Status.NOT_RUN:
            ET.SubElement(case, "skipped", message=r.message)
        elif not r.status.passed:
            fail = ET.SubElement(
                case,
                "failure",
                message=f"{r.status.value}: {r.message}",
                type=r.status.value,
            )
            fail.text = r.log_tail
        if r.out_dir:
            ET.SubElement(case, "system-out").text = f"artifacts: {r.out_dir}"

    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)
