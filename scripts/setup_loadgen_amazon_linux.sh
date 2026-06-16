#!/usr/bin/env bash
# One-time setup on Amazon Linux 2/2023 (or Ubuntu) load-generator EC2.
set -euo pipefail

echo "=== EMQX load-generator setup ==="

if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
fi

install_amazon_linux_2023() {
  sudo dnf install -y python3 python3-pip git awscli
}

install_amazon_linux_2() {
  sudo yum install -y python3 python3-pip git awscli
}

install_ubuntu() {
  sudo apt-get update -qq
  sudo apt-get install -y python3 python3-venv python3-pip git awscli
}

case "${ID:-unknown}" in
  amzn)
    if [[ "${VERSION_ID:-}" == "2" ]]; then
      install_amazon_linux_2
    else
      install_amazon_linux_2023
    fi
    ;;
  ubuntu|debian)
    install_ubuntu
    ;;
  *)
    echo "Unsupported OS: ${PRETTY_NAME:-unknown}" >&2
    echo "Install manually: python3, python3-pip, git, awscli" >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ ! -f "${ROOT}/loadtest/requirements.txt" ]]; then
  echo "Run from project root (folder with loadtest/requirements.txt)." >&2
  echo "Example: cd /path/to/emqx && bash ./scripts/setup_loadgen_amazon_linux.sh" >&2
  exit 1
fi

# Git clone on Windows often drops +x on lib/*.sh
chmod +x "${ROOT}/scripts/lib/"*.sh "${ROOT}/scripts/"*.sh 2>/dev/null || true

PYTHON="$(bash "${ROOT}/scripts/lib/ensure_venv.sh" "${ROOT}")"
"${PYTHON}" -m pip install -q --upgrade pip
"${PYTHON}" -m pip install -q -r loadtest/requirements.txt

echo ""
echo "Setup OK. Python: ${PYTHON}"
echo ""
echo "Next (set targets from your PC — run: bash ./scripts/print_load_test_env.sh):"
echo "  export MQTT_HOST=<nlb-dns-from-terraform>"
echo "  export ASG_NAME=emqx-prod-replicants-asg"
echo "  export AWS_REGION=ap-south-1"
echo ""
echo "  bash ./scripts/run_load_test_on_ec2.sh probe"
echo "  bash ./scripts/run_load_test_on_ec2.sh staged"
echo "  bash ./scripts/run_2k_load_test.sh                         # full 2K dashboard demo"
echo "  bash ./scripts/run_load_test_on_ec2.sh 2k                # same (alias)"
echo "  CLIENTS=100 bash ./scripts/run_load_test_on_ec2.sh sustained"
