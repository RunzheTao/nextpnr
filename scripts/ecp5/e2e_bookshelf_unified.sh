#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PREFIX="${NEXTPNR_MVP_TOOLCHAIN:-${ROOT_DIR}/_toolchain}"
BUILD_DIR="${NEXTPNR_MVP_BUILD:-${ROOT_DIR}/_build}"
BACKEND="${NEXTPNR_MVP_DEPS_BACKEND:-conda}"
CONDA_ENV_PREFIX="${NEXTPNR_MVP_CONDA_PREFIX:-${ROOT_DIR}/_conda_env/nextpnr}"

YOSYS_BIN="${YOSYS_BIN:-${PREFIX}/bin/yosys}"
NEXTPNR_BIN="${NEXTPNR_BIN:-${BUILD_DIR}/nextpnr-ecp5/nextpnr-ecp5}"
EXPORT_SCRIPT="${NEXTPNR_BOOKSHELF_EXPORT_SCRIPT:-${ROOT_DIR}/python/export_bookshelf_prepack.py}"

DESIGN_NAME="${NEXTPNR_BOOKSHELF_DESIGN_NAME:-unified_bench}"
TOP_MODULE="${NEXTPNR_BOOKSHELF_TOP:-${DESIGN_NAME}}"
SEED="${NEXTPNR_BOOKSHELF_SEED:-1}"
PACKAGE="${NEXTPNR_BOOKSHELF_PACKAGE:-CABGA381}"

BENCH_DIR="${NEXTPNR_BOOKSHELF_BENCH_DIR:-${ROOT_DIR}/_bench/ecp5_unified}"
RTL_DIR="${BENCH_DIR}/rtl"
DEFAULT_RTL_PATH="${RTL_DIR}/${DESIGN_NAME}.v"
RTL_PATH="${NEXTPNR_BOOKSHELF_RTL:-${DEFAULT_RTL_PATH}}"
NETLIST="${NEXTPNR_BOOKSHELF_NETLIST:-${BENCH_DIR}/${DESIGN_NAME}.json}"
OUT_ROOT="${NEXTPNR_BOOKSHELF_OUT_ROOT:-${BENCH_DIR}/out}"
NETLIST_SHA_FILE="${BENCH_DIR}/netlist.sha256"

DEVICE_NAMES=("LFE5U-12F" "LFE5U-45F" "LFE5U-85F")
DEVICE_FLAGS=("--12k" "--45k" "--85k")

status=("blocked" "blocked" "blocked")
reason=("" "" "")
local_pass=(0 0 0)
instances=("" "" "")
nets=("" "" "")
pin_refs=("" "" "")
nodes_sha=("" "" "")
nets_sha=("" "" "")
lib_sha=("" "" "")
name_map_sha=("" "" "")

die() {
    echo "[e2e-ecp5-bookshelf] ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_exec() {
    [[ -x "$1" ]] || die "Missing executable: $1"
}

require_file() {
    [[ -f "$1" ]] || die "Missing file: $1"
}

require_nextpnr_run_support() {
    local help_output
    if ! help_output="$(run_backend "${NEXTPNR_BIN}" --help 2>&1)"; then
        die "Failed to execute '${NEXTPNR_BIN} --help': ${help_output}"
    fi
    if ! grep -Fq -- "--run arg" <<<"${help_output}"; then
        die "Binary '${NEXTPNR_BIN}' does not support --run. Rebuild nextpnr with -DBUILD_PYTHON=ON."
    fi
}

set_blocked() {
    local idx="$1"
    shift
    status[$idx]="blocked"
    reason[$idx]="$*"
}

