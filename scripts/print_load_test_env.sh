#!/usr/bin/env bash
# Print export commands to paste on your Amazon Linux load-generator EC2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
source "${ROOT}/scripts/lib/common.sh"

TERRAFORM_DIR="${TERRAFORM_DIR:-.}"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required (run from project root on your PC)." >&2
  exit 1
fi

MQTT_HOST="$(emqx_from_terraform_host "${TERRAFORM_DIR}")"
ASG_NAME="$(emqx_terraform_output replicant_asg_name "${TERRAFORM_DIR}" || true)"
REGION="$(emqx_terraform_output aws_region "${TERRAFORM_DIR}" 2>/dev/null || true)"
if [[ -z "${REGION}" ]]; then
  REGION="ap-south-1"
fi

cat <<EOF
# Paste on Amazon Linux EC2 (after: git clone <repo> && cd emqx)

export AWS_REGION=${REGION}
export AWS_DEFAULT_REGION=${REGION}
export MQTT_HOST=${MQTT_HOST}
export ASG_NAME=${ASG_NAME}

bash ./scripts/setup_loadgen_amazon_linux.sh
bash ./scripts/run_load_test_on_ec2.sh probe
bash ./scripts/run_load_test_on_ec2.sh staged
# Or sustained (Ctrl+C to stop):
# CLIENTS=100 bash ./scripts/run_load_test_on_ec2.sh sustained
EOF
