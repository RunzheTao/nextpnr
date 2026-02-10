#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/arch_matrix.sh"

banner() {
    printf '\n[%s] %s\n' "bootstrap" "$1"
}

die() {
    echo "[bootstrap] ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

default_nprocs() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN
    else
        echo 4
    fi
}

run_system_clean() {
    local system_path="${NEXTPNR_MVP_SYSTEM_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
    if [[ -d "${PREFIX}/bin" ]]; then
        system_path="${PREFIX}/bin:${system_path}"
    fi

    env -u CONDA_PREFIX -u CMAKE_PREFIX_PATH -u CPATH -u LIBRARY_PATH \
        -u LD_LIBRARY_PATH -u PKG_CONFIG_PATH \
        PATH="${system_path}" \
        "$@"
}

run_conda() {
    env -u CMAKE_PREFIX_PATH -u CPATH -u LIBRARY_PATH \
        -u LD_LIBRARY_PATH -u PKG_CONFIG_PATH \
        "${CONDA_BIN}" run --no-capture-output --prefix "${CONDA_ENV_PREFIX}" "$@"
}

run_backend() {
    if [[ "${BACKEND}" == "conda" ]]; then
        run_conda "$@"
    else
        run_system_clean "$@"
    fi
}

setup_conda_env() {
    banner "Preparing conda environment"
    require_cmd conda

    CONDA_BIN="$(command -v conda)"

    mkdir -p "$(dirname "${CONDA_ENV_PREFIX}")"
    mkdir -p "${DEPS_DIR}" "${BUILD_DIR}" "${PREFIX}"

    if [[ ! -f "${CONDA_ENV_FILE}" ]]; then
        die "Conda env file not found: ${CONDA_ENV_FILE}"
    fi

    if [[ -d "${CONDA_ENV_PREFIX}" ]]; then
        conda env update --prefix "${CONDA_ENV_PREFIX}" --file "${CONDA_ENV_FILE}" --prune
    else
        conda env create -y --prefix "${CONDA_ENV_PREFIX}" --file "${CONDA_ENV_FILE}"
    fi

    local conda_cc
    local conda_cxx
    conda_cc="$(run_conda bash -lc 'command -v x86_64-conda-linux-gnu-cc || command -v gcc')"
    conda_cxx="$(run_conda bash -lc 'command -v x86_64-conda-linux-gnu-c++ || command -v g++')"

    if [[ -n "${conda_cc}" ]]; then
        CC_BIN="${conda_cc}"
    fi
    if [[ -n "${conda_cxx}" ]]; then
        CXX_BIN="${conda_cxx}"
    fi

    echo "[bootstrap] BACKEND=conda"
    echo "[bootstrap] CONDA_ENV_PREFIX=${CONDA_ENV_PREFIX}"
    echo "[bootstrap] CC=${CC_BIN}"
    echo "[bootstrap] CXX=${CXX_BIN}"
}

check_prerequisites_system() {
    banner "Checking system build tools"
    require_cmd git
    require_cmd cmake
    require_cmd make
    require_cmd python3
    require_cmd pkg-config

    if [[ ! -x "${CC_BIN}" ]]; then
        die "CC_BIN not found: ${CC_BIN}"
    fi
    if [[ ! -x "${CXX_BIN}" ]]; then
        die "CXX_BIN not found: ${CXX_BIN}"
    fi

    echo "[bootstrap] BACKEND=system"
    echo "[bootstrap] CC=${CC_BIN}"
    echo "[bootstrap] CXX=${CXX_BIN}"
}

check_prerequisites() {
    case "${BACKEND}" in
        conda)
            require_cmd git
            setup_conda_env
            ;;
        system)
            check_prerequisites_system
            ;;
        *)
            die "Unsupported backend: ${BACKEND} (expected conda or system)"
            ;;
    esac
}