append_blocked_reason() {
    local idx="$1"
    shift
    if [[ -n "${reason[$idx]}" ]]; then
        reason[$idx]+="; $*"
    else
        reason[$idx]="$*"
    fi
    status[$idx]="blocked"
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

sha256_file() {
    local target="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${target}" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${target}" | awk '{print $1}'
    else
        die "Neither sha256sum nor shasum is available"
    fi
}

write_default_rtl() {
    mkdir -p "${RTL_DIR}"
    cat > "${DEFAULT_RTL_PATH}" <<'RTL'
module unified_bench(
    input wire clk,
    input wire [7:0] a,
    input wire [7:0] b,
    output wire [7:0] y
);
    reg [7:0] r = 8'h00;
    always @(posedge clk) begin
        r <= a + b;
    end
    assign y = r ^ (a & b);
endmodule
RTL
    echo "[e2e-ecp5-bookshelf] Wrote default RTL: ${DEFAULT_RTL_PATH}"
}

check_name_map_reversible() {
    local map_json="$1"
    python3 - "${map_json}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)

orig_to_safe = payload.get("orig_to_safe")
safe_to_orig = payload.get("safe_to_orig")
if not isinstance(orig_to_safe, dict):
    raise SystemExit("orig_to_safe must be a JSON object")
if not isinstance(safe_to_orig, dict):
    raise SystemExit("safe_to_orig must be a JSON object")

safe_values = list(orig_to_safe.values())
if len(safe_values) != len(set(safe_values)):
    raise SystemExit("orig_to_safe contains duplicated safe names")

orig_values = list(safe_to_orig.values())
if len(orig_values) != len(set(orig_values)):
    raise SystemExit("safe_to_orig contains duplicated original scoped names")

for orig_name, safe_name in orig_to_safe.items():
    back = safe_to_orig.get(safe_name)
    if back != orig_name:
        raise SystemExit(f"mapping is not reversible: {orig_name} -> {safe_name} -> {back}")

for safe_name, orig_name in safe_to_orig.items():
    back = orig_to_safe.get(orig_name)
    if back != safe_name:
        raise SystemExit(f"mapping is not reversible: {safe_name} -> {orig_name} -> {back}")
PY
}

check_openparf_device_field() {
    local openparf_json="$1"
    local expected_device="$2"
    python3 - "${openparf_json}" "${expected_device}" <<'PY'
import json
import sys

path = sys.argv[1]
expected = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)

actual = str(payload.get("device", ""))
if actual != expected:
    raise SystemExit(f"openparf device mismatch: expected '{expected}', got '{actual}'")
PY
}

prepare_unified_netlist() {
    mkdir -p "${BENCH_DIR}" "${OUT_ROOT}"

    if [[ -n "${NEXTPNR_BOOKSHELF_NETLIST:-}" ]]; then
        require_file "${NETLIST}"
        echo "[e2e-ecp5-bookshelf] Using existing netlist: ${NETLIST}"
    else
        if [[ ! -f "${RTL_PATH}" ]]; then
            if [[ "${RTL_PATH}" == "${DEFAULT_RTL_PATH}" ]]; then
                write_default_rtl
            else
                die "RTL not found: ${RTL_PATH}. Set NEXTPNR_BOOKSHELF_RTL to a valid file."
            fi
        fi

        echo "[e2e-ecp5-bookshelf] Synthesizing shared netlist from ${RTL_PATH}"
        run_backend "${YOSYS_BIN}" -p "read_verilog ${RTL_PATH}; synth_ecp5 -top ${TOP_MODULE} -json ${NETLIST}" \
            2>&1 | tee "${BENCH_DIR}/synth.log"
    fi

    local netlist_sha
    netlist_sha="$(sha256_file "${NETLIST}")"
    printf '%s  %s\n' "${netlist_sha}" "${NETLIST}" > "${NETLIST_SHA_FILE}"
    echo "[e2e-ecp5-bookshelf] Netlist SHA256: ${netlist_sha}"
}

