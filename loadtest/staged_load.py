#!/usr/bin/env python3
"""Staged MQTT load test via NLB — waits for CONNACK, reports errors, stops on failure."""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass

import paho.mqtt.client as mqtt

from mqtt_common import connack_ok


@dataclass(frozen=True)
class Stage:
    clients: int
    duration_sec: int
    label: str


DEFAULT_STAGES = [
    Stage(40, 180, "baseline-heavy"),
    Stage(80, 300, "scale-out-2"),
    Stage(120, 300, "scale-out-3"),
    Stage(10, 90, "scale-in"),
]

DEFAULT_PUBLISH_INTERVAL = 0.001
DEFAULT_PAYLOAD_SIZE = 16384
DEFAULT_MESSAGES_PER_BURST = 10
DEFAULT_CONNECT_STAGGER_SEC = float(os.environ.get("CONNECT_STAGGER_SEC", "0.05"))
DEFAULT_LOAD_STAGES = ",".join(
    f"{s.clients}:{s.duration_sec}:{s.label}" for s in DEFAULT_STAGES
)


class LoadClient(threading.Thread):
    def __init__(
        self,
        host: str,
        port: int,
        client_id: str,
        topic: str,
        publish_interval_sec: float,
        payload_size: int,
        messages_per_burst: int,
        stop_event: threading.Event,
        connect_timeout_sec: float,
        error_samples: list[str],
        error_lock: threading.Lock,
        conn_only: bool = False,
    ) -> None:
        super().__init__(daemon=True)
        self.host = host
        self.port = port
        self.client_id = client_id
        self.topic = topic
        self.publish_interval_sec = publish_interval_sec
        self.payload = "X" * payload_size
        self.messages_per_burst = messages_per_burst
        self.stop_event = stop_event
        self.connect_timeout_sec = connect_timeout_sec
        self.error_samples = error_samples
        self.error_lock = error_lock
        self.conn_only = conn_only
        self.published = 0
        self.errors = 0
        self.connected = False

    def _fail(self, message: str) -> None:
        self.errors += 1
        with self.error_lock:
            if len(self.error_samples) < 8:
                self.error_samples.append(f"{self.client_id}: {message}")

    def run(self) -> None:
        ready = threading.Event()
        conn_rc: list[object] = [None]

        def on_connect(_c, _u, _f, reason_code, _p) -> None:
            conn_rc[0] = reason_code
            ready.set()

        client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=self.client_id,
            protocol=mqtt.MQTTv311,
        )
        client.on_connect = on_connect

        try:
            time.sleep(random.uniform(0, 0.3))
            client.connect(self.host, self.port, keepalive=60)
            client.loop_start()

            if not ready.wait(timeout=self.connect_timeout_sec):
                self._fail("CONNACK timeout")
                return
            if not connack_ok(conn_rc[0]):
                self._fail(f"CONNACK rejected ({conn_rc[0]})")
                return

            self.connected = True

            if self.conn_only:
                while not self.stop_event.is_set():
                    self.stop_event.wait(timeout=30.0)
                return

            seq = 0
            while not self.stop_event.is_set():
                for _ in range(self.messages_per_burst):
                    payload = json.dumps(
                        {
                            "client": self.client_id,
                            "seq": seq,
                            "ts": time.time(),
                            "payload": self.payload,
                        }
                    )
                    info = client.publish(self.topic, payload, qos=0)
                    if info.rc != mqtt.MQTT_ERR_SUCCESS:
                        self._fail(f"publish rc={info.rc}")
                        return
                    self.published += 1
                    seq += 1
                time.sleep(self.publish_interval_sec)
        except Exception as exc:
            self._fail(str(exc))
        finally:
            try:
                client.loop_stop()
                client.disconnect()
            except Exception:
                pass


