#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/external_versions.lock"

default_nprocs() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN
    else
        echo 4
    fi
}

banner() {
    printf '\n[%s] %s\n' "deps" "$1"
}

die() {
    echo "[deps] ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

run_conda() {
    "${CONDA_BIN}" run --no-capture-output --prefix "${CONDA_ENV_PREFIX}" "$@"
}

run_backend() {
    if [[ "${BACKEND}" == "conda" ]]; then
        run_conda "$@"
    else
        "$@"
    fi
}

setup_conda_env() {
    banner "Preparing conda environment for dependency build"

    require_cmd conda
    CONDA_BIN="$(command -v conda)"

    mkdir -p "$(dirname "${CONDA_ENV_PREFIX}")"

    if [[ ! -f "${CONDA_ENV_FILE}" ]]; then
        die "Conda environment file not found: ${CONDA_ENV_FILE}"
    fi

    if [[ -d "${CONDA_ENV_PREFIX}" ]]; then
        conda env update --prefix "${CONDA_ENV_PREFIX}" --file "${CONDA_ENV_FILE}" --prune
    else
        conda env create -y --prefix "${CONDA_ENV_PREFIX}" --file "${CONDA_ENV_FILE}"
    fi

    local conda_bin_dir="${CONDA_ENV_PREFIX}/bin"
    if [[ -x "${conda_bin_dir}/x86_64-conda-linux-gnu-cc" ]]; then
        CC_BIN="${conda_bin_dir}/x86_64-conda-linux-gnu-cc"
    elif [[ -x "${conda_bin_dir}/gcc" ]]; then
        CC_BIN="${conda_bin_dir}/gcc"
    fi

    if [[ -x "${conda_bin_dir}/x86_64-conda-linux-gnu-c++" ]]; then
        CXX_BIN="${conda_bin_dir}/x86_64-conda-linux-gnu-c++"
    elif [[ -x "${conda_bin_dir}/g++" ]]; then
        CXX_BIN="${conda_bin_dir}/g++"
    fi

    echo "[deps] CONDA_ENV_PREFIX=${CONDA_ENV_PREFIX}"
    echo "[deps] CC=${CC_BIN}"
    echo "[deps] CXX=${CXX_BIN}"
}

setup_backend() {
    case "${BACKEND}" in
        conda)
            setup_conda_env
            ;;
        system)
            require_cmd cmake
            require_cmd make
            require_cmd pkg-config
            ;;
        *)
            die "Unsupported backend: ${BACKEND} (expected conda or system)"
            ;;
    esac
}

ensure_repo() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_ref="$3"

    if [[ ! -d "${repo_dir}/.git" ]]; then
        git clone "${repo_url}" "${repo_dir}"
    fi

    git -C "${repo_dir}" fetch --tags origin
    git -C "${repo_dir}" checkout --detach "${repo_ref}"
    git -C "${repo_dir}" submodule update --init --recursive || true
}

check_host_prereqs() {
    banner "Checking host prerequisites"

    require_cmd git
    require_cmd python3

    if ! python3 -m venv --help >/dev/null 2>&1; then
        die "python3 venv support is required (Ubuntu package: python3-venv)"
    fi
}

ensure_rust_toolchain() {
    banner "Checking Rust toolchain"

    if [[ -x "${CARGO_HOME_DIR}/bin/cargo" ]]; then
        CARGO_BIN="${CARGO_HOME_DIR}/bin/cargo"
    elif command -v cargo >/dev/null 2>&1; then
        CARGO_BIN="$(command -v cargo)"
    else
        banner "Installing local rustup/cargo into ${CARGO_HOME_DIR}"
        require_cmd curl

        local installer="${DEPS_DIR}/rustup-init.sh"
        curl -fsSL https://sh.rustup.rs -o "${installer}"
        chmod +x "${installer}"

        CARGO_HOME="${CARGO_HOME_DIR}" \
            RUSTUP_HOME="${RUSTUP_HOME_DIR}" \
            sh "${installer}" -y --profile minimal --default-toolchain stable --no-modify-path

        rm -f "${installer}"
        CARGO_BIN="${CARGO_HOME_DIR}/bin/cargo"
    fi

    [[ -x "${CARGO_BIN}" ]] || die "cargo not found after Rust toolchain setup"
    export PATH="$(dirname "${CARGO_BIN}"):${PATH}"
}

