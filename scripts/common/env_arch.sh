#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/arch_matrix.sh"

exit_or_return() {
    local code="$1"
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        exit "${code}"
    else
        return "${code}"
    fi
}

main() {
    local arch_key="${1:-${NEXTPNR_MVP_ARCH:-}}"
    if [[ -z "${arch_key}" ]]; then
        echo "[env] ARCH argument is required" >&2
        exit_or_return 1
    fi
    if ! nextpnr_arch_is_supported "${arch_key}"; then
        echo "[env] Unsupported architecture: ${arch_key}" >&2
        echo "[env] Supported architectures: ${NEXTPNR_BOOTSTRAP_SUPPORTED_ARCHES[*]}" >&2
        exit_or_return 1
    fi

    export NEXTPNR_MVP_ROOT_DIR="${ROOT_DIR}"
    export NEXTPNR_MVP_DEPS="${NEXTPNR_MVP_DEPS:-${ROOT_DIR}/_deps}"
    export NEXTPNR_MVP_DEPS_INSTALL="${NEXTPNR_MVP_DEPS_INSTALL:-${NEXTPNR_MVP_DEPS}/_install}"

    nextpnr_apply_arch_env_defaults "${arch_key}"
    nextpnr_load_arch_matrix "${arch_key}" || {
        echo "[env] Failed to load architecture matrix for ${arch_key}" >&2
        exit_or_return 1
    }

    export NEXTPNR_MVP_ARCH="${arch_key}"
    export NEXTPNR_MVP_TOOLCHAIN="${NEXTPNR_MVP_TOOLCHAIN:-${ROOT_DIR}/_toolchain}"
    export NEXTPNR_MVP_BUILD="${NEXTPNR_MVP_BUILD:-${ROOT_DIR}/_build}"
    export NEXTPNR_MVP_CONDA_PREFIX="${NEXTPNR_MVP_CONDA_PREFIX:-${ROOT_DIR}/_conda_env/nextpnr}"
    export NEXTPNR_MVP_NEXTPNR_BIN="${NEXTPNR_MVP_BUILD}/nextpnr-${arch_key}/${NEXTPNR_ARCH_BINARY}"

    export PATH="${NEXTPNR_MVP_TOOLCHAIN}/bin:${PATH}"

    echo "[env] NEXTPNR_MVP_ARCH=${NEXTPNR_MVP_ARCH}"
    echo "[env] NEXTPNR_MVP_TOOLCHAIN=${NEXTPNR_MVP_TOOLCHAIN}"
    echo "[env] NEXTPNR_MVP_BUILD=${NEXTPNR_MVP_BUILD}"
    echo "[env] NEXTPNR_MVP_CONDA_PREFIX=${NEXTPNR_MVP_CONDA_PREFIX}"
    echo "[env] NEXTPNR_MVP_NEXTPNR_BIN=${NEXTPNR_MVP_NEXTPNR_BIN}"
    echo "[env] PATH prefixed with ${NEXTPNR_MVP_TOOLCHAIN}/bin"

    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        echo "[env] Tip: source this script to persist variables in the current shell" >&2
    fi
}

main "$@"
