#!/usr/bin/env bash

# Architecture matrix for local bootstrap entrypoints.
readonly NEXTPNR_BOOTSTRAP_SUPPORTED_ARCHES=(
    ecp5
    nexus
    machxo2
    mistral
    generic
    himbaechel-gowin
    himbaechel-ng-ultra
    himbaechel-gatemate
)

nextpnr_arch_is_supported() {
    local candidate="$1"
    local arch
    for arch in "${NEXTPNR_BOOTSTRAP_SUPPORTED_ARCHES[@]}"; do
        if [[ "${arch}" == "${candidate}" ]]; then
            return 0
        fi
    done
    return 1
}

nextpnr_apply_arch_env_defaults() {
    local arch="$1"
    local root_dir="${NEXTPNR_MVP_ROOT_DIR:-}"
    local deps_dir="${NEXTPNR_MVP_DEPS:-}"
    local deps_install_dir="${NEXTPNR_MVP_DEPS_INSTALL:-}"

    if [[ -z "${deps_dir}" && -n "${root_dir}" ]]; then
        deps_dir="${root_dir}/_deps"
    fi
    if [[ -z "${deps_install_dir}" && -n "${deps_dir}" ]]; then
        deps_install_dir="${deps_dir}/_install"
    fi

    local local_trellis_prefix="${deps_install_dir}/trellis"
    local local_oxide_prefix="${deps_install_dir}/oxide"
    local local_apycula_prefix="${deps_install_dir}/apycula-venv"
    local local_mistral_root="${deps_dir}/mistral"
    local local_prjbeyond_db="${deps_dir}/prjbeyond-db"
    local local_prjpeppercorn="${deps_dir}/prjpeppercorn"

    case "${arch}" in
        ecp5|machxo2)
            local default_trellis_prefix="/usr/local"
            if [[ -d "${local_trellis_prefix}" ]]; then
                default_trellis_prefix="${local_trellis_prefix}"
            fi

            : "${TRELLIS_INSTALL_PREFIX:=${default_trellis_prefix}}"
            if [[ -z "${TRELLIS_LIBDIR:-}" && -d "${TRELLIS_INSTALL_PREFIX}/lib/trellis" ]]; then
                TRELLIS_LIBDIR="${TRELLIS_INSTALL_PREFIX}/lib/trellis"
            fi
            if [[ -z "${TRELLIS_DATADIR:-}" && -d "${TRELLIS_INSTALL_PREFIX}/share/trellis" ]]; then
                TRELLIS_DATADIR="${TRELLIS_INSTALL_PREFIX}/share/trellis"
            fi

            if [[ -z "${TRELLIS_PYTHON_EXECUTABLE:-}" ]]; then
                local pytrellis_python_hint="${TRELLIS_INSTALL_PREFIX}/.pytrellis-python"
                if [[ -f "${pytrellis_python_hint}" ]]; then
                    TRELLIS_PYTHON_EXECUTABLE="$(<"${pytrellis_python_hint}")"
                fi
            fi
            ;;
        nexus)
            local default_oxide_prefix="${HOME}/.cargo"
            if [[ -d "${local_oxide_prefix}" ]]; then
                default_oxide_prefix="${local_oxide_prefix}"
            fi
            : "${OXIDE_INSTALL_PREFIX:=${default_oxide_prefix}}"
            ;;
        mistral)
            if [[ -z "${MISTRAL_ROOT:-}" && -d "${local_mistral_root}" ]]; then
                MISTRAL_ROOT="${local_mistral_root}"
            fi
            ;;
        himbaechel-gowin)
            if [[ -z "${APYCULA_INSTALL_PREFIX:-}" && -d "${local_apycula_prefix}" ]]; then
                APYCULA_INSTALL_PREFIX="${local_apycula_prefix}"
            fi
            ;;
        himbaechel-ng-ultra)
            if [[ -z "${HIMBAECHEL_PRJBEYOND_DB:-}" && -d "${local_prjbeyond_db}" ]]; then
                HIMBAECHEL_PRJBEYOND_DB="${local_prjbeyond_db}"
            fi
            ;;
        himbaechel-gatemate)
            if [[ -z "${HIMBAECHEL_PEPPERCORN_PATH:-}" && -d "${local_prjpeppercorn}" ]]; then
                HIMBAECHEL_PEPPERCORN_PATH="${local_prjpeppercorn}"
            fi
            ;;
        *)
            ;;
    esac
}

