#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PREFIX="${NEXTPNR_MVP_TOOLCHAIN:-${ROOT_DIR}/_toolchain}"
BUILD_DIR="${NEXTPNR_MVP_BUILD:-${ROOT_DIR}/_build}"
BACKEND="${NEXTPNR_MVP_DEPS_BACKEND:-conda}"
CONDA_ENV_PREFIX="${NEXTPNR_MVP_CONDA_PREFIX:-${ROOT_DIR}/_conda_env/nextpnr-ice40}"

if [[ -z "${NEXTPNR_MVP_CONDA_PREFIX:-}" ]]; then
    if [[ -d "${ROOT_DIR}/_conda_env/nextpnr" ]]; then
        CONDA_ENV_PREFIX="${ROOT_DIR}/_conda_env/nextpnr"
    elif [[ -d "${ROOT_DIR}/_conda_env/nextpnr-ice40" ]]; then
        CONDA_ENV_PREFIX="${ROOT_DIR}/_conda_env/nextpnr-ice40"
    else
        CONDA_ENV_PREFIX="${ROOT_DIR}/_conda_env/nextpnr"
    fi
fi

YOSYS_BIN="${YOSYS_BIN:-${PREFIX}/bin/yosys}"
ICEPACK_BIN="${ICEPACK_BIN:-${PREFIX}/bin/icepack}"
NEXTPNR_BIN="${NEXTPNR_BIN:-${BUILD_DIR}/nextpnr-ice40/nextpnr-ice40}"

EXAMPLE_DIR="${ROOT_DIR}/ice40/examples/blinky"

require_file() {
    [[ -x "$1" ]] || {
        echo "[e2e] Missing executable: $1" >&2
        exit 1
    }
}

run_backend() {
    if [[ "${BACKEND}" == "conda" ]]; then
        conda run --no-capture-output --prefix "${CONDA_ENV_PREFIX}" "$@"
    else
        "$@"
    fi
}

main() {
    require_file "${YOSYS_BIN}"
    require_file "${NEXTPNR_BIN}"
    require_file "${ICEPACK_BIN}"

    pushd "${EXAMPLE_DIR}" >/dev/null

    run_backend "${YOSYS_BIN}" -p 'synth_ice40 -top blinky -json blinky.json' blinky.v
    run_backend "${NEXTPNR_BIN}" --hx1k --package tq144 --json blinky.json --pcf blinky.pcf --asc blinky.asc
    run_backend "${ICEPACK_BIN}" blinky.asc blinky.bin

    ls -lh blinky.json blinky.asc blinky.bin
    popd >/dev/null

    echo "[e2e] SUCCESS: blinky flow completed"
}

main "$@"
