#!/usr/bin/env bash
# EMQX 5.x core bootstrap — overrides via terraform.env (preserves package emqx.conf).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

EMQX_TUNE_NOFILE="${tune_nofile}"
EMQX_TUNE_MAX_PORTS="${tune_max_ports}"
EMQX_TUNE_ACCEPTORS="${tune_acceptors}"
EMQX_TUNE_MAX_CONNECTIONS="${tune_max_connections}"
EMQX_TUNE_DIST_BUFFER_SIZE_KB="${tune_dist_buffer_size_kb}"

${performance_tune_lib}

log() { echo "[$(date -Is)] $*"; }

apt-get update -y
apt-get install -y curl unzip jq ca-certificates gnupg apt-transport-https lsb-release

log "Applying OS + EMQX performance tuning (core)"
apply_emqx_performance_tuning "core"

curl -fsSL https://assets.emqx.com/scripts/install-emqx-deb.sh | bash
apt-get update -y
apt-get install -y emqx

wget -O /tmp/amazon-cloudwatch-agent.deb https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i /tmp/amazon-cloudwatch-agent.deb

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWCFG'
{
  "metrics": {
    "append_dimensions": {
      "AutoScalingGroupName": "$${aws:AutoScalingGroupName}"
    },
    "metrics_collected": {
      "mem": {
        "measurement": [
          "mem_used_percent"
        ]
      }
    }
  }
}
CWCFG

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

EMQX_ENV_FILE="/etc/emqx/terraform.env"
SYSTEMD_DROPIN="/etc/systemd/system/emqx.service.d"

install -d "$SYSTEMD_DROPIN"

cat > "$EMQX_ENV_FILE" <<EOF
EMQX_NODE__NAME="${node_name}"
EMQX_NODE__COOKIE="${node_cookie}"
EMQX_CLUSTER__DISCOVERY_STRATEGY=static
EMQX_CLUSTER__STATIC__SEEDS=${seed_nodes}
EMQX_DASHBOARD__DEFAULT_USERNAME="${dashboard_username}"
EMQX_DASHBOARD__DEFAULT_PASSWORD="${dashboard_password}"
EMQX_DASHBOARD__LISTENERS__HTTP__BIND=18083
EMQX_LISTENERS__TCP__DEFAULT__BIND=0.0.0.0:1883
EMQX_LISTENERS__TCP__DEFAULT__ENABLE_AUTHN=false
EMQX_MQTT__MAX_PACKET_SIZE=1MB
EOF

append_emqx_performance_env "core" >> "$EMQX_ENV_FILE"

cat > "$SYSTEMD_DROPIN/terraform.conf" <<'EOF'
[Service]
EnvironmentFile=-/etc/emqx/terraform.env
EOF

chmod 600 "$EMQX_ENV_FILE"
chmod 644 "$SYSTEMD_DROPIN/terraform.conf"

systemctl daemon-reload
systemctl enable emqx
systemctl restart emqx

for attempt in $(seq 1 60); do
  if ss -tln | grep -q ':1883' && ss -tln | grep -q ':18083'; then
    break
  fi
  sleep 10
done

/usr/bin/emqx ctl status || true