install_trellis() {
    banner "Installing Project Trellis"

    ensure_repo "${PRJTRELLIS_DIR}" "${PRJTRELLIS_REPO}" "${PRJTRELLIS_REF}"

    rm -rf "${PRJTRELLIS_DIR}/libtrellis/build"

    if [[ "${BACKEND}" == "conda" ]]; then
        TRELLIS_PYTHON_EXECUTABLE="${CONDA_ENV_PREFIX}/bin/python"
    else
        TRELLIS_PYTHON_EXECUTABLE="$(command -v python3)"
    fi

    run_backend env CC="${CC_BIN}" CXX="${CXX_BIN}" \
        cmake -S "${PRJTRELLIS_DIR}/libtrellis" -B "${PRJTRELLIS_DIR}/libtrellis/build" \
        -DPython3_EXECUTABLE="${TRELLIS_PYTHON_EXECUTABLE}" \
        -DCMAKE_INSTALL_PREFIX="${TRELLIS_PREFIX}"
    run_backend env CC="${CC_BIN}" CXX="${CXX_BIN}" \
        cmake --build "${PRJTRELLIS_DIR}/libtrellis/build" -j"${NPROCS}"
    run_backend env CC="${CC_BIN}" CXX="${CXX_BIN}" \
        cmake --install "${PRJTRELLIS_DIR}/libtrellis/build"

    printf '%s\n' "${TRELLIS_PYTHON_EXECUTABLE}" > "${TRELLIS_PREFIX}/.pytrellis-python"
}

install_oxide() {
    banner "Installing Project Oxide (prjoxide)"

    ensure_repo "${PRJOXIDE_DIR}" "${PRJOXIDE_REPO}" "${PRJOXIDE_REF}"

    CARGO_HOME="${CARGO_HOME_DIR}" \
        RUSTUP_HOME="${RUSTUP_HOME_DIR}" \
        cargo install --locked --force \
        --path "${PRJOXIDE_DIR}/libprjoxide/prjoxide" \
        --root "${OXIDE_PREFIX}"
}

prepare_mistral() {
    banner "Preparing Mistral checkout"
    ensure_repo "${MISTRAL_DIR}" "${MISTRAL_REPO}" "${MISTRAL_REF}"
}

install_apycula() {
    banner "Installing Apycula virtualenv"

    ensure_repo "${APYCULA_DIR}" "${APYCULA_REPO}" "${APYCULA_REF}"

    python3 -m venv "${APYCULA_PREFIX}"
    "${APYCULA_PREFIX}/bin/python" -m pip install --upgrade pip
    "${APYCULA_PREFIX}/bin/python" -m pip install "${APYCULA_DIR}"
}

prepare_prjbeyond_db() {
    banner "Preparing prjbeyond-db checkout"
    ensure_repo "${PRJBEYOND_DB_DIR}" "${PRJBEYOND_DB_REPO}" "${PRJBEYOND_DB_REF}"
}

prepare_prjpeppercorn() {
    banner "Preparing prjpeppercorn checkout"
    ensure_repo "${PRJPEPPERCORN_DIR}" "${PRJPEPPERCORN_REPO}" "${PRJPEPPERCORN_REF}"
}

validate_trellis() {
    TRELLIS_LIBDIR="${TRELLIS_PREFIX}/lib/trellis"
    TRELLIS_DATADIR="${TRELLIS_PREFIX}/share/trellis"

    local pytrellis_so
    pytrellis_so="$(find "${TRELLIS_LIBDIR}" -maxdepth 4 -type f -name 'pytrellis*.so' | head -n 1 || true)"
    [[ -n "${pytrellis_so}" ]] || die "pytrellis library not found under ${TRELLIS_LIBDIR}"
    [[ -d "${TRELLIS_DATADIR}" ]] || die "Trellis data dir not found: ${TRELLIS_DATADIR}"
}

validate_oxide() {
    [[ -x "${OXIDE_PREFIX}/bin/prjoxide" ]] || die "prjoxide binary not found: ${OXIDE_PREFIX}/bin/prjoxide"
}

validate_mistral() {
    local path
    for path in tools generator libmistral; do
        [[ -d "${MISTRAL_DIR}/${path}" ]] || die "Mistral path missing: ${MISTRAL_DIR}/${path}"
    done
}

validate_apycula() {
    "${APYCULA_PREFIX}/bin/python" - <<'PY'
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("apycula") else 1)
PY
}

