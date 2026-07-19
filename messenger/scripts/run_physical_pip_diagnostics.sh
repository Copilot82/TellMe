#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${IOS_ROOT}/.." && pwd)"
PROJECT_PATH="${IOS_ROOT}/messenger.xcodeproj"
BUNDLE_ID="${PIP_PHYSICAL_BUNDLE_ID:-com.surraund.messenger}"
RUN_ID="${PIP_PHYSICAL_RUN_ID:-pip-physical-$(date +%Y%m%d-%H%M%S)}"
ARTIFACT_ROOT="${PIP_PHYSICAL_ARTIFACT_ROOT:-${IOS_ROOT}/.e2e-artifacts/physical-pip-diagnostics}"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
ITERATIONS="${PIP_PHYSICAL_ITERATIONS:-1}"
COLLECT_DEVICE_CONTAINERS="${PIP_COLLECT_DEVICE_CONTAINERS:-1}"
E2E_API_BASE_URL="${E2E_API_BASE_URL:-https://messenger.surraund.com/api}"
export E2E_API_BASE_URL
PIP_GENERATE_ITERATION_HANDLES="${PIP_GENERATE_ITERATION_HANDLES:-auto}"
PIP_HANDLE_RUN_TOKEN="${PIP_HANDLE_RUN_TOKEN:-$(date +%y%m%d%H%M%S)}"

mkdir -p "${ARTIFACT_DIR}"

for cmd in bash xcodebuild xcrun python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done

snapshot_devices() {
  local label="$1"
  local out_dir="${ARTIFACT_DIR}/device-snapshots/${label}"
  mkdir -p "${out_dir}"

  xcrun devicectl list devices \
    --json-output "${out_dir}/devicectl-devices.json" \
    --log-output "${out_dir}/devicectl-devices.log" \
    >"${out_dir}/devicectl-devices.txt" 2>&1 || true

  xcrun xcdevice list >"${out_dir}/xcdevice-list.json" 2>&1 || true

  xcodebuild -project "${PROJECT_PATH}" -scheme messenger -showdestinations \
    >"${out_dir}/xcodebuild-destinations.txt" 2>&1 || true
}

copy_pip_diagnostics_from_device() {
  local device_id="$1"
  local role="$2"
  local iteration_dir="$3"

  if [[ -z "${device_id}" ]]; then
    return 0
  fi

  local out_dir="${iteration_dir}/device-diagnostics/${role}"
  mkdir -p "${out_dir}"

  xcrun devicectl device info details \
    --device "${device_id}" \
    --json-output "${out_dir}/device-details.json" \
    --log-output "${out_dir}/device-details.log" \
    >"${out_dir}/device-details.txt" 2>&1 || true

  xcrun devicectl device info apps \
    --device "${device_id}" \
    --bundle-id "${BUNDLE_ID}" \
    --json-output "${out_dir}/app-info.json" \
    --log-output "${out_dir}/app-info.log" \
    >"${out_dir}/app-info.txt" 2>&1 || true

  if [[ "${COLLECT_DEVICE_CONTAINERS}" != "1" ]]; then
    return 0
  fi

  xcrun devicectl device info files \
    --device "${device_id}" \
    --domain-type appDataContainer \
    --domain-identifier "${BUNDLE_ID}" \
    --subdirectory "Library/Caches/PiPDiagnostics" \
    --json-output "${out_dir}/pip-files.json" \
    --log-output "${out_dir}/pip-files.log" \
    >"${out_dir}/pip-files.txt" 2>&1 || true

  rm -rf "${out_dir}/PiPDiagnostics"
  xcrun devicectl device copy from \
    --device "${device_id}" \
    --domain-type appDataContainer \
    --domain-identifier "${BUNDLE_ID}" \
    --source "Library/Caches/PiPDiagnostics" \
    --destination "${out_dir}/PiPDiagnostics" \
    --json-output "${out_dir}/pip-copy.json" \
    --log-output "${out_dir}/pip-copy.log" \
    >"${out_dir}/pip-copy.txt" 2>&1 || true
}

