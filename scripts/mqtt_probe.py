#!/usr/bin/env python3
"""Single-client MQTT probe against the NLB."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "loadtest"))

from staged_load import probe_broker  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="MQTT preflight probe via NLB")
    parser.add_argument("--host", default=os.environ.get("MQTT_HOST", ""))
    parser.add_argument("--port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")))
    parser.add_argument("--topic", default=os.environ.get("MQTT_TOPIC", "loadtest/probe"))
    args = parser.parse_args()

    if not args.host:
        print("Error: --host or MQTT_HOST required", file=sys.stderr)
        return 1

    print(f"Connecting to {args.host}:{args.port} ...")
    return 0 if probe_broker(args.host, args.port, args.topic, 15.0) else 1


if __name__ == "__main__":
    raise SystemExit(main())