print_arch_matrix() {
    banner "Architecture matrix"
    echo "[bootstrap] ARCH=${NEXTPNR_ARCH_KEY}"
    echo "[bootstrap] LABEL=${NEXTPNR_ARCH_LABEL}"
    echo "[bootstrap] FAMILY=${NEXTPNR_ARCH_FAMILY}"
    echo "[bootstrap] EXPERIMENTAL=${NEXTPNR_ARCH_EXPERIMENTAL}"
    if ((${#NEXTPNR_ARCH_EXTERNAL_DEPS[@]} > 0)); then
        local dep
        for dep in "${NEXTPNR_ARCH_EXTERNAL_DEPS[@]}"; do
            echo "[bootstrap] DEP=${dep}"
        done
    fi
}

fail_missing_with_hints() {
    local reason="$1"
    echo "[bootstrap] ${reason}" >&2
    if ((${#NEXTPNR_ARCH_REQUIRED_ENV_HINTS[@]} > 0)); then
        local hint
        echo "[bootstrap] Required/important environment variables:" >&2
        for hint in "${NEXTPNR_ARCH_REQUIRED_ENV_HINTS[@]}"; do
            echo "  - ${hint}" >&2
        done
    fi
    echo "[bootstrap] Example: make bootstrap-${NEXTPNR_ARCH_KEY}-system" >&2
    exit 1
}

check_trellis() {
    local data_dir="${TRELLIS_DATADIR:-${TRELLIS_INSTALL_PREFIX}/share/trellis}"
    local lib_dir="${TRELLIS_LIBDIR:-}"
    local found_pytrellis=""

    if [[ -n "${lib_dir}" ]]; then
        if [[ ! -d "${lib_dir}" ]]; then
            fail_missing_with_hints "TRELLIS_LIBDIR does not exist: ${lib_dir}"
        fi
        found_pytrellis="$(find "${lib_dir}" -maxdepth 4 -type f \( -name 'pytrellis*.so' -o -name 'pytrellis*.pyd' \) | head -n 1 || true)"
    else
        found_pytrellis="$(find "${TRELLIS_INSTALL_PREFIX}/lib" -maxdepth 4 -type f \( -name 'pytrellis*.so' -o -name 'pytrellis*.pyd' \) 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -z "${found_pytrellis}" ]]; then
        fail_missing_with_hints "Failed to locate pytrellis shared library under TRELLIS_INSTALL_PREFIX=${TRELLIS_INSTALL_PREFIX}"
    fi

    if [[ ! -d "${data_dir}" ]]; then
        fail_missing_with_hints "Trellis data directory not found: ${data_dir}"
    fi
}

check_oxide() {
    local oxide_tool="${PRJOXIDE_TOOL:-${OXIDE_INSTALL_PREFIX}/bin/prjoxide}"
    if [[ ! -x "${oxide_tool}" ]]; then
        fail_missing_with_hints "Project Oxide tool not found: ${oxide_tool}"
    fi
}

check_mistral() {
    if [[ -z "${MISTRAL_ROOT:-}" ]]; then
        fail_missing_with_hints "MISTRAL_ROOT must be set for ARCH=mistral"
    fi

    local path
    for path in tools generator libmistral; do
        if [[ ! -d "${MISTRAL_ROOT}/${path}" ]]; then
            fail_missing_with_hints "Mistral path missing: ${MISTRAL_ROOT}/${path}"
        fi
    done

    if ! run_backend pkg-config --exists liblzma; then
        fail_missing_with_hints "liblzma was not found by pkg-config"
    fi
}

check_gowin_apycula() {
    local py_cmd=()

    if [[ -n "${APYCULA_INSTALL_PREFIX:-}" ]]; then
        local venv_python="${APYCULA_INSTALL_PREFIX}/bin/python"
        if [[ ! -x "${venv_python}" ]]; then
            fail_missing_with_hints "APYCULA_INSTALL_PREFIX set but python not found: ${venv_python}"
        fi
        py_cmd=("${venv_python}")
    elif [[ "${BACKEND}" == "conda" ]]; then
        py_cmd=("${CONDA_BIN}" run --no-capture-output --prefix "${CONDA_ENV_PREFIX}" python)
    else
        require_cmd python3
        py_cmd=(python3)
    fi

    if ! "${py_cmd[@]}" - <<'PY'
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("apycula") else 1)
PY
    then
        fail_missing_with_hints "Python package 'apycula' is required for himbaechel-gowin"
    fi
}

check_prjbeyond() {
    if [[ -z "${HIMBAECHEL_PRJBEYOND_DB:-}" ]]; then
        fail_missing_with_hints "HIMBAECHEL_PRJBEYOND_DB must be set for himbaechel-ng-ultra"
    fi
    if [[ ! -d "${HIMBAECHEL_PRJBEYOND_DB}" ]]; then
        fail_missing_with_hints "HIMBAECHEL_PRJBEYOND_DB does not exist: ${HIMBAECHEL_PRJBEYOND_DB}"
    fi
}

check_peppercorn() {
    if [[ -z "${HIMBAECHEL_PEPPERCORN_PATH:-}" ]]; then
        fail_missing_with_hints "HIMBAECHEL_PEPPERCORN_PATH must be set for himbaechel-gatemate"
    fi
    if [[ ! -d "${HIMBAECHEL_PEPPERCORN_PATH}" ]]; then
        fail_missing_with_hints "HIMBAECHEL_PEPPERCORN_PATH does not exist: ${HIMBAECHEL_PEPPERCORN_PATH}"
    fi
    if [[ ! -d "${HIMBAECHEL_PEPPERCORN_PATH}/gatemate" ]]; then
        fail_missing_with_hints "Expected directory missing: ${HIMBAECHEL_PEPPERCORN_PATH}/gatemate"
    fi
}

preflight_arch_dependencies() {
    banner "Checking architecture-specific dependencies"
    case "${NEXTPNR_ARCH_KEY}" in
        ecp5|machxo2)
            check_trellis
            ;;
        nexus)
            check_oxide
            ;;
        mistral)
            check_mistral
            ;;
        generic)
            ;;
        himbaechel-gowin)
            check_gowin_apycula
            ;;
        himbaechel-ng-ultra)
            check_prjbeyond
            ;;
        himbaechel-gatemate)
            check_peppercorn
            ;;
        *)
            die "Unsupported architecture for preflight: ${NEXTPNR_ARCH_KEY}"
            ;;
    esac
}

