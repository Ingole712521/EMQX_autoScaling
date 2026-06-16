#!/usr/bin/env bash
# Message durability validation (sent/received/lost).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MQTT_HOST="${MQTT_HOST:-$(terraform output -raw mqtt_nlb_dns_name)}"
COUNT="${COUNT:-100000}"
RATE="${RATE:-2000}"
QOS="${QOS:-1}"
MODE="${MODE:-both}"

python3 -m pip install -q -r loadtest/requirements.txt
python3 loadtest/durability_test.py \
  --host "$MQTT_HOST" \
  --count "$COUNT" \
  --rate "$RATE" \
  --qos "$QOS" \
  --mode "$MODE"
