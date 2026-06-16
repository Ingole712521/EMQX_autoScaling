#!/usr/bin/env bash
# Ensure project .venv exists (all platforms). Prints python path to stdout.
set -euo pipefail

_ensure_venv_root="${1:?project root required}"
cd "${_ensure_venv_root}"

_venv_unix="${_ensure_venv_root}/.venv/bin/python"
_venv_win="${_ensure_venv_root}/.venv/Scripts/python.exe"

if [[ -x "${_venv_unix}" ]]; then
  echo "${_venv_unix}"
  exit 0
fi

if [[ -x "${_venv_win}" ]]; then
  echo "${_venv_win}"
  exit 0
fi

_base_python=""
if command -v python3 >/dev/null 2>&1; then
  _base_python="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  _base_python="$(command -v python)"
elif command -v py >/dev/null 2>&1; then
  _base_python="$(py -3 -c "import sys; print(sys.executable)" 2>/dev/null || true)"
fi

if [[ -z "${_base_python}" ]] || ! "${_base_python}" -c "import sys; assert sys.version_info[0] == 3" >/dev/null 2>&1; then
  echo "Python 3 is required." >&2
  echo "  macOS:   brew install python" >&2
  echo "  Windows: winget install Python.Python.3" >&2
  echo "  Linux:   sudo apt install python3 python3-venv   # Ubuntu/Debian" >&2
  echo "           sudo dnf install python3 python3-pip    # Amazon Linux 2023" >&2
  exit 1
fi

echo "Creating Python virtual environment at .venv..." >&2
"${_base_python}" -m venv "${_ensure_venv_root}/.venv"

if [[ -x "${_venv_unix}" ]]; then
  echo "${_venv_unix}"
elif [[ -x "${_venv_win}" ]]; then
  echo "${_venv_win}"
else
  echo "Failed to create .venv" >&2
  exit 1
fi
