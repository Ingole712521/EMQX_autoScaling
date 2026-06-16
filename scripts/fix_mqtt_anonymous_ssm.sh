#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/lib/common.sh"

emqx_run_pwsh "${ROOT}/scripts/fix_mqtt_anonymous_ssm.ps1" "$@"
