#!/usr/bin/env python3
"""Orchestrated ~2000-connection demo: scale ASG first, then conn-only hold for dashboard."""

from __future__ import annotations

import argparse
import os
import signal
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from staged_load import (
    log_asg_capacity,
    probe_broker,
    run_until_stopped,
    wait_asg_min_capacity,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="2K MQTT connection demo for EMQX dashboard + ASG")
    parser.add_argument("--host", default=os.environ.get("MQTT_HOST", ""))
    parser.add_argument("--port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")))
    parser.add_argument("--asg-name", default=os.environ.get("ASG_NAME", ""))
    parser.add_argument("--aws-region", default=os.environ.get("AWS_REGION", "ap-south-1"))
    parser.add_argument("--target-clients", type=int, default=int(os.environ.get("TARGET_CLIENTS", "2000")))
    parser.add_argument("--warmup-clients", type=int, default=int(os.environ.get("WARMUP_CLIENTS", "400")))
    parser.add_argument("--min-asg", type=int, default=int(os.environ.get("MIN_ASG_CAPACITY", "2")))
    parser.add_argument("--warmup-sec", type=int, default=int(os.environ.get("WARMUP_SEC", "300")))
    parser.add_argument("--hold-sec", type=int, default=int(os.environ.get("HOLD_SEC", "600")))
    parser.add_argument("--connect-stagger", type=float, default=float(os.environ.get("CONNECT_STAGGER_SEC", "0.2")))
    parser.add_argument("--connect-timeout", type=float, default=float(os.environ.get("MQTT_CONNECT_TIMEOUT", "60")))
    args = parser.parse_args()

    if not args.host:
        print("Error: --host or MQTT_HOST required", file=sys.stderr)
        return 1

    stop = threading.Event()

    def on_sig(_a, _b) -> None:
        stop.set()
        print("\nCtrl+C — stopping...")

    signal.signal(signal.SIGINT, on_sig)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, on_sig)

    print("=" * 60)
    print(" EMQX 2K connection demo")
    print("=" * 60)
    print(f"Target NLB:     {args.host}:{args.port}")
    print(f"Goal:           {args.target_clients} connections visible in dashboard")
    print(f"Warmup:         {args.warmup_clients} clients x {args.warmup_sec}s (trigger ASG)")
    print(f"Min ASG size:   {args.min_asg} replicants before 2K ramp")
    print(f"2K ramp:        {args.connect_stagger}s stagger (~{int(args.target_clients * args.connect_stagger)}s)")
    print(f"Dashboard hold: {args.hold_sec}s conn-only after ramp")
    print("=" * 60)

    if args.asg_name:
        log_asg_capacity(args.asg_name, args.aws_region, "start")

    if not probe_broker(args.host, args.port, "loadtest/2k", args.connect_timeout):
        return 1

    # Phase 1 — warm traffic to trigger scale-out
    print("\n[Phase 1/3] Warmup load (publish) to trigger autoscaling...")
    ok = run_until_stopped(
        args.host,
        args.port,
        args.warmup_clients,
        "warmup",
        "loadtest/warmup",
        publish_interval_sec=0.05,
        payload_size=2048,
        messages_per_burst=2,
        connect_timeout_sec=args.connect_timeout,
        connect_stagger_sec=0.1,
        global_stop=stop,
        asg_name=args.asg_name,
        aws_region=args.aws_region,
        conn_only=False,
        duration_sec=args.warmup_sec,
    )
    if stop.is_set():
        return 130
    print(f"[Phase 1/3] warmup done (ok={ok})")

    # Phase 2 — wait for ASG
    if args.asg_name:
        print("\n[Phase 2/3] Waiting for autoscaling...")
        if not wait_asg_min_capacity(args.asg_name, args.aws_region, args.min_asg, timeout_sec=900):
            print(
                "WARNING: ASG did not reach min capacity in time. Continuing anyway — "
                "2K may see CONNACK timeouts on t3.small with one replicant.",
                file=sys.stderr,
            )
        log_asg_capacity(args.asg_name, args.aws_region, "before 2K ramp")
        print("Pausing 45s so new NLB targets become healthy before fresh connections...")
        time.sleep(45)
    else:
        print("\n[Phase 2/3] ASG_NAME not set — skipping wait (set ASG_NAME for autoscaling demo)")
        time.sleep(15)

    if stop.is_set():
        return 130

    # Phase 3 — 2K conn-only hold for dashboard
    print("\n[Phase 3/3] Ramping to 2000 conn-only clients — open EMQX dashboard Nodes tab now")
    ok = run_until_stopped(
        args.host,
        args.port,
        args.target_clients,
        "2k-hold",
        "loadtest/2k",
        publish_interval_sec=1.0,
        payload_size=64,
        messages_per_burst=0,
        connect_timeout_sec=args.connect_timeout,
        connect_stagger_sec=args.connect_stagger,
        global_stop=stop,
        asg_name=args.asg_name,
        aws_region=args.aws_region,
        conn_only=True,
        duration_sec=args.hold_sec,
    )

    if args.asg_name:
        log_asg_capacity(args.asg_name, args.aws_region, "after 2K demo")

    print("\n" + "=" * 60)
    if ok:
        print(" 2K DEMO COMPLETE — check dashboard total connections ~2000")
    else:
        print(" 2K DEMO FINISHED WITH ERRORS — reduce TARGET_CLIENTS or resize instances")
    print("=" * 60)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