configure_nextpnr() {
    banner "Configuring nextpnr"

    mkdir -p "${NEXTPNR_BUILD_DIR}"
    pushd "${NEXTPNR_BUILD_DIR}" >/dev/null

    if [[ -f CMakeCache.txt ]]; then
        local cached_cxx
        local cache_reset_reason=""
        cached_cxx="$(sed -n 's/^CMAKE_CXX_COMPILER:FILEPATH=//p' CMakeCache.txt | head -n 1)"
        if [[ -n "${cached_cxx}" && "${cached_cxx}" != "${CXX_BIN}" ]]; then
            cache_reset_reason="compiler changed"
        fi

        # Conda backend must not reuse cache entries that point at a different
        # host/base Conda prefix, otherwise runtime can pick incompatible libs.
        if [[ -z "${cache_reset_reason}" && "${BACKEND}" == "conda" ]]; then
            if grep -E '/(mini|ana)conda[0-9]?|/_conda_env/' CMakeCache.txt >/dev/null; then
                if grep -E '/(mini|ana)conda[0-9]?|/_conda_env/' CMakeCache.txt | grep -Fv "${CONDA_ENV_PREFIX}" >/dev/null; then
                    cache_reset_reason="conda backend detected foreign conda paths in CMake cache"
                fi
            fi
        fi

        # System backend must not reuse cache entries that point at Conda paths.
        if [[ -z "${cache_reset_reason}" && "${BACKEND}" == "system" ]]; then
            if grep -Eq '/(mini|ana)?conda[0-9]?|/_conda_env/' CMakeCache.txt; then
                cache_reset_reason="system backend detected conda paths in CMake cache"
            fi
        fi

        if [[ -n "${cache_reset_reason}" ]]; then
            echo "[bootstrap] ${cache_reset_reason}: clearing stale CMake cache"
            rm -f CMakeCache.txt
            rm -rf CMakeFiles
        fi
    fi

    local cmake_args=(
        "${ROOT_DIR}"
        "-DCMAKE_CXX_COMPILER=${CXX_BIN}"
        "-DBUILD_GUI=OFF"
        "-DBUILD_PYTHON=OFF"
    )

    cmake_args+=("${NEXTPNR_ARCH_CMAKE_ARGS[@]}")

    run_backend env CC="${CC_BIN}" CXX="${CXX_BIN}" cmake "${cmake_args[@]}"

    if [[ "${CONFIGURE_ONLY}" == "1" ]]; then
        echo "[bootstrap] CONFIGURE_ONLY=1, skipping build"
    else
        run_backend env CC="${CC_BIN}" CXX="${CXX_BIN}" cmake --build . -j"${NPROCS}"
    fi

    popd >/dev/null
}