def probe_broker(host: str, port: int, topic: str, timeout_sec: float) -> bool:
    ready = threading.Event()
    state = {"rc": None}

    def on_connect(_c, _u, _f, rc, _p) -> None:
        state["rc"] = rc
        ready.set()

    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"preflight-{int(time.time())}",
        protocol=mqtt.MQTTv311,
    )
    client.on_connect = on_connect
    try:
        client.connect(host, port, keepalive=30)
        client.loop_start()
        if not ready.wait(timeout=timeout_sec):
            print(f"Preflight FAIL: no CONNACK within {timeout_sec}s")
            return False
        if not connack_ok(state["rc"]):
            print(f"Preflight FAIL: CONNACK={state['rc']}")
            return False
        info = client.publish(topic, '{"preflight":true}', qos=0)
        time.sleep(0.5)
        if info.rc != mqtt.MQTT_ERR_SUCCESS:
            print(f"Preflight FAIL: publish rc={info.rc}")
            return False
        print(f"Preflight OK: {host}:{port}")
        return True
    except Exception as exc:
        print(f"Preflight FAIL: {exc}")
        return False
    finally:
        try:
            client.loop_stop()
            client.disconnect()
        except Exception:
            pass


def asg_desired_capacity(asg_name: str, region: str) -> int | None:
    if not asg_name:
        return None
    try:
        out = subprocess.check_output(
            [
                "aws", "autoscaling", "describe-auto-scaling-groups",
                "--region", region,
                "--auto-scaling-group-names", asg_name,
                "--query", "AutoScalingGroups[0].DesiredCapacity",
                "--output", "text",
            ],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
        ).strip()
        return int(out) if out and out != "None" else None
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        return None


def log_asg_capacity(asg_name: str, region: str, label: str) -> None:
    cap = asg_desired_capacity(asg_name, region)
    if cap is not None:
        print(f"  ASG {asg_name} desired_capacity={cap} ({label})")


def wait_asg_min_capacity(
    asg_name: str,
    region: str,
    min_capacity: int,
    timeout_sec: int = 900,
    poll_sec: int = 30,
) -> bool:
    if not asg_name:
        return False
    deadline = time.time() + timeout_sec
    print(f"Waiting for ASG {asg_name} desired_capacity >= {min_capacity} (timeout {timeout_sec}s)...")
    while time.time() < deadline:
        cap = asg_desired_capacity(asg_name, region)
        if cap is not None:
            print(f"  ASG desired_capacity={cap}")
            if cap >= min_capacity:
                return True
        time.sleep(poll_sec)
    return False


