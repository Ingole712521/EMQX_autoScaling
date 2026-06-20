#!/usr/bin/env python3
"""Orchestrated MQTT connection demo: scale ASG first, then hold with light traffic for dashboard."""

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
    resolve_min_asg_for_load,
    run_until_stopped,
    wait_asg_min_capacity,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="2K MQTT connection demo for EMQX dashboard + ASG")
    parser.add_argument("--host", default=os.environ.get("MQTT_HOST", ""))
    parser.add_argument("--port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")))
    parser.add_argument("--asg-name", default=os.environ.get("ASG_NAME", ""))
    parser.add_argument("--aws-region", default=os.environ.get("AWS_REGION", "ap-south-1"))
    parser.add_argument("--target-clients", type=int, default=int(os.environ.get("TARGET_CLIENTS", "10000")))
    parser.add_argument("--warmup-clients", type=int, default=int(os.environ.get("WARMUP_CLIENTS", "400")))
    parser.add_argument(
        "--min-asg",
        type=int,
        default=int(os.environ["MIN_ASG_CAPACITY"]) if os.environ.get("MIN_ASG_CAPACITY") else None,
        help="Fixed ASG wait target; default is computed from --target-clients",
    )
    parser.add_argument(
        "--clients-per-replicant",
        type=int,
        default=int(os.environ.get("CLIENTS_PER_REPLICANT", "2000")),
        help="Connections per replicant when auto-computing --min-asg",
    )
    parser.add_argument("--warmup-sec", type=int, default=int(os.environ.get("WARMUP_SEC", "300")))
    parser.add_argument("--hold-sec", type=int, default=int(os.environ.get("HOLD_SEC", "600")))
    parser.add_argument("--connect-stagger", type=float, default=float(os.environ.get("CONNECT_STAGGER_SEC", "0.2")))
    parser.add_argument("--connect-timeout", type=float, default=float(os.environ.get("MQTT_CONNECT_TIMEOUT", "60")))
    parser.add_argument(
        "--hold-publish-interval",
        type=float,
        default=float(os.environ.get("HOLD_PUBLISH_INTERVAL_SEC", "30")),
        help="Seconds between keepalive publishes per client in phase 3",
    )
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
    print(" EMQX connection load demo")
    print("=" * 60)
    print(f"Target NLB:     {args.host}:{args.port}")
    print(f"Goal:           {args.target_clients} connections visible in dashboard")
    print(f"Warmup:         {args.warmup_clients} clients x {args.warmup_sec}s (trigger ASG)")
    min_asg = resolve_min_asg_for_load(
        args.target_clients,
        args.clients_per_replicant,
        args.min_asg,
        args.asg_name,
        args.aws_region,
    )
    print(f"ASG wait target: {min_asg} replicants before connection ramp (load-based unless MIN_ASG_CAPACITY set)")
    print(f"Connection ramp: {args.connect_stagger}s stagger (~{int(args.target_clients * args.connect_stagger)}s)")
    print(
        f"Dashboard hold: {args.hold_sec}s with keepalive publish every "
        f"{args.hold_publish_interval}s/client (connections + message traffic)"
    )
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
        if not wait_asg_min_capacity(args.asg_name, args.aws_region, min_asg, timeout_sec=900):
            print(
                "WARNING: ASG did not reach min capacity in time. Continuing anyway — "
                "connection ramp may see CONNACK timeouts if the cluster is undersized.",
                file=sys.stderr,
            )
        log_asg_capacity(args.asg_name, args.aws_region, "before connection ramp")
        print("Pausing 45s so new NLB targets become healthy before fresh connections...")
        time.sleep(45)
    else:
        print("\n[Phase 2/3] ASG_NAME not set — skipping wait (set ASG_NAME for autoscaling demo)")
        time.sleep(15)

    if stop.is_set():
        return 130

    # Phase 3 — ramp connections with keepalive publishes for dashboard + autoscaling
    print(
        f"\n[Phase 3/3] Ramping to {args.target_clients} clients (keepalive publish) — "
        "open EMQX dashboard Nodes tab now"
    )
    ok = run_until_stopped(
        args.host,
        args.port,
        args.target_clients,
        "hold",
        "loadtest/hold",
        publish_interval_sec=args.hold_publish_interval,
        payload_size=64,
        messages_per_burst=1,
        connect_timeout_sec=args.connect_timeout,
        connect_stagger_sec=args.connect_stagger,
        global_stop=stop,
        asg_name=args.asg_name,
        aws_region=args.aws_region,
        conn_only=False,
        duration_sec=args.hold_sec,
    )

    if args.asg_name:
        log_asg_capacity(args.asg_name, args.aws_region, "after connection demo")

    print("\n" + "=" * 60)
    if ok:
        print(f" DEMO COMPLETE — check dashboard total connections ~{args.target_clients}")
    else:
        print(" DEMO FINISHED WITH ERRORS — reduce TARGET_CLIENTS or resize instances")
    print("=" * 60)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
