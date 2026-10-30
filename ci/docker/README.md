# CI image

`Dockerfile` builds the image the regression pipeline (`ci/azure/regression.yml`)
runs in. It holds only what `ci/run_flow.py` needs:

- CORE-V GCC (`riscv32-corev-`), without RV64 libraries and gdb, in `/tools/riscv` (`RISCV_XHEEP`)
- Verilator 5.040, Verible
- `make`, `cmake`, `g++`, `git`, and the Python packages of `util/python-requirements.txt`
  in `/opt/venv` (`VENVDIR`, so the Makefile uses it; no `make venv` needed)

The developer image with every toolchain is `util/docker/dockerfile`.

## Build

From the repository root (BuildKit, the default in current Docker, picks up
`Dockerfile.dockerignore`, so only `util/python-requirements.txt` is sent):

```bash
docker build -f ci/docker/Dockerfile -t xheep-ci:1 .
```

Versions can be changed with `--build-arg VERILATOR_VERSION=...`,
`VERIBLE_VERSION`, `COREV_GCC_URL`. Bump the tag (`xheep-ci:2`, ...) on every
change: the pipeline names the tag it runs on.

## Check

```bash
docker run --rm xheep-ci:1 bash -c 'riscv32-corev-elf-gcc --version | head -1; verilator --version; verible-verilog-format --version | head -1; fusesoc --version'
# the smoke regression on this checkout, as the pipeline would run it
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:$PWD" -w "$PWD" xheep-ci:1 \
    python ci/run_flow.py ci/regressions/smoke.hjson
docker image ls xheep-ci
```

## Publish

The pipeline pulls the image on every job, so it lives in a public registry
(no service connection needed). With a GitHub token that has `write:packages`:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
docker tag xheep-ci:1 ghcr.io/<github-user>/xheep-ci:1
docker push ghcr.io/<github-user>/xheep-ci:1
```

A new GHCR package is private: make it public once in the package settings
on GitHub. Point the pipeline at a new tag with its `image` parameter (or its
default in `ci/azure/regression.yml`).
