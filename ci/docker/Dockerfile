# Copyright 2026 OpenHW Group
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# CI image for the regression flow (ci/run_flow.py): only what mcu-gen, the
# elaboration, the sw compilation and the simulation need. The developer image
# with every toolchain is util/docker/dockerfile.
#
# Build from the repository root (see ci/docker/README.md):
#   docker build -f ci/docker/Dockerfile -t xheep-ci:1 .

ARG BASE=debian:12-slim

# -----------------------------------------------------------------------------
# Verilator, built here so that its build dependencies stay out of the image
FROM ${BASE} AS verilator
ARG VERILATOR_VERSION=v5.040
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git make autoconf g++ flex bison help2man perl python3 \
        libfl-dev zlib1g-dev && \
    git clone --depth 1 --branch ${VERILATOR_VERSION} \
        https://github.com/verilator/verilator.git /src && \
    cd /src && autoconf && ./configure --prefix=/tools/verilator && \
    make -j"$(nproc)" && make install
RUN rm -f /tools/verilator/bin/verilator_bin_dbg

# -----------------------------------------------------------------------------
# CORE-V GCC (riscv32-corev-), the toolchain of the regressions, trimmed: no
# RV64 libraries, no gdb, host binaries stripped
FROM ${BASE} AS toolchain
ARG COREV_GCC_URL=https://github.com/x-heep/corev-gcc/releases/download/cv32e40pv2-release/corev-openhw-gcc-ubuntu2204-20240530.tar.gz
ARG VERIBLE_VERSION=v0.0-4023-gc1271a00
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget binutils && \
    mkdir -p /tools/riscv /tools/verible && \
    wget -qO- ${COREV_GCC_URL} | tar -xz -C /tools/riscv --strip-components=1 && \
    find /tools/riscv -depth -type d -name 'rv64*' -exec rm -rf {} + && \
    rm -rf /tools/riscv/bin/*-gdb* /tools/riscv/share/gdb /tools/riscv/share/doc \
        /tools/riscv/share/info /tools/riscv/share/man && \
    { find /tools/riscv/bin /tools/riscv/libexec -type f -perm -u+x \
        -exec strip --strip-unneeded {} + 2>/dev/null || true; }
RUN wget -qO- https://github.com/chipsalliance/verible/releases/download/${VERIBLE_VERSION}/verible-${VERIBLE_VERSION}-linux-static-x86_64.tar.gz | \
        tar -xz -C /tools/verible --strip-components=1
# The Verible release ships bin/ as 0700; the CI runs as a non-root user
RUN chmod -R a+rX /tools

# -----------------------------------------------------------------------------
# Python packages of the flow, in the venv the Makefile uses (VENVDIR); some
# build C extensions, so the headers stay in this stage
FROM ${BASE} AS python
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git make cmake g++ python3-dev python3-venv && \
    rm -rf /var/lib/apt/lists/*
COPY util/python-requirements.txt /tmp/python-requirements.txt
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir -r /tmp/python-requirements.txt

# -----------------------------------------------------------------------------
FROM ${BASE}
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ca-certificates git make cmake g++ perl python3 python3-venv \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

COPY --from=verilator /tools/verilator /tools/verilator
COPY --from=toolchain /tools /tools
COPY --from=python /opt/venv /opt/venv
ENV VENVDIR=/opt/venv

ENV RISCV_XHEEP=/tools/riscv \
    PATH=/opt/venv/bin:/tools/riscv/bin:/tools/verilator/bin:/tools/verible/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8

# The CI checks the repository out as another user
RUN git config --system --add safe.directory '*'

# No ENTRYPOINT: Azure Pipelines runs its own command in job containers
CMD ["/bin/bash"]
