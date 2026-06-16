#!/usr/bin/env bash
# EMQX 5.8.x replicant — joins core cluster via Route53 seeds, serves NLB MQTT traffic.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

EMQX_TUNE_NOFILE="${tune_nofile}"
EMQX_TUNE_MAX_PORTS="${tune_max_ports}"
EMQX_TUNE_ACCEPTORS="${tune_acceptors}"
EMQX_TUNE_MAX_CONNECTIONS="${tune_max_connections}"
EMQX_TUNE_DIST_BUFFER_SIZE_KB="${tune_dist_buffer_size_kb}"

${performance_tune_lib}

LOG="/var/log/emqx-bootstrap.log"
OK_MARKER="/var/log/emqx-bootstrap.ok"
EMQX_ENV_FILE="/etc/emqx/terraform.env"
SYSTEMD_DROPIN="/etc/systemd/system/emqx.service.d"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }
fail() { log "ERROR: $*"; journalctl -u emqx --no-pager -n 50 || true; exit 1; }

log "Replicant bootstrap started"
: > "$LOG"
rm -f "$OK_MARKER"

apt-get update -y
apt-get install -y curl gnupg apt-transport-https ca-certificates lsb-release netcat-openbsd jq

log "Applying OS + EMQX performance tuning (replicant)"
apply_emqx_performance_tuning "replicant"

curl -fsSL https://assets.emqx.com/scripts/install-emqx-deb.sh | bash
apt-get update -y
apt-get install -y emqx

PRIVATE_IP=$(curl -sf http://169.254.169.254/latest/meta-data/local-ipv4)
log "Private IP: $PRIVATE_IP"

# Wait for at least one core seed (Erlang distribution ports).
FIRST_SEED=$(echo ${seed_nodes} | jq -r '.[0]')
SEED_HOST="${FIRST_SEED#emqx@}"
log "Waiting for core seed $SEED_HOST (ports 5369/4370)"

for attempt in $(seq 1 90); do
  CORE_IP=$(getent hosts "$SEED_HOST" | awk '{print $1}' | head -1)
  if [[ -n "$CORE_IP" ]] && { nc -z "$CORE_IP" 5369 2>/dev/null || nc -z "$CORE_IP" 4370 2>/dev/null; }; then
    log "Core reachable at $CORE_IP (attempt $attempt)"
    break
  fi
  log "Core not ready (attempt $attempt/90)"
  sleep 10
done

CORE_IP=$(getent hosts "$SEED_HOST" | awk '{print $1}' | head -1)
if [[ -z "$CORE_IP" ]] || ! { nc -z "$CORE_IP" 5369 2>/dev/null || nc -z "$CORE_IP" 4370 2>/dev/null; }; then
  fail "Timed out waiting for core $SEED_HOST"
fi

install -d "$SYSTEMD_DROPIN"
cat > "$EMQX_ENV_FILE" <<EOF
EMQX_NODE__NAME="emqx@$PRIVATE_IP"
EMQX_NODE__COOKIE="${node_cookie}"
EMQX_CLUSTER__DISCOVERY_STRATEGY=static
EMQX_CLUSTER__STATIC__SEEDS=${seed_nodes}
EMQX_DASHBOARD__DEFAULT_USERNAME="${dashboard_username}"
EMQX_DASHBOARD__DEFAULT_PASSWORD="${dashboard_password}"
EMQX_LISTENERS__TCP__DEFAULT__BIND=0.0.0.0:1883
EMQX_LISTENERS__TCP__DEFAULT__ENABLE_AUTHN=false
EMQX_MQTT__MAX_PACKET_SIZE=1MB
EOF

append_emqx_performance_env "replicant" >> "$EMQX_ENV_FILE"

cat > "$SYSTEMD_DROPIN/terraform.conf" <<'EOF'
[Service]
EnvironmentFile=-/etc/emqx/terraform.env
EOF

chmod 600 "$EMQX_ENV_FILE"
systemctl daemon-reload
systemctl enable emqx
systemctl restart emqx

for attempt in $(seq 1 60); do
  if ss -tln | grep -q ':1883'; then
    log "MQTT listener up"
    break
  fi
  sleep 10
done

for attempt in $(seq 1 36); do
  STATUS=$(/usr/bin/emqx ctl cluster status 2>&1 || true)
  NODE_COUNT=$(grep -oE 'emqx@[0-9a-zA-Z._:-]+' <<< "$STATUS" | sort -u | wc -l)
  if [[ "$NODE_COUNT" -ge 2 ]] && grep -qF "emqx@$PRIVATE_IP" <<< "$STATUS"; then
    log "Joined cluster ($NODE_COUNT nodes)"
    date -Is > "$OK_MARKER"
    exit 0
  fi
  log "Waiting for cluster join (nodes=$NODE_COUNT, attempt $attempt/36)"
  sleep 10
done

fail "Replicant did not join cluster"
