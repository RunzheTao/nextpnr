#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export NEXTPNR_MVP_TOOLCHAIN="${NEXTPNR_MVP_TOOLCHAIN:-${ROOT_DIR}/_toolchain}"
if [[ -z "${NEXTPNR_MVP_CONDA_PREFIX:-}" ]]; then
    export NEXTPNR_MVP_CONDA_PREFIX="${ROOT_DIR}/_conda_env/nextpnr"
fi
export PATH="${NEXTPNR_MVP_TOOLCHAIN}/bin:${PATH}"

echo "[env] NEXTPNR_MVP_TOOLCHAIN=${NEXTPNR_MVP_TOOLCHAIN}"
echo "[env] NEXTPNR_MVP_CONDA_PREFIX=${NEXTPNR_MVP_CONDA_PREFIX}"
echo "[env] PATH prefixed with ${NEXTPNR_MVP_TOOLCHAIN}/bin"
