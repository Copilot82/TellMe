#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/messenger/messenger.xcodeproj"
SCHEME="${PIP_DIAG_SCHEME:-messenger}"
BUNDLE_ID="${PIP_DIAG_BUNDLE_ID:-com.surraund.messenger}"
DURATION_SECONDS="${PIP_DIAG_DURATION_SECONDS:-60}"
ARTIFACT_ROOT="${PIP_DIAG_ARTIFACT_ROOT:-${REPO_ROOT}/messenger/.e2e-artifacts/pip-diagnostics}"
RUN_ID="${PIP_DIAG_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
DERIVED_DATA_PATH="${PIP_DIAG_DERIVED_DATA:-${REPO_ROOT}/messenger/.e2e-derived-data/pip-diagnostics}"
START_ROUTE="${PIP_DIAG_START_ROUTE:-call_active}"
STUB_NETWORK="${PIP_DIAG_STUB_NETWORK:-1}"
BOOTSTRAP_SAMPLE_DATA="${PIP_DIAG_BOOTSTRAP_SAMPLE_DATA:-1}"
DISABLE_REALTIME="${PIP_DIAG_DISABLE_REALTIME:-1}"
RESET_STATE="${PIP_DIAG_RESET_STATE:-1}"

mkdir -p "${ARTIFACT_DIR}" "${DERIVED_DATA_PATH}"

select_simulator() {
  if [[ -n "${PIP_DIAG_SIMULATOR_ID:-}" ]]; then
    printf '%s' "${PIP_DIAG_SIMULATOR_ID}"
    return
  fi

  python3 - <<'PY'
import json
import subprocess
import sys

raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "-j"], text=True)
devices = json.loads(raw).get("devices", {})
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device.get("state") == "Booted":
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
PY
}

SIMULATOR_ID="$(select_simulator || true)"
if [[ -z "${SIMULATOR_ID}" ]]; then
  echo "No booted simulator found. Boot one in Xcode or Simulator, then rerun this script." >&2
  exit 2
fi

BUILD_LOG="${ARTIFACT_DIR}/xcodebuild-build.log"
SIM_LOG="${ARTIFACT_DIR}/simulator-log-stream.log"
LAUNCH_LOG="${ARTIFACT_DIR}/simctl-launch.log"
SUMMARY_PATH="${ARTIFACT_DIR}/summary.txt"
SCREENSHOT_PATH="${ARTIFACT_DIR}/final-screenshot.png"

if [[ "${PIP_DIAG_SKIP_BUILD:-0}" != "1" ]]; then
  xcodebuild build \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "id=${SIMULATOR_ID}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    2>&1 | tee "${BUILD_LOG}"
fi

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug-iphonesimulator/messenger.app"
if [[ ! -d "${APP_PATH}" ]]; then
  APP_PATH="$(find "${DERIVED_DATA_PATH}/Build/Products" -path "*/messenger.app" -type d | head -n 1)"
fi

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "Built app not found under ${DERIVED_DATA_PATH}/Build/Products" >&2
  exit 3
fi

xcrun simctl install "${SIMULATOR_ID}" "${APP_PATH}"

LOG_PREDICATE='process == "messenger" OR subsystem == "com.surraund.messenger" OR eventMessage CONTAINS[c] "call_pip" OR eventMessage CONTAINS[c] "PictureInPicture" OR eventMessage CONTAINS[c] "PiP"'
xcrun simctl spawn "${SIMULATOR_ID}" log stream \
  --style compact \
  --level debug \
  --predicate "${LOG_PREDICATE}" \
  >"${SIM_LOG}" 2>&1 &
LOG_PID="$!"

cleanup() {
  if kill -0 "${LOG_PID}" >/dev/null 2>&1; then
    kill "${LOG_PID}" >/dev/null 2>&1 || true
    wait "${LOG_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${PIP_DIAG_NO_LAUNCH:-0}" != "1" ]]; then
  env \
    SIMCTL_CHILD_UITEST_MODE=1 \
    SIMCTL_CHILD_UITEST_STORAGE_NAMESPACE="pip-diagnostics-${RUN_ID}" \
    SIMCTL_CHILD_UITEST_RESET_STATE="${RESET_STATE}" \
    SIMCTL_CHILD_UITEST_BOOTSTRAP_SAMPLE_DATA="${BOOTSTRAP_SAMPLE_DATA}" \
    SIMCTL_CHILD_UITEST_STUB_NETWORK="${STUB_NETWORK}" \
    SIMCTL_CHILD_UITEST_DISABLE_REALTIME="${DISABLE_REALTIME}" \
    SIMCTL_CHILD_UITEST_REQUEST_NOTIFICATIONS=0 \
    SIMCTL_CHILD_UITEST_START_ROUTE="${START_ROUTE}" \
    SIMCTL_CHILD_MESSENGER_APP_ENV=local \
    xcrun simctl launch --terminate-running-process "${SIMULATOR_ID}" "${BUNDLE_ID}" \
    2>&1 | tee "${LAUNCH_LOG}"
fi

echo "Collecting PiP diagnostics for ${DURATION_SECONDS}s. Interact with the app now if needed."
sleep "${DURATION_SECONDS}"

xcrun simctl io "${SIMULATOR_ID}" screenshot "${SCREENSHOT_PATH}" >/dev/null 2>&1 || true

CONTAINER_PATH="$(xcrun simctl get_app_container "${SIMULATOR_ID}" "${BUNDLE_ID}" data 2>/dev/null || true)"
if [[ -n "${CONTAINER_PATH}" ]]; then
  echo "${CONTAINER_PATH}" >"${ARTIFACT_DIR}/app-container-path.txt"
  if [[ -d "${CONTAINER_PATH}/Library/Caches/PiPDiagnostics" ]]; then
    cp -R "${CONTAINER_PATH}/Library/Caches/PiPDiagnostics" "${ARTIFACT_DIR}/PiPDiagnostics"
  fi
fi

xcrun simctl spawn "${SIMULATOR_ID}" log collect \
  --last "${DURATION_SECONDS}s" \
  --output "${ARTIFACT_DIR}/system.logarchive" \
  >/dev/null 2>&1 || true

{
  echo "runId=${RUN_ID}"
  echo "simulator=${SIMULATOR_ID}"
  echo "bundleId=${BUNDLE_ID}"
  echo "durationSeconds=${DURATION_SECONDS}"
  echo "artifactDir=${ARTIFACT_DIR}"
  echo "startRoute=${START_ROUTE}"
  echo "stubNetwork=${STUB_NETWORK}"
  echo "bootstrapSampleData=${BOOTSTRAP_SAMPLE_DATA}"
  echo "disableRealtime=${DISABLE_REALTIME}"
  echo "resetState=${RESET_STATE}"
  echo "appPath=${APP_PATH}"
  echo "containerPath=${CONTAINER_PATH:-none}"
} >"${SUMMARY_PATH}"

echo "PiP diagnostic artifacts: ${ARTIFACT_DIR}"