is_truthy() {
  local value="${1:-}"
  local normalized
  normalized="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${normalized}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

handle_domain_from_api_base() {
  local without_suffix="${E2E_API_BASE_URL%/api}"
  local without_scheme="${without_suffix#http://}"
  without_scheme="${without_scheme#https://}"
  local host_port="${without_scheme%%/*}"
  local host="${host_port%%:*}"

  if [[ -z "${host}" ]]; then
    echo "messenger.surraund.com"
    return 0
  fi

  echo "${host}"
}

should_generate_iteration_handles() {
  case "${PIP_GENERATE_ITERATION_HANDLES}" in
    auto|"")
      if [[ "${E2E_AUTH_MODE:-register}" == "register" ]]; then
        if (( ITERATIONS > 1 )) || [[ -z "${E2E_INITIATOR_HANDLE:-}" || -z "${E2E_RECEIVER_HANDLE:-}" ]]; then
          return 0
        fi
      fi
      return 1
      ;;
    *)
      is_truthy "${PIP_GENERATE_ITERATION_HANDLES}"
      ;;
  esac
}

generated_iteration_handle() {
  local role_suffix="$1"
  local iteration="$2"
  local handle_domain="${PIP_HANDLE_DOMAIN:-$(handle_domain_from_api_base)}"
  local normalized_token
  normalized_token="$(printf '%s' "${PIP_HANDLE_RUN_TOKEN}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  normalized_token="${normalized_token:0:12}"
  echo "@iospip${normalized_token}i${iteration}${role_suffix}:${handle_domain}"
}

write_run_summary() {
  local status="$1"
  local failed_iteration="${2:-none}"
  local summary="${ARTIFACT_DIR}/summary.txt"

  {
    echo "runId=${RUN_ID}"
    echo "status=${status}"
    echo "failedIteration=${failed_iteration}"
    echo "artifactDir=${ARTIFACT_DIR}"
    echo "iterations=${ITERATIONS}"
    echo "bundleId=${BUNDLE_ID}"
    echo "deviceA=${E2E_DEVICE_A_UDID:-auto}"
    echo "deviceB=${E2E_DEVICE_B_UDID:-auto}"
    echo "apiBaseURL=${E2E_API_BASE_URL}"
    echo "wsBaseURL=${E2E_WS_BASE_URL:-auto}"
    echo "pipRole=${E2E_VALIDATE_CALL_PIP_ROLE:-initiator}"
    echo "pipDelaySeconds=${E2E_CALL_PIP_BACKGROUND_DELAY_SECONDS:-8}"
    echo "pipManualStartBeforeBackground=${E2E_CALL_PIP_MANUAL_START_BEFORE_BACKGROUND:-0}"
    echo "pipTapButtonBeforeBackground=${E2E_CALL_PIP_TAP_BUTTON_BEFORE_BACKGROUND:-0}"
    echo "pipSourceMode=${E2E_CALL_PIP_SOURCE_MODE:-video_call}"
    echo "pipBackgroundAppBundleId=${E2E_CALL_PIP_BACKGROUND_APP_BUNDLE_ID:-none}"
    echo "pipBackgroundAppSeconds=${E2E_CALL_PIP_BACKGROUND_APP_SECONDS:-4}"
    echo "pipGenerateIterationHandles=${PIP_GENERATE_ITERATION_HANDLES}"
    echo "pipHandleRunToken=${PIP_HANDLE_RUN_TOKEN}"
    echo "pipHandleDomain=${PIP_HANDLE_DOMAIN:-$(handle_domain_from_api_base)}"
    echo "performPush=${E2E_PERFORM_PUSH:-0}"
    echo "callDurationSeconds=${E2E_CALL_DURATION_SECONDS:-24}"
  } >"${summary}"
}

snapshot_devices "before"

AVAILABLE_DEVICES=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && AVAILABLE_DEVICES+=("${line}")
done < <(xcrun xcdevice list | python3 "${SCRIPT_DIR}/e2e_json_tools.py" list-physical-iphones)