print_summary() {
    banner "Done"
    echo "[bootstrap] ARCH=${NEXTPNR_ARCH_KEY}"
    echo "[bootstrap] BUILD_DIR=${NEXTPNR_BUILD_DIR}"
    if [[ "${BACKEND}" == "conda" ]]; then
        echo "[bootstrap] CONDA_ENV_PREFIX=${CONDA_ENV_PREFIX}"
    fi
    echo "[bootstrap] Export environment with:"
    echo "  source scripts/${NEXTPNR_ARCH_KEY}/env.sh"
    if [[ -n "${NEXTPNR_ARCH_E2E_SCRIPT}" ]]; then
        echo "[bootstrap] Run smoke test with:"
        echo "  ./${NEXTPNR_ARCH_E2E_SCRIPT}"
    fi
}

usage() {
    cat <<USAGE
Usage: NEXTPNR_MVP_ARCH=<arch> ${0##*/} [--configure-only]

Environment:
  NEXTPNR_MVP_ARCH             Architecture key (required)
  NEXTPNR_MVP_DEPS_BACKEND     conda|system (default: conda)
  NEXTPNR_MVP_CONDA_ENV_FILE   Conda environment file for backend=conda
  NEXTPNR_MVP_CONFIGURE_ONLY   1 to skip cmake --build
USAGE
}

parse_args() {
    while (($#)); do
        case "$1" in
            --configure-only)
                CONFIGURE_ONLY=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

main() {
    local arch_key="${NEXTPNR_MVP_ARCH:-}"
    if [[ -z "${arch_key}" ]]; then
        die "NEXTPNR_MVP_ARCH is required"
    fi
    if ! nextpnr_arch_is_supported "${arch_key}"; then
        die "Unsupported architecture '${arch_key}'. Supported: ${NEXTPNR_BOOTSTRAP_SUPPORTED_ARCHES[*]}"
    fi

    parse_args "$@"

    export NEXTPNR_MVP_ROOT_DIR="${ROOT_DIR}"
    : "${NEXTPNR_MVP_DEPS:=${ROOT_DIR}/_deps}"
    : "${NEXTPNR_MVP_DEPS_INSTALL:=${NEXTPNR_MVP_DEPS}/_install}"
    export NEXTPNR_MVP_DEPS
    export NEXTPNR_MVP_DEPS_INSTALL

    nextpnr_apply_arch_env_defaults "${arch_key}"
    nextpnr_load_arch_matrix "${arch_key}" || die "Failed to load architecture matrix for ${arch_key}"

    PREFIX="${NEXTPNR_MVP_TOOLCHAIN:-${ROOT_DIR}/_toolchain}"
    DEPS_DIR="${NEXTPNR_MVP_DEPS}"
    BUILD_DIR="${NEXTPNR_MVP_BUILD:-${ROOT_DIR}/_build}"
    NPROCS="${NPROCS:-$(default_nprocs)}"

    BACKEND="${NEXTPNR_MVP_DEPS_BACKEND:-conda}"
    CONDA_ENV_PREFIX="${NEXTPNR_MVP_CONDA_PREFIX:-${ROOT_DIR}/_conda_env/nextpnr}"
    CONDA_ENV_FILE="${NEXTPNR_MVP_CONDA_ENV_FILE:-${ROOT_DIR}/scripts/ice40/conda/environment.yml}"

    CONFIGURE_ONLY="${NEXTPNR_MVP_CONFIGURE_ONLY:-0}"

    CC_BIN="${CC_BIN:-/usr/bin/gcc}"
    CXX_BIN="${CXX_BIN:-/usr/bin/g++}"
    CONDA_BIN=""

    NEXTPNR_BUILD_DIR="${BUILD_DIR}/nextpnr-${arch_key}"

    mkdir -p "${PREFIX}" "${DEPS_DIR}" "${BUILD_DIR}"

    print_arch_matrix
    check_prerequisites
    preflight_arch_dependencies
    configure_nextpnr
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
