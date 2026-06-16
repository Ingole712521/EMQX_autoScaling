#!/bin/bash
# Bootstrap Amazon Linux 2 load-generator for EMQX validation tests.
set -euo pipefail

LOG="/var/log/emqx-load-generator-setup.log"

log() {
  echo "[$(date -Is)] $*" | tee -a "$LOG"
}

log "Installing load-generator packages"
yum update -y
yum install -y python3 python3-pip git jq

pip3 install --upgrade pip
pip3 install "paho-mqtt>=2.0.0" "requests>=2.28.0"

install -d -m 0755 /opt/emqx-validation
cat > /opt/emqx-validation/README.txt <<'EOF'
EMQX validation load generator.

Deploy test scripts from your workstation:
  aws ssm start-session --target <this-instance-id>
  # or use scripts/deploy_validation_bundle.ps1

Run durability test:
  python3 /opt/emqx-validation/durability_test.py --host <NLB_DNS> --mode sub
  python3 /opt/emqx-validation/durability_test.py --host <NLB_DNS> --mode pub --count 100000 --rate 2000

Run resilience orchestrator:
  python3 /opt/emqx-validation/resilience_test.py --help
EOF

log "Load generator ready: /opt/emqx-validation"