def run_until_stopped(
    host: str,
    port: int,
    clients: int,
    label: str,
    topic: str,
    publish_interval_sec: float,
    payload_size: int,
    messages_per_burst: int,
    connect_timeout_sec: float,
    connect_stagger_sec: float,
    global_stop: threading.Event,
    asg_name: str = "",
    aws_region: str = "ap-south-1",
    conn_only: bool = False,
    duration_sec: int = 0,
) -> bool:
    """Run N MQTT clients until Ctrl+C, duration_sec, or global_stop."""
    stop_event = threading.Event()
    threads: list[LoadClient] = []
    error_samples: list[str] = []
    error_lock = threading.Lock()

    mode = "conn-only (dashboard hold)" if conn_only else "publish load"
    print(f"\n[sustained] {label}: {clients} clients — {mode}")
    print(f"  Connect stagger: {connect_stagger_sec}s between clients (~{int(clients * connect_stagger_sec)}s ramp)")
    if duration_sec > 0:
        print(f"  Hold duration: {duration_sec}s (refresh EMQX dashboard during this window)")
    else:
        print("  Press Ctrl+C to stop.")
    print("  Watch ASG + EMQX dashboard Nodes tab while this runs.")

    for i in range(clients):
        if global_stop.is_set():
            break
        worker = LoadClient(
            host=host,
            port=port,
            client_id=f"load-{label}-{i}",
            topic=topic,
            publish_interval_sec=publish_interval_sec,
            payload_size=payload_size,
            messages_per_burst=messages_per_burst,
            stop_event=stop_event,
            connect_timeout_sec=connect_timeout_sec,
            error_samples=error_samples,
            error_lock=error_lock,
            conn_only=conn_only,
        )
        threads.append(worker)
        worker.start()
        time.sleep(connect_stagger_sec)

    started = time.time()
    end_at = started + duration_sec if duration_sec > 0 else None
    while not global_stop.is_set():
        if end_at is not None and time.time() >= end_at:
            print(f"\nHold complete ({duration_sec}s) — disconnecting clients...")
            break
        time.sleep(10)
        published = sum(t.published for t in threads)
        errors = sum(t.errors for t in threads)
        connected = sum(1 for t in threads if t.connected)
        elapsed = int(time.time() - started)
        line = (
            f"  elapsed={elapsed}s connected={connected}/{len(threads)} "
            f"errors={errors} published={published}"
        )
        if asg_name:
            cap = asg_desired_capacity(asg_name, aws_region)
            if cap is not None:
                line += f" asg_desired={cap}"
        print(line)
        if conn_only and connected >= clients * 9 // 10 and connected > 0:
            print(f"  >> Dashboard should show ~{connected} connections across replicant nodes")
        if errors and error_samples:
            for sample in error_samples[:3]:
                print(f"    sample: {sample}")

    print("\nStopping clients...")
    stop_event.set()
    for t in threads:
        t.join(timeout=5)

    published = sum(t.published for t in threads)
    errors = sum(t.errors for t in threads)
    connected = sum(1 for t in threads if t.connected)
    print(f"[sustained] stopped connected={connected}/{len(threads)} published={published} errors={errors}")
    if conn_only:
        return connected >= clients * 8 // 10
    return published > 0 and errors == 0