if (( ${#AVAILABLE_DEVICES[@]} < 2 )); then
  echo "At least two available physical iPhones are required. Found: ${#AVAILABLE_DEVICES[@]}" >&2
  echo "Unlock both devices, trust this Mac, keep them connected, and ensure Developer Mode is enabled." >&2
  write_run_summary "blocked" "device_discovery"
  exit 2
fi

if [[ -z "${E2E_DEVICE_A_UDID:-}" ]]; then
  E2E_DEVICE_A_UDID="${AVAILABLE_DEVICES[0]%%$'\t'*}"
  E2E_DEVICE_A_NAME="${AVAILABLE_DEVICES[0]#*$'\t'}"
fi

if [[ -z "${E2E_DEVICE_B_UDID:-}" ]]; then
  E2E_DEVICE_B_UDID="${AVAILABLE_DEVICES[1]%%$'\t'*}"
  E2E_DEVICE_B_NAME="${AVAILABLE_DEVICES[1]#*$'\t'}"
fi

if [[ "${E2E_DEVICE_A_UDID}" == "${E2E_DEVICE_B_UDID}" ]]; then
  echo "Device A and Device B must be different UDIDs" >&2
  write_run_summary "blocked" "device_selection"
  exit 2
fi

export E2E_DEVICE_A_UDID
export E2E_DEVICE_A_NAME
export E2E_DEVICE_B_UDID
export E2E_DEVICE_B_NAME

echo "[physical-pip] Device A: ${E2E_DEVICE_A_NAME:-DeviceA} (${E2E_DEVICE_A_UDID})"
echo "[physical-pip] Device B: ${E2E_DEVICE_B_NAME:-DeviceB} (${E2E_DEVICE_B_UDID})"

if [[ "${PIP_PHYSICAL_PREFLIGHT_ONLY:-0}" == "1" ]]; then
  snapshot_devices "after"
  write_run_summary "preflight"
  echo "[physical-pip] PREFLIGHT: artifacts at ${ARTIFACT_DIR}"
  exit 0
fi

status=0
failed_iteration="none"

for iteration in $(seq 1 "${ITERATIONS}"); do
  iteration_run_id="${RUN_ID}-iter-${iteration}"
  iteration_root="${ARTIFACT_DIR}/iterations"
  iteration_dir="${iteration_root}/${iteration_run_id}"
  mkdir -p "${iteration_dir}"

  echo "[physical-pip] Iteration ${iteration}/${ITERATIONS}: ${iteration_run_id}"

  iteration_initiator_handle="${E2E_INITIATOR_HANDLE:-}"
  iteration_receiver_handle="${E2E_RECEIVER_HANDLE:-}"
  if should_generate_iteration_handles; then
    iteration_initiator_handle="$(generated_iteration_handle "a" "${iteration}")"
    iteration_receiver_handle="$(generated_iteration_handle "b" "${iteration}")"
    echo "[physical-pip] Generated iteration handles: ${iteration_initiator_handle} -> ${iteration_receiver_handle}"
  fi

  {
    echo "iteration=${iteration}"
    echo "runId=${iteration_run_id}"
    echo "authMode=${E2E_AUTH_MODE:-register}"
    echo "initiatorHandle=${iteration_initiator_handle}"
    echo "receiverHandle=${iteration_receiver_handle}"
  } >"${iteration_dir}/physical-pip-iteration.env"

  set +e
  env \
    E2E_AUTH_MODE="${E2E_AUTH_MODE:-register}" \
    E2E_INITIATOR_HANDLE="${iteration_initiator_handle}" \
    E2E_INITIATOR_SEED="${E2E_INITIATOR_SEED:-}" \
    E2E_RECEIVER_HANDLE="${iteration_receiver_handle}" \
    E2E_RECEIVER_SEED="${E2E_RECEIVER_SEED:-}" \
    E2E_RUN_ID="${iteration_run_id}" \
    E2E_ARTIFACTS_ROOT="${iteration_root}" \
    E2E_SCENARIO_MANIFEST_PATH="${E2E_SCENARIO_MANIFEST_PATH:-${SCRIPT_DIR}/physical_pip_scenarios.json}" \
    E2E_ENABLE_COMPANION="${E2E_ENABLE_COMPANION:-0}" \
    E2E_ALLOW_MAC_AS_THIRD_DEVICE="${E2E_ALLOW_MAC_AS_THIRD_DEVICE:-0}" \
    E2E_PERFORM_CALL_FLOW="${E2E_PERFORM_CALL_FLOW:-1}" \
    E2E_CALL_TYPE="${E2E_CALL_TYPE:-video}" \
    E2E_VALIDATE_CALL_PIP_BACKGROUND="${E2E_VALIDATE_CALL_PIP_BACKGROUND:-1}" \
    E2E_VALIDATE_CALL_PIP_ROLE="${E2E_VALIDATE_CALL_PIP_ROLE:-initiator}" \
    E2E_CALL_PIP_BACKGROUND_DELAY_SECONDS="${E2E_CALL_PIP_BACKGROUND_DELAY_SECONDS:-8}" \
    E2E_CALL_PIP_MANUAL_START_BEFORE_BACKGROUND="${E2E_CALL_PIP_MANUAL_START_BEFORE_BACKGROUND:-0}" \
    E2E_CALL_PIP_TAP_BUTTON_BEFORE_BACKGROUND="${E2E_CALL_PIP_TAP_BUTTON_BEFORE_BACKGROUND:-0}" \
    E2E_CALL_PIP_SOURCE_MODE="${E2E_CALL_PIP_SOURCE_MODE:-video_call}" \
    E2E_CALL_PIP_BACKGROUND_APP_BUNDLE_ID="${E2E_CALL_PIP_BACKGROUND_APP_BUNDLE_ID:-}" \
    E2E_CALL_PIP_BACKGROUND_APP_SECONDS="${E2E_CALL_PIP_BACKGROUND_APP_SECONDS:-4}" \
    E2E_CALL_DURATION_SECONDS="${E2E_CALL_DURATION_SECONDS:-24}" \
    E2E_PERFORM_PUSH="${E2E_PERFORM_PUSH:-0}" \
    E2E_PERFORM_ATTACHMENTS="${E2E_PERFORM_ATTACHMENTS:-0}" \
    E2E_PERFORM_VOICE_MESSAGES="${E2E_PERFORM_VOICE_MESSAGES:-0}" \
    E2E_PERFORM_BLOCK="${E2E_PERFORM_BLOCK:-0}" \
    E2E_PERFORM_DELETE_CHAT="${E2E_PERFORM_DELETE_CHAT:-0}" \
    E2E_PERFORM_DEVICE_LINK="${E2E_PERFORM_DEVICE_LINK:-0}" \
    E2E_PERFORM_SETTINGS="${E2E_PERFORM_SETTINGS:-0}" \
    E2E_PERFORM_SETTINGS_LOGOUT="${E2E_PERFORM_SETTINGS_LOGOUT:-0}" \
    E2E_REQUIRE_NEW_DEVICE_SYNC="${E2E_REQUIRE_NEW_DEVICE_SYNC:-0}" \
    bash "${SCRIPT_DIR}/run_dual_iphone_user_scenarios.sh" \
    2>&1 | tee "${iteration_dir}/physical-pip-wrapper.log"
  iteration_status="${PIPESTATUS[0]}"
  set -e

  copy_pip_diagnostics_from_device "${E2E_DEVICE_A_UDID:-}" "initiator" "${iteration_dir}"
  copy_pip_diagnostics_from_device "${E2E_DEVICE_B_UDID:-}" "receiver" "${iteration_dir}"

  if [[ "${iteration_status}" -ne 0 ]]; then
    status="${iteration_status}"
    failed_iteration="${iteration}"
    break
  fi
done

snapshot_devices "after"

if [[ "${status}" -eq 0 ]]; then
  write_run_summary "pass"
  echo "[physical-pip] PASS: artifacts at ${ARTIFACT_DIR}"
else
  write_run_summary "fail" "${failed_iteration}"
  echo "[physical-pip] FAIL in iteration ${failed_iteration}: artifacts at ${ARTIFACT_DIR}" >&2
fi

exit "${status}"
