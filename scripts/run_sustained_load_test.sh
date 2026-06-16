#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
source "${ROOT}/scripts/lib/common.sh"

MQTT_HOST="${MQTT_HOST:-}"
FROM_TERRAFORM="${FROM_TERRAFORM:-false}"
TERRAFORM_DIR="${TERRAFORM_DIR:-.}"
CLIENTS="${CLIENTS:-100}"
PUBLISH_INTERVAL="${PUBLISH_INTERVAL:-0.01}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-8192}"
MESSAGES_PER_BURST="${MESSAGES_PER_BURST:-5}"
CONNECT_STAGGER_SEC="${CONNECT_STAGGER_SEC:-0.05}"
MQTT_CONNECT_TIMEOUT="${MQTT_CONNECT_TIMEOUT:-20}"
CONN_ONLY="${CONN_ONLY:-false}"
LOAD_DURATION_SEC="${LOAD_DURATION_SEC:-0}"
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
  echo "Example: FROM_TERRAFORM=true CLIENTS=200 ./scripts/run_sustained_load_test.sh"
  exit 1
fi

PYTHON="$(bash "${ROOT}/scripts/lib/ensure_venv.sh" "${ROOT}")"
"${PYTHON}" -m pip install -q -r loadtest/requirements.txt

echo "MQTT preflight..."
"${PYTHON}" scripts/mqtt_probe.py --host "${MQTT_HOST}"

ARGS=(
  -u loadtest/staged_load.py
  --host "${MQTT_HOST}"
  --sustained
  --clients "${CLIENTS}"
  --publish-interval "${PUBLISH_INTERVAL}"
  --payload-size "${PAYLOAD_SIZE}"
  --messages-per-burst "${MESSAGES_PER_BURST}"
  --connect-timeout "${MQTT_CONNECT_TIMEOUT}"
  --connect-stagger "${CONNECT_STAGGER_SEC}"
)

if [[ "${CONN_ONLY}" == "true" || "${CONN_ONLY}" == "1" ]]; then
  ARGS+=(--conn-only)
fi
if [[ "${LOAD_DURATION_SEC}" -gt 0 ]]; then
  ARGS+=(--duration "${LOAD_DURATION_SEC}")
fi

if [[ -n "${ASG_NAME}" ]]; then
  ARGS+=(--asg-name "${ASG_NAME}")
fi

export PYTHONUNBUFFERED=1
echo "Sustained load: ${CLIENTS} clients against ${MQTT_HOST} (Ctrl+C to stop)"
exec "${PYTHON}" "${ARGS[@]}"