def run_stage(
    host: str,
    port: int,
    stage: Stage,
    topic: str,
    publish_interval_sec: float,
    payload_size: int,
    messages_per_burst: int,
    stage_index: int,
    connect_timeout_sec: float,
    connect_stagger_sec: float = DEFAULT_CONNECT_STAGGER_SEC,
) -> bool:
    stop_event = threading.Event()
    threads: list[LoadClient] = []
    error_samples: list[str] = []
    error_lock = threading.Lock()

    print(
        f"\n[stage {stage_index}] {stage.label}: "
        f"{stage.clients} clients x {stage.duration_sec}s"
    )

    for i in range(stage.clients):
        worker = LoadClient(
            host=host,
            port=port,
            client_id=f"load-{stage.label}-{i}",
            topic=topic,
            publish_interval_sec=publish_interval_sec,
            payload_size=payload_size,
            messages_per_burst=messages_per_burst,
            stop_event=stop_event,
            connect_timeout_sec=connect_timeout_sec,
            error_samples=error_samples,
            error_lock=error_lock,
        )
        threads.append(worker)
        worker.start()
        time.sleep(connect_stagger_sec)

    deadline = time.time() + stage.duration_sec
    while time.time() < deadline:
        time.sleep(10)
        published = sum(t.published for t in threads)
        errors = sum(t.errors for t in threads)
        print(
            f"  published={published} errors={errors} "
            f"remaining={int(deadline - time.time())}s"
        )
        if errors and error_samples:
            for line in error_samples[:3]:
                print(f"    sample: {line}")

    stop_event.set()
    for t in threads:
        t.join(timeout=5)

    published = sum(t.published for t in threads)
    errors = sum(t.errors for t in threads)
    print(f"[stage {stage_index}] done published={published} errors={errors}")
    return published > 0 and errors == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.environ.get("MQTT_HOST", ""))
    parser.add_argument("--port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")))
    parser.add_argument("--topic", default=os.environ.get("MQTT_TOPIC", "loadtest/staged"))
    parser.add_argument("--publish-interval", type=float, default=float(os.environ.get("PUBLISH_INTERVAL", "0.001")))
    parser.add_argument("--payload-size", type=int, default=int(os.environ.get("PAYLOAD_SIZE", "16384")))
    parser.add_argument("--messages-per-burst", type=int, default=int(os.environ.get("MESSAGES_PER_BURST", "10")))
    parser.add_argument("--stages", default=os.environ.get("LOAD_STAGES", DEFAULT_LOAD_STAGES))
    parser.add_argument("--skip-preflight", action="store_true")
    parser.add_argument("--connect-timeout", type=float, default=float(os.environ.get("MQTT_CONNECT_TIMEOUT", "20")))
    parser.add_argument(
        "--connect-stagger",
        type=float,
        default=float(os.environ.get("CONNECT_STAGGER_SEC", str(DEFAULT_CONNECT_STAGGER_SEC))),
        help="Seconds between starting each client (avoid connection storms)",
    )
    parser.add_argument("--asg-name", default=os.environ.get("ASG_NAME", ""))
    parser.add_argument("--aws-region", default=os.environ.get("AWS_REGION", "ap-south-1"))
    parser.add_argument(
        "--sustained",
        action="store_true",
        help="Run until Ctrl+C (use with --clients)",
    )
    parser.add_argument(
        "--clients",
        type=int,
        default=int(os.environ.get("LOAD_CLIENTS", os.environ.get("CLIENTS", "100"))),
        help="Number of MQTT clients for --sustained mode (default 100)",
    )
    parser.add_argument(
        "--conn-only",
        action="store_true",
        default=os.environ.get("CONN_ONLY", "").lower() in ("1", "true", "yes"),
        help="Hold connections open without publish load (best for dashboard connection count)",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=int(os.environ.get("LOAD_DURATION_SEC", "0")),
        help="Auto-stop after N seconds (0 = until Ctrl+C)",
    )
    args = parser.parse_args()

    if not args.host:
        print("Error: --host or MQTT_HOST required", file=sys.stderr)
        return 1

    print(f"Target NLB: {args.host}:{args.port}")
    if args.asg_name:
        log_asg_capacity(args.asg_name, args.aws_region, "before load test")
    if not args.skip_preflight and not probe_broker(args.host, args.port, args.topic, args.connect_timeout):
        return 1

    stop = threading.Event()

    def on_sig(_a, _b) -> None:
        stop.set()
        print("\nCtrl+C received — stopping load test...")

    signal.signal(signal.SIGINT, on_sig)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, on_sig)

    if args.sustained:
        ok = run_until_stopped(
            args.host,
            args.port,
            args.clients,
            "sustained-100",
            args.topic,
            args.publish_interval,
            args.payload_size,
            args.messages_per_burst,
            args.connect_timeout,
            args.connect_stagger,
            stop,
            asg_name=args.asg_name,
            aws_region=args.aws_region,
            conn_only=args.conn_only,
            duration_sec=args.duration,
        )
        if args.asg_name:
            log_asg_capacity(args.asg_name, args.aws_region, "after sustained load")
        print("\nSustained load test finished." if ok else "\nSustained load test ended with errors.")
        return 0 if ok else 1

    stages = parse_stages(args.stages)
    if not stages:
        return 1

    for idx, stage in enumerate(stages, 1):
        if stop.is_set():
            break
        if not run_stage(
            args.host,
            args.port,
            stage,
            args.topic,
            args.publish_interval,
            args.payload_size,
            args.messages_per_burst,
            idx,
            args.connect_timeout,
            args.connect_stagger,
        ):
            print("Stage failed — fix broker/NLB before continuing.")
            return 1
        if args.asg_name:
            log_asg_capacity(args.asg_name, args.aws_region, f"after {stage.label}")

    print("\nLoad test finished successfully.")
    if args.asg_name:
        log_asg_capacity(args.asg_name, args.aws_region, "final")
    return 0


def parse_stages(raw: str) -> list[Stage]:
    stages: list[Stage] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        clients_str, duration_str, *label_parts = part.split(":")
        label = label_parts[0] if label_parts else "stage"
        stages.append(Stage(int(clients_str), int(duration_str), label))
    return stages


if __name__ == "__main__":
    raise SystemExit(main())
