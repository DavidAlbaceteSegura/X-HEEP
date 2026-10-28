# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Logging setup: a concise, colored console and a detailed run.log."""

import logging
import sys
from pathlib import Path

ROOT_LOGGER = "flow"

_COLORS = {
    logging.DEBUG: "\033[90m",
    logging.INFO: "",
    logging.WARNING: "\033[33m",
    logging.ERROR: "\033[31m",
    logging.CRITICAL: "\033[1;31m",
}
_RESET = "\033[0m"


class _ConsoleFormatter(logging.Formatter):
    def __init__(self, color: bool):
        super().__init__("%(asctime)s %(message)s", datefmt="%H:%M:%S")
        self.color = color

    def format(self, record: logging.LogRecord) -> str:
        msg = super().format(record)
        if self.color and _COLORS.get(record.levelno):
            msg = f"{_COLORS[record.levelno]}{msg}{_RESET}"
        return msg


def setup(log_file: Path, verbose: bool = False) -> logging.Logger:
    """Configures the flow loggers. Every module logs through
    logging.getLogger("flow.<module>")."""
    logger = logging.getLogger(ROOT_LOGGER)
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()
    logger.propagate = False

    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.DEBUG if verbose else logging.INFO)
    console.setFormatter(_ConsoleFormatter(color=sys.stdout.isatty()))
    logger.addHandler(console)

    log_file.parent.mkdir(parents=True, exist_ok=True)
    file_handler = logging.FileHandler(log_file, mode="w")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)-7s %(name)s: %(message)s")
    )
    logger.addHandler(file_handler)
    return logger


def get(name: str) -> logging.Logger:
    return logging.getLogger(f"{ROOT_LOGGER}.{name}")
