#!/usr/bin/env bash
# Shared helpers for Bash wrappers (Git Bash, macOS, Linux, WSL).
set -euo pipefail

emqx_project_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

emqx_run_pwsh() {
  local script="$1"
  shift

  if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoProfile -File "$script" "$@"
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script" "$@"
  fi

  echo "PowerShell (pwsh) is required." >&2
  echo "  macOS:   brew install powershell" >&2
  echo "  Windows: winget install Microsoft.PowerShell" >&2
  echo "  Linux:   https://aka.ms/powershell" >&2
  return 1
}

emqx_terraform_output() {
  local name="$1"
  local dir="${2:-.}"
  terraform -chdir="${dir}" output -raw "${name}" 2>/dev/null
}

emqx_from_terraform_host() {
  local dir="${1:-.}"
  local name host

  for name in mqtt_nlb_dns_name nlb_dns_name; do
    if host="$(emqx_terraform_output "${name}" "${dir}")"; then
      printf '%s' "${host}"
      return 0
    fi
  done

  return 1
}