nextpnr_load_arch_matrix() {
    local arch="$1"

    NEXTPNR_ARCH_KEY="${arch}"
    NEXTPNR_ARCH_LABEL=""
    NEXTPNR_ARCH_FAMILY=""
    NEXTPNR_ARCH_UARCH=""
    NEXTPNR_ARCH_EXPERIMENTAL=0
    NEXTPNR_ARCH_BINARY=""
    NEXTPNR_ARCH_E2E_SCRIPT=""
    NEXTPNR_ARCH_EXTERNAL_DEPS=()
    NEXTPNR_ARCH_REQUIRED_ENV_HINTS=()
    NEXTPNR_ARCH_CMAKE_ARGS=()

    case "${arch}" in
        ecp5)
            NEXTPNR_ARCH_LABEL="ECP5"
            NEXTPNR_ARCH_FAMILY="ecp5"
            NEXTPNR_ARCH_BINARY="nextpnr-ecp5"
            NEXTPNR_ARCH_EXTERNAL_DEPS=("Project Trellis (pytrellis library + Trellis database)")
            NEXTPNR_ARCH_REQUIRED_ENV_HINTS=(
                "TRELLIS_INSTALL_PREFIX: Trellis install prefix (default: /usr/local)"
                "TRELLIS_LIBDIR/TRELLIS_DATADIR: optional overrides for custom layouts"
                "TRELLIS_PYTHON_EXECUTABLE: Python executable matching pytrellis ABI (optional)"
            )
            NEXTPNR_ARCH_CMAKE_ARGS=(
                "-DARCH=ecp5"
                "-DTRELLIS_INSTALL_PREFIX=${TRELLIS_INSTALL_PREFIX}"
            )
            if [[ -n "${TRELLIS_LIBDIR:-}" ]]; then
                NEXTPNR_ARCH_CMAKE_ARGS+=("-DTRELLIS_LIBDIR=${TRELLIS_LIBDIR}")
            fi
            if [[ -n "${TRELLIS_DATADIR:-}" ]]; then
                NEXTPNR_ARCH_CMAKE_ARGS+=("-DTRELLIS_DATADIR=${TRELLIS_DATADIR}")
            fi
            if [[ -n "${TRELLIS_PYTHON_EXECUTABLE:-}" ]]; then
                NEXTPNR_ARCH_CMAKE_ARGS+=("-DPython3_EXECUTABLE=${TRELLIS_PYTHON_EXECUTABLE}")
            fi
            ;;
        nexus)
            NEXTPNR_ARCH_LABEL="Nexus"
            NEXTPNR_ARCH_FAMILY="nexus"
            NEXTPNR_ARCH_BINARY="nextpnr-nexus"
            NEXTPNR_ARCH_EXPERIMENTAL=1
            NEXTPNR_ARCH_EXTERNAL_DEPS=("Project Oxide (prjoxide CLI + Oxide database)")
            NEXTPNR_ARCH_REQUIRED_ENV_HINTS=(
                "OXIDE_INSTALL_PREFIX: prefix containing bin/prjoxide (default: \$HOME/.cargo)"
            )
            NEXTPNR_ARCH_CMAKE_ARGS=(
                "-DARCH=nexus"
                "-DOXIDE_INSTALL_PREFIX=${OXIDE_INSTALL_PREFIX}"
            )
            ;;
        machxo2)
            NEXTPNR_ARCH_LABEL="MachXO2"
            NEXTPNR_ARCH_FAMILY="machxo2"
            NEXTPNR_ARCH_BINARY="nextpnr-machxo2"
            NEXTPNR_ARCH_EXPERIMENTAL=1
            NEXTPNR_ARCH_E2E_SCRIPT="scripts/machxo2/e2e_smoke.sh"
            NEXTPNR_ARCH_EXTERNAL_DEPS=("Project Trellis (pytrellis library + Trellis database)")
            NEXTPNR_ARCH_REQUIRED_ENV_HINTS=(
                "TRELLIS_INSTALL_PREFIX: Trellis install prefix (default: /usr/local)"
                "TRELLIS_LIBDIR/TRELLIS_DATADIR: optional overrides for custom layouts"
                "TRELLIS_PYTHON_EXECUTABLE: Python executable matching pytrellis ABI (optional)"
            )
            NEXTPNR_ARCH_CMAKE_ARGS=(
                "-DARCH=machxo2"
                "-DTRELLIS_INSTALL_PREFIX=${TRELLIS_INSTALL_PREFIX}"
            )
            if [[ -n "${TRELLIS_LIBDIR:-}" ]]; then
                NEXTPNR_ARCH_CMAKE_ARGS+=("-DTRELLIS_LIBDIR=${TRELLIS_LIBDIR}")
            fi
            if [[ -n "${TRELLIS_DATADIR:-}" ]]; then
                NEXTPNR_ARCH_CMAKE_ARGS+=("-DTRELLIS_DATADIR=${TRELLIS_DATADIR}")
            fi
            if [[ -n "${TRELLIS_PYTHON_EXECUTABLE:-}" ]]; then
                NEXTPNR_ARCH_CMAKE_ARGS+=("-DPython3_EXECUTABLE=${TRELLIS_PYTHON_EXECUTABLE}")
            fi
            ;;
        mistral)
            NEXTPNR_ARCH_LABEL="Mistral (Cyclone V)"
            NEXTPNR_ARCH_FAMILY="mistral"
            NEXTPNR_ARCH_BINARY="nextpnr-mistral"
            NEXTPNR_ARCH_EXPERIMENTAL=1
            NEXTPNR_ARCH_EXTERNAL_DEPS=("Mistral checkout (tools/generator/libmistral)" "liblzma development package")
            NEXTPNR_ARCH_REQUIRED_ENV_HINTS=(
                "MISTRAL_ROOT: path to a Mistral checkout"
            )
            NEXTPNR_ARCH_CMAKE_ARGS=(
                "-DARCH=mistral"
                "-DMISTRAL_ROOT=${MISTRAL_ROOT:-}"
            )
            ;;
        generic)
            NEXTPNR_ARCH_LABEL="Generic"
            NEXTPNR_ARCH_FAMILY="generic"
            NEXTPNR_ARCH_BINARY="nextpnr-generic"
            NEXTPNR_ARCH_EXPERIMENTAL=1
            NEXTPNR_ARCH_E2E_SCRIPT="scripts/generic/e2e_smoke.sh"
            NEXTPNR_ARCH_EXTERNAL_DEPS=("No architecture-specific external database")
            NEXTPNR_ARCH_REQUIRED_ENV_HINTS=()
            NEXTPNR_ARCH_CMAKE_ARGS=(
                "-DARCH=generic"
            )
            ;;
        himbaechel-gowin)
            NEXTPNR_ARCH_LABEL="Himbaechel (Gowin)"
            NEXTPNR_ARCH_FAMILY="himbaechel"
            NEXTPNR_ARCH_UARCH="gowin"
            NEXTPNR_ARCH_BINARY="nextpnr-himbaechel"
            NEXTPNR_ARCH_EXPERIMENTAL=1
            NEXTPNR_ARCH_EXTERNAL_DEPS=("Project Apicula Python package (apycula)")
            NEXTPNR_ARCH_REQUIRED_ENV_HINTS=(
                "APYCULA_INSTALL_PREFIX: optional virtualenv prefix with apycula"
            )
            NEXTPNR_ARCH_CMAKE_ARGS=(
                "-DARCH=himbaechel"
                "-DHIMBAECHEL_UARCH=gowin"
            )
            if [[ -n "${APYCULA_INSTALL_PREFIX:-}" ]]; then
                NEXTPNR_ARCH_CMAKE_ARGS+=("-DAPYCULA_INSTALL_PREFIX=${APYCULA_INSTALL_PREFIX}")
            fi
            ;;
        himbaechel-ng-ultra)
            NEXTPNR_ARCH_LABEL="Himbaechel (NG-Ultra)"
            NEXTPNR_ARCH_FAMILY="himbaechel"
            NEXTPNR_ARCH_UARCH="ng-ultra"
            NEXTPNR_ARCH_BINARY="nextpnr-himbaechel"
            NEXTPNR_ARCH_EXPERIMENTAL=1
            NEXTPNR_ARCH_EXTERNAL_DEPS=("Project Beyond database checkout")
            NEXTPNR_ARCH_REQUIRED_ENV_HINTS=(
                "HIMBAECHEL_PRJBEYOND_DB: path to prjbeyond-db checkout"
            )
            NEXTPNR_ARCH_CMAKE_ARGS=(
                "-DARCH=himbaechel"
                "-DHIMBAECHEL_UARCH=ng-ultra"
                "-DHIMBAECHEL_PRJBEYOND_DB=${HIMBAECHEL_PRJBEYOND_DB:-}"
            )
            ;;
        himbaechel-gatemate)
            NEXTPNR_ARCH_LABEL="Himbaechel (GateMate)"
            NEXTPNR_ARCH_FAMILY="himbaechel"
            NEXTPNR_ARCH_UARCH="gatemate"
            NEXTPNR_ARCH_BINARY="nextpnr-himbaechel"
            NEXTPNR_ARCH_EXPERIMENTAL=1
            NEXTPNR_ARCH_EXTERNAL_DEPS=("Project Peppercorn checkout")
            NEXTPNR_ARCH_REQUIRED_ENV_HINTS=(
                "HIMBAECHEL_PEPPERCORN_PATH: path to prjpeppercorn checkout"
            )
            NEXTPNR_ARCH_CMAKE_ARGS=(
                "-DARCH=himbaechel"
                "-DHIMBAECHEL_UARCH=gatemate"
                "-DHIMBAECHEL_PEPPERCORN_PATH=${HIMBAECHEL_PEPPERCORN_PATH:-}"
            )
            ;;
        *)
            return 1
            ;;
    esac

    return 0
}
