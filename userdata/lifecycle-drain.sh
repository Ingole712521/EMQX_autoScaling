#!/bin/bash
# Watches ASG Terminating:Wait and gracefully stops EMQX before completing the lifecycle hook.
set -euo pipefail

REGION="${aws_region}"
ASG_NAME="${asg_name}"
HOOK_NAME="${lifecycle_hook_name}"
DRAIN_GRACE_SEC="${lifecycle_drain_grace_sec}"
LOG="/var/log/emqx-lifecycle-drain.log"

log() {
  echo "[$(date -Is)] $*" | tee -a "$LOG"
}

instance_id() {
  curl -fsS -H "X-aws-ec2-metadata-token: $(curl -fsS -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")" \
    "http://169.254.169.254/latest/meta-data/instance-id"
}

lifecycle_state() {
  local iid="$1"
  aws autoscaling describe-auto-scaling-instances \
    --region "$REGION" \
    --instance-ids "$iid" \
    --query "AutoScalingInstances[0].LifecycleState" \
    --output text 2>/dev/null || echo "Unknown"
}

complete_hook() {
  local iid="$1"
  local token
  token="$(aws autoscaling describe-auto-scaling-instances \
    --region "$REGION" \
    --instance-ids "$iid" \
    --query "AutoScalingInstances[0].LifecycleState" \
    --output text 2>/dev/null || true)"

  log "Completing lifecycle hook $HOOK_NAME for $iid (state=$token)"
  aws autoscaling complete-lifecycle-action \
    --region "$REGION" \
    --auto-scaling-group-name "$ASG_NAME" \
    --lifecycle-hook-name "$HOOK_NAME" \
    --lifecycle-action-result CONTINUE \
    --instance-id "$iid" || log "WARN: complete-lifecycle-action failed (hook may have timed out)"
}

drain_emqx() {
  log "Draining EMQX (graceful stop, wait ${DRAIN_GRACE_SEC}s)"
  if systemctl is-active --quiet emqx 2>/dev/null; then
    systemctl stop emqx || /usr/bin/emqx stop || true
    sleep "$DRAIN_GRACE_SEC"
  fi
  log "EMQX drain complete"
}

main() {
  if [[ -z "$HOOK_NAME" || -z "$ASG_NAME" ]]; then
    exit 0
  fi

  : > "$LOG"
  log "Lifecycle drain watcher started (hook=$HOOK_NAME asg=$ASG_NAME)"

  local iid
  iid="$(instance_id)"
  log "Instance ID: $iid"

  while true; do
    state="$(lifecycle_state "$iid")"
    if [[ "$state" == "Terminating:Wait" ]]; then
      log "Detected Terminating:Wait — starting drain"
      drain_emqx
      complete_hook "$iid"
      log "Lifecycle drain finished"
      exit 0
    fi
    sleep 5
  done
}

main "$@"
