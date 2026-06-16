#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
source "${ROOT}/scripts/lib/common.sh"

MQTT_HOST="${MQTT_HOST:-}"
FROM_TERRAFORM="${FROM_TERRAFORM:-false}"
TERRAFORM_DIR="${TERRAFORM_DIR:-.}"
PUBLISH_INTERVAL="${PUBLISH_INTERVAL:-0.001}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-16384}"
MESSAGES_PER_BURST="${MESSAGES_PER_BURST:-10}"
LOAD_STAGES="${LOAD_STAGES:-40:180:baseline-heavy,80:300:scale-out-2,120:300:scale-out-3,10:90:scale-in}"
ASG_NAME="${ASG_NAME:-}"

if [[ "${FROM_TERRAFORM}" == "true" ]]; then
  if ! command -v terraform >/dev/null 2>&1; then
    echo "terraform is required for FROM_TERRAFORM=true"
    exit 1
  fi
  MQTT_HOST="$(emqx_from_terraform_host "${TERRAFORM_DIR}")"
  ASG_NAME="$(emqx_terraform_output replicant_asg_name "${TERRAFORM_DIR}" || true)"
fi

if [[ -z "${MQTT_HOST}" ]]; then
  echo "Set MQTT_HOST or run with FROM_TERRAFORM=true after terraform apply."
  echo "Example: FROM_TERRAFORM=true ./scripts/run_staged_load_test.sh"
  exit 1
fi

PYTHON="$(bash "${ROOT}/scripts/lib/ensure_venv.sh" "${ROOT}")"
"${PYTHON}" -m pip install -q -r loadtest/requirements.txt

echo "MQTT preflight..."
"${PYTHON}" scripts/mqtt_probe.py --host "${MQTT_HOST}"

ARGS=(
  -u loadtest/staged_load.py
  --host "${MQTT_HOST}"
  --publish-interval "${PUBLISH_INTERVAL}"
  --payload-size "${PAYLOAD_SIZE}"
  --messages-per-burst "${MESSAGES_PER_BURST}"
  --stages "${LOAD_STAGES}"
)

if [[ -n "${ASG_NAME}" ]]; then
  ARGS+=(--asg-name "${ASG_NAME}")
fi

export PYTHONUNBUFFERED=1
echo "Running staged load test against ${MQTT_HOST}"
exec "${PYTHON}" "${ARGS[@]}"
