#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PREFIX="${NEXTPNR_MVP_TOOLCHAIN:-${ROOT_DIR}/_toolchain}"
BUILD_DIR="${NEXTPNR_MVP_BUILD:-${ROOT_DIR}/_build}"
BACKEND="${NEXTPNR_MVP_DEPS_BACKEND:-conda}"
CONDA_ENV_PREFIX="${NEXTPNR_MVP_CONDA_PREFIX:-${ROOT_DIR}/_conda_env/nextpnr}"

YOSYS_BIN="${YOSYS_BIN:-${PREFIX}/bin/yosys}"
NEXTPNR_BIN="${NEXTPNR_BIN:-${BUILD_DIR}/nextpnr-generic/nextpnr-generic}"

EXAMPLE_DIR="${ROOT_DIR}/generic/viaduct/example"

require_file() {
    [[ -x "$1" ]] || {
        echo "[e2e] Missing executable: $1" >&2
        exit 1
    }
}

run_backend() {
    if [[ "${BACKEND}" == "conda" ]]; then
        env -u CMAKE_PREFIX_PATH -u CPATH -u LIBRARY_PATH -u PKG_CONFIG_PATH \
            PATH="${CONDA_ENV_PREFIX}/bin:${PATH}" \
            LD_LIBRARY_PATH="${CONDA_ENV_PREFIX}/lib" \
            "$@"
    else
        "$@"
    fi
}

main() {
    require_file "${YOSYS_BIN}"
    require_file "${NEXTPNR_BIN}"

    pushd "${EXAMPLE_DIR}" >/dev/null

    run_backend "${YOSYS_BIN}" -p 'tcl synth_viaduct_example.tcl blinky.json' ../../examples/blinky.v
    run_backend "${NEXTPNR_BIN}" --uarch example --json blinky.json --write pnrblinky.json

    ls -lh blinky.json pnrblinky.json
    popd >/dev/null

    echo "[e2e] SUCCESS: generic smoke flow completed"
}

main "$@"
