#!/bin/bash
# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Runs a shell command in the tools image ($XHEEP_IMAGE, util/docker/dockerfile)
# from an Azure job. The agent's work folder is mounted at the same path, so
# Azure paths ($(Pipeline.Workspace), ...) are valid inside the container, and
# the command runs in the current directory. The login shell sets up the
# image's tools (PATH, RISCV_XHEEP).
#
#   ci/azure/in-image.sh '. .venv/bin/activate && python ci/run_flow.py ...'

set -euo pipefail
exec docker run --rm \
    -v "$AGENT_WORKFOLDER:$AGENT_WORKFOLDER" -w "$PWD" \
    "$XHEEP_IMAGE" bash -lc "$1"
