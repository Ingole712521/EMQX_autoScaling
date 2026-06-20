#!/usr/bin/env bash
# Cluster resilience validation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export EMQX_CORE_IP="${EMQX_CORE_IP:-$(terraform output -raw emqx_core_public_ip)}"
export MQTT_HOST="${MQTT_HOST:-$(terraform output -raw mqtt_nlb_dns_name)}"
export ASG_NAME="${ASG_NAME:-$(terraform output -raw replicant_asg_name)}"
export EMQX_CORE_INSTANCE_ID="${EMQX_CORE_INSTANCE_ID:-$(terraform output -raw emqx_core_instance_id 2>/dev/null || true)}"
export AWS_REGION="${AWS_REGION:-ap-south-1}"

SCENARIO="${SCENARIO:-replicant-terminate}"
LOAD_CLIENTS="${LOAD_CLIENTS:-100}"

python3 -m pip install -q -r loadtest/requirements.txt
python3 loadtest/resilience_test.py \
  --region "$AWS_REGION" \
  --core-ip "$EMQX_CORE_IP" \
  --mqtt-host "$MQTT_HOST" \
  --asg-name "$ASG_NAME" \
  --load-clients "$LOAD_CLIENTS" \
  --scenario "$SCENARIO" \
  ${EMQX_CORE_INSTANCE_ID:+--core-instance-id "$EMQX_CORE_INSTANCE_ID"} \
  --dashboard-user "${EMQX_DASHBOARD_USERNAME:-admin}" \
  --dashboard-password "${EMQX_DASHBOARD_PASSWORD:?Set EMQX_DASHBOARD_PASSWORD}"
