#!/usr/bin/env bash
# 300K MQTT connection demo — distributed across load-generator EC2 shards in VPC.
# Prerequisites: terraform apply with terraform.tfvars.300k-demo.example settings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
source "${ROOT}/scripts/lib/common.sh"

AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

TARGET_CLIENTS="${TARGET_CLIENTS:-300000}"
LOAD_GENERATOR_SHARDS="${LOAD_GENERATOR_SHARDS:-10}"
CLIENTS_PER_REPLICANT="${CLIENTS_PER_REPLICANT:-5000}"
CLIENTS_PER_SHARD="${CLIENTS_PER_SHARD:-$((TARGET_CLIENTS / LOAD_GENERATOR_SHARDS))}"
HOLD_SEC="${HOLD_SEC:-600}"
HOLD_PUBLISH_INTERVAL_SEC="${HOLD_PUBLISH_INTERVAL_SEC:-30}"
CONNECT_STAGGER_SEC="${CONNECT_STAGGER_SEC:-0.02}"
MQTT_CONNECT_TIMEOUT="${MQTT_CONNECT_TIMEOUT:-90}"
PREWARM_ASG="${PREWARM_ASG:-true}"

MQTT_HOST="${MQTT_HOST:-$(terraform output -raw mqtt_nlb_dns_name 2>/dev/null || true)}"
ASG_NAME="${ASG_NAME:-$(terraform output -raw replicant_asg_name 2>/dev/null || true)}"

if [[ -z "${MQTT_HOST}" ]]; then
  echo "MQTT_HOST required (terraform apply first)" >&2
  exit 1
fi

if (( CLIENTS_PER_SHARD * LOAD_GENERATOR_SHARDS != TARGET_CLIENTS )); then
  echo "WARNING: shards×per_shard = $((CLIENTS_PER_SHARD * LOAD_GENERATOR_SHARDS)) != TARGET_CLIENTS=${TARGET_CLIENTS}" >&2
fi

REQUIRED_NODES=$(( (TARGET_CLIENTS + CLIENTS_PER_REPLICANT - 1) / CLIENTS_PER_REPLICANT ))
REQUIRED_NODES=$(( REQUIRED_NODES > 2 ? REQUIRED_NODES : 2 ))

echo "============================================================"
echo " EMQX 300K distributed connection demo"
echo "============================================================"
echo "MQTT NLB:           ${MQTT_HOST}"
echo "Target connections: ${TARGET_CLIENTS}"
echo "Load-gen shards:    ${LOAD_GENERATOR_SHARDS} × ${CLIENTS_PER_SHARD} clients"
echo "ASG pre-warm target: ${REQUIRED_NODES} replicants (~${CLIENTS_PER_REPLICANT}/node)"
echo "Hold:               ${HOLD_SEC}s, publish every ${HOLD_PUBLISH_INTERVAL_SEC}s/client"
echo "============================================================"

mapfile -t LG_IDS < <(terraform output -json load_generator_instance_ids 2>/dev/null | python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin)))" || true)
if [[ "${#LG_IDS[@]}" -lt "${LOAD_GENERATOR_SHARDS}" ]]; then
  echo "ERROR: need ${LOAD_GENERATOR_SHARDS} load-generator EC2s, found ${#LG_IDS[@]}." >&2
  echo "Set load_generator_count=${LOAD_GENERATOR_SHARDS} in terraform.tfvars and terraform apply." >&2
  exit 1
fi

PYTHON="$(bash "${ROOT}/scripts/lib/ensure_venv.sh" "${ROOT}")"
"${PYTHON}" scripts/mqtt_probe.py --host "${MQTT_HOST}"

if [[ "${PREWARM_ASG}" == "true" && -n "${ASG_NAME}" ]]; then
  echo ""
  echo "[1/4] Pre-warming ASG ${ASG_NAME} to ${REQUIRED_NODES} replicants (required for 300K)..."
  aws autoscaling set-desired-capacity \
    --region "${AWS_REGION}" \
    --auto-scaling-group-name "${ASG_NAME}" \
    --desired-capacity "${REQUIRED_NODES}" \
    --honor-cooldown
  "${PYTHON}" -c "
import sys, time
sys.path.insert(0, 'loadtest')
from staged_load import wait_asg_min_capacity
ok = wait_asg_min_capacity('${ASG_NAME}', '${AWS_REGION}', ${REQUIRED_NODES}, timeout_sec=3600)
sys.exit(0 if ok else 1)
"
  echo "Pausing 90s for NLB target health..."
  sleep 90
fi

echo ""
echo "[2/4] Deploying loadtest bundle to all load-generators..."
ALL=true bash "${ROOT}/scripts/deploy_loadtest_bundle.sh"
echo "Waiting 45s for SSM deploy..."
sleep 45

echo ""
echo "[3/4] Starting ${LOAD_GENERATOR_SHARDS} shards via SSM..."
for (( shard = 0; shard < LOAD_GENERATOR_SHARDS; shard++ )); do
  iid="${LG_IDS[$shard]}"
  shard_name="lg-${shard}"
  remote_cmd=$(cat <<EOF
set -e
ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true
export MQTT_HOST='${MQTT_HOST}'
export CLIENT_SHARD='${shard_name}'
export CLIENTS='${CLIENTS_PER_SHARD}'
cd /opt/emqx-validation
nohup python3 staged_load.py \\
  --host "\${MQTT_HOST}" \\
  --sustained \\
  --clients "\${CLIENTS}" \\
  --publish-interval ${HOLD_PUBLISH_INTERVAL_SEC} \\
  --messages-per-burst 1 \\
  --payload-size 64 \\
  --connect-stagger ${CONNECT_STAGGER_SEC} \\
  --connect-timeout ${MQTT_CONNECT_TIMEOUT} \\
  --duration ${HOLD_SEC} \\
  > /var/log/emqx-${shard_name}.log 2>&1 &
echo "shard ${shard_name} started pid=\$! clients=\${CLIENTS}"
EOF
)
  params="$(python3 -c "import json,sys; print(json.dumps({'commands': [sys.stdin.read()]}))" <<< "${remote_cmd}")"
  cmd_id="$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids "${iid}" \
    --document-name "AWS-RunShellScript" \
    --parameters "${params}" \
    --query "Command.CommandId" \
    --output text)"
  echo "  shard ${shard_name} → ${iid} (command ${cmd_id})"
done

echo ""
echo "[4/4] Shards launched — open EMQX dashboard Nodes tab."
echo "Total target: ${TARGET_CLIENTS} connections across ${LOAD_GENERATOR_SHARDS} load-generators."
echo ""
echo "Monitor ASG:"
echo "  aws autoscaling describe-auto-scaling-groups --region ${AWS_REGION} \\"
echo "    --auto-scaling-group-names ${ASG_NAME} \\"
echo "    --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Instances:length(Instances)}' --output table"
echo ""
echo "Shard logs (SSM session on each load-generator):"
echo "  tail -f /var/log/emqx-lg-0.log"
echo ""
echo "When finished: terraform destroy"
