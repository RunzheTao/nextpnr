#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export NEXTPNR_ROOT="${NEXTPNR_ROOT:-${ROOT_DIR}}"
export RISCV_PREFIX="${RISCV_PREFIX:-riscv32-unknown-elf-}"
export NEXTPNR_ECP5_BIN="${NEXTPNR_ECP5_BIN:-${NEXTPNR_ROOT}/_build/nextpnr-ecp5-py-conda/nextpnr-ecp5}"

export PATH="${HOME}/.local/bin:${NEXTPNR_ROOT}/_toolchain/bin:${NEXTPNR_ROOT}/_deps/_install/trellis/bin:${NEXTPNR_ROOT}/_build/nextpnr-ecp5-py-conda:${PATH}"

if [[ -d "${NEXTPNR_ROOT}/_conda_env/nextpnr/lib" ]]; then
    export LD_LIBRARY_PATH="${NEXTPNR_ROOT}/_conda_env/nextpnr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

echo "[env] NEXTPNR_ROOT=${NEXTPNR_ROOT}"
echo "[env] NEXTPNR_ECP5_BIN=${NEXTPNR_ECP5_BIN}"
echo "[env] RISCV_PREFIX=${RISCV_PREFIX}"
echo "[env] PATH prepended with ~/.local/bin, _toolchain/bin, trellis/bin, _build/nextpnr-ecp5-py-conda"
if command -v "${RISCV_PREFIX}gcc" >/dev/null 2>&1; then
    "${RISCV_PREFIX}gcc" --version | head -n 1
else
    echo "[env] WARN: ${RISCV_PREFIX}gcc not found in PATH"
fi
if command -v "${RISCV_PREFIX}objcopy" >/dev/null 2>&1; then
    "${RISCV_PREFIX}objcopy" --version | head -n 1
else
    echo "[env] WARN: ${RISCV_PREFIX}objcopy not found in PATH"
fi