validate_device_output() {
    local idx="$1"
    local device="${DEVICE_NAMES[$idx]}"
    local out_dir="${OUT_ROOT}/${device}"
    local log_file="${out_dir}/export.log"
    local design
    local missing=()

    design="$(sed -n 's/^\[bookshelf-export\] design=//p' "${log_file}" | tail -n 1)"
    if [[ -z "${design}" ]]; then
        set_blocked "${idx}" "cannot parse exported design name from ${log_file}"
        return
    fi

    local aux_file="${out_dir}/${design}.aux"
    local lib_file="${out_dir}/${design}.lib"
    local nodes_file="${out_dir}/${design}.nodes"
    local nets_file="${out_dir}/${design}.nets"
    local pl_file="${out_dir}/${design}.pl"
    local scl_file="${out_dir}/${design}.scl"
    local wts_file="${out_dir}/${design}.wts"
    local name_map_file="${out_dir}/${design}.name_map.json"
    local openparf_file="${out_dir}/${design}_openparf.json"

    local required_files=(
        "${aux_file}" "${lib_file}" "${nodes_file}" "${nets_file}" "${pl_file}" "${scl_file}" "${wts_file}"
        "${name_map_file}" "${openparf_file}"
    )

    local file
    for file in "${required_files[@]}"; do
        if [[ ! -f "${file}" ]]; then
            missing+=("${file##*/}")
        fi
    done
    if ((${#missing[@]} > 0)); then
        set_blocked "${idx}" "missing exported files: ${missing[*]}"
        return
    fi

    local declared_instances declared_nets declared_pin_refs
    declared_instances="$(sed -n 's/^\[bookshelf-export\] instances=\([0-9][0-9]*\)$/\1/p' "${log_file}" | tail -n 1)"
    declared_nets="$(sed -n 's/^\[bookshelf-export\] nets=\([0-9][0-9]*\)$/\1/p' "${log_file}" | tail -n 1)"
    declared_pin_refs="$(sed -n 's/^\[bookshelf-export\] pin_refs=\([0-9][0-9]*\)$/\1/p' "${log_file}" | tail -n 1)"
    if [[ -z "${declared_instances}" || -z "${declared_nets}" || -z "${declared_pin_refs}" ]]; then
        set_blocked "${idx}" "cannot parse exporter counts from ${log_file}"
        return
    fi

    local actual_instances actual_nets actual_pin_refs
    actual_instances="$(wc -l < "${nodes_file}" | tr -d '[:space:]')"
    actual_nets="$(awk '$1=="net"{count+=1} END{print count+0}' "${nets_file}")"
    actual_pin_refs="$(awk '$1=="net"{sum+=$3} END{print sum+0}' "${nets_file}")"

    if [[ "${declared_instances}" != "${actual_instances}" ]]; then
        set_blocked "${idx}" "instances mismatch: log=${declared_instances}, nodes=${actual_instances}"
        return
    fi
    if [[ "${declared_nets}" != "${actual_nets}" ]]; then
        set_blocked "${idx}" "nets mismatch: log=${declared_nets}, nets_file=${actual_nets}"
        return
    fi
    if [[ "${declared_pin_refs}" != "${actual_pin_refs}" ]]; then
        set_blocked "${idx}" "pin_refs mismatch: log=${declared_pin_refs}, nets_file=${actual_pin_refs}"
        return
    fi

    local name_map_check_err
    if ! name_map_check_err="$(check_name_map_reversible "${name_map_file}" 2>&1)"; then
        set_blocked "${idx}" "name_map reversibility check failed: ${name_map_check_err}"
        return
    fi

    local device_check_err
    if ! device_check_err="$(check_openparf_device_field "${openparf_file}" "${device}" 2>&1)"; then
        set_blocked "${idx}" "openparf metadata check failed: ${device_check_err}"
        return
    fi

    instances[$idx]="${actual_instances}"
    nets[$idx]="${actual_nets}"
    pin_refs[$idx]="${actual_pin_refs}"
    nodes_sha[$idx]="$(sha256_file "${nodes_file}")"
    nets_sha[$idx]="$(sha256_file "${nets_file}")"
    lib_sha[$idx]="$(sha256_file "${lib_file}")"
    name_map_sha[$idx]="$(sha256_file "${name_map_file}")"

    status[$idx]="passed"
    reason[$idx]=""
    local_pass[$idx]=1
}

run_one_device() {
    local idx="$1"
    local device="${DEVICE_NAMES[$idx]}"
    local flag="${DEVICE_FLAGS[$idx]}"
    local out_dir="${OUT_ROOT}/${device}"
    local log_file="${out_dir}/export.log"

    mkdir -p "${out_dir}"
    echo "[e2e-ecp5-bookshelf] Running ${device} (${flag})"

    if ! NEXTPNR_BOOKSHELF_OUT_DIR="${out_dir}" \
        NEXTPNR_BOOKSHELF_DESIGN_NAME="${DESIGN_NAME}" \
        NEXTPNR_BOOKSHELF_FAMILY="ecp5" \
        NEXTPNR_BOOKSHELF_DEVICE="${device}" \
        NEXTPNR_BOOKSHELF_PACKAGE="${PACKAGE}" \
        run_backend "${NEXTPNR_BIN}" "${flag}" --json "${NETLIST}" --seed "${SEED}" --pack-only \
        --package "${PACKAGE}" --run "${EXPORT_SCRIPT}" 2>&1 | tee "${log_file}"; then
        set_blocked "${idx}" "nextpnr export failed, see ${log_file}"
        return
    fi

    validate_device_output "${idx}"
}

check_cross_device_consistency() {
    local i j
    local local_pass_count=0
    for i in "${!DEVICE_NAMES[@]}"; do
        if [[ "${local_pass[$i]}" == "1" ]]; then
            ((local_pass_count += 1))
        fi
    done

    if ((local_pass_count < ${#DEVICE_NAMES[@]})); then
        echo "[e2e-ecp5-bookshelf] NOTE: cross-device checks are partial because some devices are blocked."
    fi

    for ((i = 0; i < ${#DEVICE_NAMES[@]}; i++)); do
        if [[ "${local_pass[$i]}" != "1" ]]; then
            continue
        fi
        for ((j = i + 1; j < ${#DEVICE_NAMES[@]}; j++)); do
            if [[ "${local_pass[$j]}" != "1" ]]; then
                continue
            fi
            if [[ "${instances[$i]}" != "${instances[$j]}" ]]; then
                append_blocked_reason "${i}" "instances mismatch vs ${DEVICE_NAMES[$j]} (${instances[$i]} != ${instances[$j]})"
                append_blocked_reason "${j}" "instances mismatch vs ${DEVICE_NAMES[$i]} (${instances[$j]} != ${instances[$i]})"
            fi
            if [[ "${nets[$i]}" != "${nets[$j]}" ]]; then
                append_blocked_reason "${i}" "nets mismatch vs ${DEVICE_NAMES[$j]} (${nets[$i]} != ${nets[$j]})"
                append_blocked_reason "${j}" "nets mismatch vs ${DEVICE_NAMES[$i]} (${nets[$j]} != ${nets[$i]})"
            fi
            if [[ "${pin_refs[$i]}" != "${pin_refs[$j]}" ]]; then
                append_blocked_reason "${i}" "pin_refs mismatch vs ${DEVICE_NAMES[$j]} (${pin_refs[$i]} != ${pin_refs[$j]})"
                append_blocked_reason "${j}" "pin_refs mismatch vs ${DEVICE_NAMES[$i]} (${pin_refs[$j]} != ${pin_refs[$i]})"
            fi
            if [[ "${nodes_sha[$i]}" != "${nodes_sha[$j]}" ]]; then
                append_blocked_reason "${i}" ".nodes sha256 mismatch vs ${DEVICE_NAMES[$j]}"
                append_blocked_reason "${j}" ".nodes sha256 mismatch vs ${DEVICE_NAMES[$i]}"
            fi
            if [[ "${nets_sha[$i]}" != "${nets_sha[$j]}" ]]; then
                append_blocked_reason "${i}" ".nets sha256 mismatch vs ${DEVICE_NAMES[$j]}"
                append_blocked_reason "${j}" ".nets sha256 mismatch vs ${DEVICE_NAMES[$i]}"
            fi
            if [[ "${lib_sha[$i]}" != "${lib_sha[$j]}" ]]; then
                append_blocked_reason "${i}" ".lib sha256 mismatch vs ${DEVICE_NAMES[$j]}"
                append_blocked_reason "${j}" ".lib sha256 mismatch vs ${DEVICE_NAMES[$i]}"
            fi
            if [[ "${name_map_sha[$i]}" != "${name_map_sha[$j]}" ]]; then
                append_blocked_reason "${i}" ".name_map.json sha256 mismatch vs ${DEVICE_NAMES[$j]}"
                append_blocked_reason "${j}" ".name_map.json sha256 mismatch vs ${DEVICE_NAMES[$i]}"
            fi
        done
    done
}

print_summary() {
    local idx
    echo
    echo "[e2e-ecp5-bookshelf] Shared netlist: ${NETLIST}"
    echo "[e2e-ecp5-bookshelf] Netlist sha256: $(sha256_file "${NETLIST}")"
    for idx in "${!DEVICE_NAMES[@]}"; do
        if [[ "${status[$idx]}" == "passed" ]]; then
            echo "[e2e-ecp5-bookshelf] ${DEVICE_NAMES[$idx]}: passed (instances=${instances[$idx]}, nets=${nets[$idx]}, pin_refs=${pin_refs[$idx]})"
        else
            echo "[e2e-ecp5-bookshelf] ${DEVICE_NAMES[$idx]}: blocked(${reason[$idx]})"
        fi
    done
}

main() {
    [[ -n "${DESIGN_NAME}" ]] || die "NEXTPNR_BOOKSHELF_DESIGN_NAME cannot be empty"
    [[ -n "${TOP_MODULE}" ]] || die "NEXTPNR_BOOKSHELF_TOP cannot be empty"
    [[ -n "${PACKAGE}" ]] || die "NEXTPNR_BOOKSHELF_PACKAGE cannot be empty"
    [[ "${SEED}" =~ ^[0-9]+$ ]] || die "NEXTPNR_BOOKSHELF_SEED must be a non-negative integer, got '${SEED}'"
    [[ "${BACKEND}" == "conda" || "${BACKEND}" == "system" ]] || \
        die "NEXTPNR_MVP_DEPS_BACKEND must be 'conda' or 'system', got '${BACKEND}'"

    require_cmd awk
    require_cmd sed
    require_cmd tee
    require_cmd python3
    require_exec "${YOSYS_BIN}"
    require_exec "${NEXTPNR_BIN}"
    require_file "${EXPORT_SCRIPT}"
    require_nextpnr_run_support

    prepare_unified_netlist

    local idx
    for idx in "${!DEVICE_NAMES[@]}"; do
        run_one_device "${idx}"
    done

    check_cross_device_consistency
    print_summary

    local blocked_count=0
    for idx in "${!DEVICE_NAMES[@]}"; do
        if [[ "${status[$idx]}" != "passed" ]]; then
            ((blocked_count += 1))
        fi
    done

    if ((blocked_count > 0)); then
        die "${blocked_count} device(s) blocked"
    fi

    echo "[e2e-ecp5-bookshelf] SUCCESS: all devices passed unified bookshelf export checks"
}

main "$@"
