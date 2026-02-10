#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/versions.lock"

PREFIX="${NEXTPNR_MVP_TOOLCHAIN:-${ROOT_DIR}/_toolchain}"
DEPS_DIR="${NEXTPNR_MVP_DEPS:-${ROOT_DIR}/_deps}"
BUILD_DIR="${NEXTPNR_MVP_BUILD:-${ROOT_DIR}/_build}"
NPROCS="${NPROCS:-$(nproc)}"

BACKEND="${NEXTPNR_MVP_DEPS_BACKEND:-conda}"
CONDA_ENV_PREFIX="${NEXTPNR_MVP_CONDA_PREFIX:-${ROOT_DIR}/_conda_env/nextpnr-ice40}"
CONDA_ENV_FILE="${NEXTPNR_MVP_CONDA_ENV_FILE:-${SCRIPT_DIR}/conda/environment.yml}"

if [[ -z "${NEXTPNR_MVP_CONDA_PREFIX:-}" ]]; then
    if [[ -d "${ROOT_DIR}/_conda_env/nextpnr" ]]; then
        CONDA_ENV_PREFIX="${ROOT_DIR}/_conda_env/nextpnr"
    elif [[ -d "${ROOT_DIR}/_conda_env/nextpnr-ice40" ]]; then
        CONDA_ENV_PREFIX="${ROOT_DIR}/_conda_env/nextpnr-ice40"
    else
        CONDA_ENV_PREFIX="${ROOT_DIR}/_conda_env/nextpnr"
    fi
fi

CC_BIN="${CC_BIN:-/usr/bin/gcc}"
CXX_BIN="${CXX_BIN:-/usr/bin/g++}"

ICESTORM_DIR="${DEPS_DIR}/icestorm"
YOSYS_DIR="${DEPS_DIR}/yosys"
NEXTPNR_BUILD_DIR="${BUILD_DIR}/nextpnr-ice40"

CONDA_BIN=""

banner() {
    printf '\n[%s] %s\n' "bootstrap" "$1"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[bootstrap] Missing required command: $1" >&2
        exit 1
    }
}

run_system_clean() {
    env -u CONDA_PREFIX -u CMAKE_PREFIX_PATH -u CPATH -u LIBRARY_PATH \
        -u LD_LIBRARY_PATH -u PKG_CONFIG_PATH \
        "$@"
}

run_conda() {
    "${CONDA_BIN}" run --no-capture-output --prefix "${CONDA_ENV_PREFIX}" "$@"
}

run_backend() {
    if [[ "${BACKEND}" == "conda" ]]; then
        run_conda "$@"
    else
        run_system_clean "$@"
    fi
}

get_conda_pkgconfig_path() {
    run_conda python -c 'import pathlib,sys; p=pathlib.Path(sys.prefix)/"lib"/"pkgconfig"; print(str(p) if p.exists() else "")'
}