validate_prjbeyond_db() {
    [[ -d "${PRJBEYOND_DB_DIR}" ]] || die "prjbeyond-db path missing: ${PRJBEYOND_DB_DIR}"
}

validate_prjpeppercorn() {
    [[ -d "${PRJPEPPERCORN_DIR}/gatemate" ]] || die "prjpeppercorn/gatemate path missing: ${PRJPEPPERCORN_DIR}/gatemate"
}

write_env_file() {
    banner "Writing environment file"

    cat > "${ENV_FILE}" <<ENVEOF
# Generated by scripts/common/install_external_deps.sh
# Source this file before running multi-architecture bootstrap commands.

export TRELLIS_INSTALL_PREFIX="${TRELLIS_PREFIX}"
export TRELLIS_LIBDIR="${TRELLIS_LIBDIR}"
export TRELLIS_DATADIR="${TRELLIS_DATADIR}"
export TRELLIS_PYTHON_EXECUTABLE="${TRELLIS_PYTHON_EXECUTABLE}"

export OXIDE_INSTALL_PREFIX="${OXIDE_PREFIX}"

export MISTRAL_ROOT="${MISTRAL_DIR}"

export APYCULA_INSTALL_PREFIX="${APYCULA_PREFIX}"

export HIMBAECHEL_PRJBEYOND_DB="${PRJBEYOND_DB_DIR}"
export HIMBAECHEL_PEPPERCORN_PATH="${PRJPEPPERCORN_DIR}"
ENVEOF
}

print_summary() {
    banner "Done"
    cat <<EOF_SUMMARY
[deps] All architecture external dependencies are prepared under:
  ${DEPS_DIR}

[deps] Environment file:
  ${ENV_FILE}

[deps] To use in current shell:
  source ${ENV_FILE}
EOF_SUMMARY
}

main() {
    DEPS_DIR="${NEXTPNR_MVP_DEPS:-${ROOT_DIR}/_deps}"
    INSTALL_DIR="${NEXTPNR_MVP_DEPS_INSTALL:-${DEPS_DIR}/_install}"
    CARGO_HOME_DIR="${NEXTPNR_MVP_CARGO_HOME:-${DEPS_DIR}/.cargo}"
    RUSTUP_HOME_DIR="${NEXTPNR_MVP_RUSTUP_HOME:-${DEPS_DIR}/.rustup}"
    BACKEND="${NEXTPNR_MVP_DEPS_BACKEND:-conda}"

    CONDA_ENV_PREFIX="${NEXTPNR_MVP_CONDA_PREFIX:-${ROOT_DIR}/_conda_env/nextpnr}"
    CONDA_ENV_FILE="${NEXTPNR_MVP_CONDA_ENV_FILE:-${ROOT_DIR}/scripts/ice40/conda/environment.yml}"
    CONDA_BIN=""

    CC_BIN="${CC_BIN:-/usr/bin/gcc}"
    CXX_BIN="${CXX_BIN:-/usr/bin/g++}"
    CARGO_BIN=""

    NPROCS="${NPROCS:-$(default_nprocs)}"

    PRJTRELLIS_DIR="${DEPS_DIR}/prjtrellis"
    TRELLIS_PREFIX="${INSTALL_DIR}/trellis"

    PRJOXIDE_DIR="${DEPS_DIR}/prjoxide"
    OXIDE_PREFIX="${INSTALL_DIR}/oxide"

    MISTRAL_DIR="${DEPS_DIR}/mistral"

    APYCULA_DIR="${DEPS_DIR}/apicula"
    APYCULA_PREFIX="${INSTALL_DIR}/apycula-venv"

    PRJBEYOND_DB_DIR="${DEPS_DIR}/prjbeyond-db"
    PRJPEPPERCORN_DIR="${DEPS_DIR}/prjpeppercorn"

    ENV_FILE="${DEPS_DIR}/arch-deps.env"

    mkdir -p "${DEPS_DIR}" "${INSTALL_DIR}" "${CARGO_HOME_DIR}" "${RUSTUP_HOME_DIR}"

    check_host_prereqs
    setup_backend
    ensure_rust_toolchain
    install_trellis
    install_oxide
    prepare_mistral
    install_apycula
    prepare_prjbeyond_db
    prepare_prjpeppercorn

    validate_trellis
    validate_oxide
    validate_mistral
    validate_apycula
    validate_prjbeyond_db
    validate_prjpeppercorn

    write_env_file
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
