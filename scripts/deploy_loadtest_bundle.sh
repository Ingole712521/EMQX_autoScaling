#!/usr/bin/env bash
# Deploy loadtest Python bundle to load-generator EC2(s) via SSM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

REGION="${AWS_REGION:-ap-south-1}"
INSTANCE_IDS="${INSTANCE_IDS:-}"
ALL="${ALL:-false}"

usage() {
  cat <<'EOF'
Usage:
  bash ./scripts/deploy_loadtest_bundle.sh                    # first load-generator
  ALL=true bash ./scripts/deploy_loadtest_bundle.sh           # all load-generators
  INSTANCE_IDS=i-abc,i-def bash ./scripts/deploy_loadtest_bundle.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${INSTANCE_IDS}" ]]; then
  if [[ "${ALL}" == "true" ]]; then
    if ! command -v terraform >/dev/null 2>&1; then
      echo "terraform required to resolve load_generator_instance_ids" >&2
      exit 1
    fi
    mapfile -t IDS < <(terraform output -json load_generator_instance_ids 2>/dev/null | python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin)))")
    INSTANCE_IDS="$(IFS=,; echo "${IDS[*]}")"
  else
    INSTANCE_IDS="$(terraform output -raw load_generator_instance_id 2>/dev/null || true)"
  fi
fi

if [[ -z "${INSTANCE_IDS}" ]]; then
  echo "No load-generator instance IDs. Set enable_load_generator=true and apply." >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
cp loadtest/staged_load.py loadtest/mqtt_common.py loadtest/requirements.txt "${STAGING}/"

ZIP="$(mktemp)"
trap 'rm -rf "${STAGING}" "${ZIP}"' EXIT
(
  cd "${STAGING}"
  zip -q "${ZIP}" staged_load.py mqtt_common.py requirements.txt
)

B64="$(base64 -w 0 "${ZIP}" 2>/dev/null || base64 "${ZIP}" | tr -d '\n')"

deploy_one() {
  local iid="$1"
  local remote_cmds=(
    "rm -rf /tmp/emqx-loadtest.b64 /tmp/emqx-loadtest.zip"
    "mkdir -p /opt/emqx-validation"
  )
  local chunk_size=4000
  local offset=0
  local len=${#B64}
  while (( offset < len )); do
    local chunk="${B64:offset:chunk_size}"
    remote_cmds+=("printf '%s' '${chunk}' >> /tmp/emqx-loadtest.b64")
    offset=$((offset + chunk_size))
  done
  remote_cmds+=(
    "base64 -d /tmp/emqx-loadtest.b64 > /tmp/emqx-loadtest.zip"
    "cd /opt/emqx-validation && unzip -o /tmp/emqx-loadtest.zip"
    "pip3 install -q -r /opt/emqx-validation/requirements.txt"
    "rm -f /tmp/emqx-loadtest.b64 /tmp/emqx-loadtest.zip"
    "ls -la /opt/emqx-validation/staged_load.py"
  )

  local params
  params="$(python3 -c "import json,sys; print(json.dumps({'commands': sys.argv[1:]}))" "${remote_cmds[@]}")"

  echo "Deploying loadtest bundle to ${iid}..."
  aws ssm send-command \
    --region "${REGION}" \
    --instance-ids "${iid}" \
    --document-name "AWS-RunShellScript" \
    --parameters "${params}" \
    --output text \
    --query "Command.CommandId"
}

IFS=',' read -ra ID_ARR <<< "${INSTANCE_IDS}"
for id in "${ID_ARR[@]}"; do
  id="${id// /}"
  [[ -n "${id}" ]] || continue
  deploy_one "${id}"
done

echo "Bundle deploy commands sent. Wait ~30s before starting 300K shards."