setup_conda_env() {
    banner "Preparing conda environment"
    require_cmd conda
    CONDA_BIN="$(command -v conda)"

    mkdir -p "$(dirname "${CONDA_ENV_PREFIX}")"
    mkdir -p "${DEPS_DIR}" "${BUILD_DIR}" "${PREFIX}"

    if [[ ! -f "${CONDA_ENV_FILE}" ]]; then
        echo "[bootstrap] Conda env file not found: ${CONDA_ENV_FILE}" >&2
        exit 1
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
        echo "[bootstrap] CC_BIN not found: ${CC_BIN}" >&2
        exit 1
    fi
    if [[ ! -x "${CXX_BIN}" ]]; then
        echo "[bootstrap] CXX_BIN not found: ${CXX_BIN}" >&2
        exit 1
    fi

    echo "[bootstrap] BACKEND=system"
    echo "[bootstrap] CC=${CC_BIN}"
    echo "[bootstrap] CXX=${CXX_BIN}"
    echo "[bootstrap] PREFIX=${PREFIX}"
    echo "[bootstrap] DEPS_DIR=${DEPS_DIR}"
    echo "[bootstrap] BUILD_DIR=${BUILD_DIR}"

    if command -v dpkg >/dev/null 2>&1; then
        local strict_apt_check="${NEXTPNR_MVP_STRICT_APT:-0}"
        local apt_packages=(
            build-essential cmake git python3 pkg-config
            libboost-filesystem-dev libboost-thread-dev
            libboost-program-options-dev libboost-iostreams-dev libeigen3-dev
            bison flex libreadline-dev gawk tcl-dev libffi-dev
        )
        local missing_packages=()
        local package_name
        for package_name in "${apt_packages[@]}"; do
            if ! dpkg -s "${package_name}" >/dev/null 2>&1; then
                missing_packages+=("${package_name}")
            fi
        done

        if ((${#missing_packages[@]} > 0)); then
            if [[ "${NEXTPNR_MVP_AUTO_APT:-0}" == "1" ]]; then
                banner "Installing missing apt packages"
                require_cmd sudo
                sudo apt update
                sudo apt install -y "${missing_packages[@]}"
            else
                echo "[bootstrap] Missing Ubuntu packages (dpkg check): ${missing_packages[*]}" >&2
                cat >&2 <<'EOF'
[bootstrap] Install them manually, or rerun with:
  NEXTPNR_MVP_AUTO_APT=1 NEXTPNR_MVP_DEPS_BACKEND=system make bootstrap-ice40

[bootstrap] By default this check is non-fatal (to support non-apt dependency sources).
[bootstrap] Enforce strict apt-only check with:
  NEXTPNR_MVP_STRICT_APT=1 NEXTPNR_MVP_DEPS_BACKEND=system make bootstrap-ice40

[bootstrap] Optional package for iceprog support:
  sudo apt install -y libftdi1-dev
EOF
                if [[ "${strict_apt_check}" == "1" ]]; then
                    exit 1
                fi
            fi
        fi
    fi
}

check_prerequisites() {
    if [[ "${BACKEND}" == "conda" ]]; then
        require_cmd git
        setup_conda_env
    elif [[ "${BACKEND}" == "system" ]]; then
        check_prerequisites_system
    else
        echo "[bootstrap] Unsupported backend: ${BACKEND} (expected conda or system)" >&2
        exit 1
    fi
}

update_repo() {
    local repo_dir="$1"
    local repo_url="$2"
    local ref="$3"

    if [[ ! -d "${repo_dir}/.git" ]]; then
        git clone "${repo_url}" "${repo_dir}"
    fi

    git -C "${repo_dir}" fetch --tags origin
    git -C "${repo_dir}" checkout --detach "${ref}"
}

build_icestorm() {
    banner "Building IceStorm"
    update_repo "${ICESTORM_DIR}" "${ICESTORM_REPO}" "${ICESTORM_REF}"

    local iceprog_flag=1
    if [[ "${BACKEND}" == "conda" ]]; then
        local conda_pkgcfg
        conda_pkgcfg="$(get_conda_pkgconfig_path)"
        if ! run_conda env PKG_CONFIG_PATH="${conda_pkgcfg}" pkg-config --exists libftdi1; then
            echo "[bootstrap] libftdi1 not found in conda env; building IceStorm with ICEPROG=0"
            iceprog_flag=0
        fi

        run_conda env PKG_CONFIG_PATH="${conda_pkgcfg}" \
            CC="${CC_BIN}" CXX="${CXX_BIN}" \
            make -C "${ICESTORM_DIR}" -j"${NPROCS}" ICEPROG="${iceprog_flag}" PREFIX="${PREFIX}"

        run_conda env PKG_CONFIG_PATH="${conda_pkgcfg}" \
            CC="${CC_BIN}" CXX="${CXX_BIN}" \
            make -C "${ICESTORM_DIR}" install ICEPROG="${iceprog_flag}" PREFIX="${PREFIX}"
    else
        if ! pkg-config --exists libftdi1; then
            echo "[bootstrap] libftdi1 not found via pkg-config; building IceStorm with ICEPROG=0"
            iceprog_flag=0
        fi

        run_system_clean CC="${CC_BIN}" CXX="${CXX_BIN}" \
            make -C "${ICESTORM_DIR}" -j"${NPROCS}" ICEPROG="${iceprog_flag}" PREFIX="${PREFIX}"

        run_system_clean CC="${CC_BIN}" CXX="${CXX_BIN}" \
            make -C "${ICESTORM_DIR}" install ICEPROG="${iceprog_flag}" PREFIX="${PREFIX}"
    fi
}

build_yosys() {
    banner "Building Yosys"
    update_repo "${YOSYS_DIR}" "${YOSYS_REPO}" "${YOSYS_REF}"
    git -C "${YOSYS_DIR}" submodule update --init --recursive

    if [[ "${NEXTPNR_MVP_CLEAN:-0}" == "1" ]]; then
        run_backend make -C "${YOSYS_DIR}" clean
    fi
    run_backend env CC="${CC_BIN}" CXX="${CXX_BIN}" \
        make -C "${YOSYS_DIR}" -j"${NPROCS}" PREFIX="${PREFIX}" ENABLE_NLS=0
    run_backend make -C "${YOSYS_DIR}" install PREFIX="${PREFIX}"
}

build_nextpnr_ice40() {
    banner "Building nextpnr-ice40"
    git -C "${ROOT_DIR}" submodule update --init --recursive

    if [[ "${BACKEND}" == "system" ]]; then
        local eigen_candidates=(
            "/usr/include/eigen3/Eigen/Core"
            "${PREFIX}/include/eigen3/Eigen/Core"
        )
        local has_eigen=0
        local eigen_probe
        for eigen_probe in "${eigen_candidates[@]}"; do
            if [[ -f "${eigen_probe}" ]]; then
                has_eigen=1
                break
            fi
        done
        if [[ "${has_eigen}" != "1" ]]; then
            cat >&2 <<'EOF'
[bootstrap] Eigen headers not found (need Eigen/Core).
[bootstrap] Install dependency from apt or provide it in your toolchain prefix.
[bootstrap] Ubuntu example: sudo apt install -y libeigen3-dev
EOF
            exit 1
        fi
    fi

    mkdir -p "${NEXTPNR_BUILD_DIR}"
    pushd "${NEXTPNR_BUILD_DIR}" >/dev/null

    if [[ -f CMakeCache.txt ]]; then
        local cached_cxx
        cached_cxx="$(sed -n 's/^CMAKE_CXX_COMPILER:FILEPATH=//p' CMakeCache.txt | head -n 1)"
        if [[ -n "${cached_cxx}" && "${cached_cxx}" != "${CXX_BIN}" ]]; then
            echo "[bootstrap] Compiler changed: clearing stale CMake cache"
            rm -f CMakeCache.txt
            rm -rf CMakeFiles
        fi
    fi

    run_backend env CC="${CC_BIN}" CXX="${CXX_BIN}" \
        cmake "${ROOT_DIR}" \
            -DCMAKE_C_COMPILER="${CC_BIN}" \
            -DCMAKE_CXX_COMPILER="${CXX_BIN}" \
            -DARCH=ice40 \
            -DBUILD_GUI=OFF \
            -DBUILD_PYTHON=OFF \
            -DICESTORM_INSTALL_PREFIX="${PREFIX}"

    run_backend env CC="${CC_BIN}" CXX="${CXX_BIN}" make -j"${NPROCS}"

    popd >/dev/null
}

print_summary() {
    banner "Done"
    echo "[bootstrap] BACKEND=${BACKEND}"
    echo "[bootstrap] Built tools in ${PREFIX}"
    echo "[bootstrap] nextpnr build dir: ${NEXTPNR_BUILD_DIR}"
    if [[ "${BACKEND}" == "conda" ]]; then
        echo "[bootstrap] Conda env prefix: ${CONDA_ENV_PREFIX}"
    fi
    echo "[bootstrap] Export toolchain path with:"
    echo "  source ${SCRIPT_DIR}/env.sh"
    echo "[bootstrap] Run end-to-end check with:"
    echo "  ${SCRIPT_DIR}/e2e_blinky.sh"
}

main() {
    mkdir -p "${PREFIX}" "${DEPS_DIR}" "${BUILD_DIR}"
    check_prerequisites
    build_icestorm
    build_yosys
    build_nextpnr_ice40
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
