#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
source "${ROOT}/scripts/lib/common.sh"

MQTT_HOST="${MQTT_HOST:-}"
ASG_NAME="${ASG_NAME:-}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

TARGET_CLIENTS="${TARGET_CLIENTS:-10000}"
WARMUP_CLIENTS="${WARMUP_CLIENTS:-400}"
MIN_ASG_CAPACITY="${MIN_ASG_CAPACITY:-}"
CLIENTS_PER_REPLICANT="${CLIENTS_PER_REPLICANT:-2000}"
WARMUP_SEC="${WARMUP_SEC:-150}"
HOLD_SEC="${HOLD_SEC:-600}"
HOLD_PUBLISH_INTERVAL_SEC="${HOLD_PUBLISH_INTERVAL_SEC:-30}"
CONNECT_STAGGER_SEC="${CONNECT_STAGGER_SEC:-0.2}"
MQTT_CONNECT_TIMEOUT="${MQTT_CONNECT_TIMEOUT:-60}"

if [[ -z "${MQTT_HOST}" ]]; then
  echo "Set MQTT_HOST (NLB DNS from: terraform output -raw mqtt_nlb_dns_name)" >&2
  exit 1
fi

ulimit -n 65535 2>/dev/null || ulimit -n 8192 2>/dev/null || true
PYTHON="$(bash "${ROOT}/scripts/lib/ensure_venv.sh" "${ROOT}")"
"${PYTHON}" -m pip install -q -r loadtest/requirements.txt
echo "MQTT preflight..."
"${PYTHON}" scripts/mqtt_probe.py --host "${MQTT_HOST}"
export PYTHONUNBUFFERED=1
DEMO_ARGS=(
  -u loadtest/run_2k_demo.py
  --host "${MQTT_HOST}"
  --asg-name "${ASG_NAME}"
  --aws-region "${AWS_REGION}"
  --target-clients "${TARGET_CLIENTS}"
  --warmup-clients "${WARMUP_CLIENTS}"
  --clients-per-replicant "${CLIENTS_PER_REPLICANT}"
  --warmup-sec "${WARMUP_SEC}"
  --hold-sec "${HOLD_SEC}"
  --hold-publish-interval "${HOLD_PUBLISH_INTERVAL_SEC}"
  --connect-stagger "${CONNECT_STAGGER_SEC}"
  --connect-timeout "${MQTT_CONNECT_TIMEOUT}"
)
if [[ -n "${MIN_ASG_CAPACITY}" ]]; then
  DEMO_ARGS+=(--min-asg "${MIN_ASG_CAPACITY}")
fi
exec "${PYTHON}" "${DEMO_ARGS[@]}"
