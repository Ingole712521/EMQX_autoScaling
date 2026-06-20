#!/usr/bin/env python3
"""MQTT message durability validator — tracks sent vs received sequence numbers."""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time

import paho.mqtt.client as mqtt


class Stats:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.sent = 0
        self.received: set[int] = set()
        self.duplicates = 0

    def record_sent(self, seq: int) -> None:
        with self.lock:
            self.sent = max(self.sent, seq + 1)

    def record_received(self, seq: int) -> None:
        with self.lock:
            if seq in self.received:
                self.duplicates += 1
            else:
                self.received.add(seq)

    def report(self) -> dict[str, int]:
        with self.lock:
            if not self.received:
                return {
                    "sent": self.sent,
                    "received_unique": 0,
                    "lost": self.sent,
                    "duplicates": 0,
                }
            max_seq = max(self.received)
            expected = set(range(max_seq + 1))
            lost = len(expected - self.received)
            return {
                "sent": self.sent,
                "received_unique": len(self.received),
                "lost": lost,
                "duplicates": self.duplicates,
                "max_seq": max_seq,
            }


stats = Stats()


def connack_ok(reason_code: object) -> bool:
    if reason_code is None:
        return False
    return getattr(reason_code, "value", reason_code) == 0


def run_subscriber(args: argparse.Namespace) -> None:
    ready = threading.Event()

    def on_connect(client, _userdata, _flags, reason_code, _props) -> None:
        if connack_ok(reason_code):
            client.subscribe(args.topic, qos=args.qos)
        ready.set()

    def on_message(_client, _userdata, msg) -> None:
        try:
            stats.record_received(int(msg.payload.decode()))
        except ValueError:
            pass

    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=args.sub_client_id,
        protocol=mqtt.MQTTv311,
        clean_session=args.clean_session,
    )
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(args.host, args.port, 60)
    client.loop_start()
    ready.wait(30)
    while True:
        time.sleep(10)
        print(json.dumps(stats.report()), flush=True)


def run_publisher(args: argparse.Namespace) -> dict[str, int]:
    ready = threading.Event()
    rc_box: list[object] = [None]

    def on_connect(_client, _userdata, _flags, reason_code, _props) -> None:
        rc_box[0] = reason_code
        ready.set()

    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=args.pub_client_id,
        protocol=mqtt.MQTTv311,
    )
    client.on_connect = on_connect
    client.connect(args.host, args.port, 60)
    client.loop_start()
    if not ready.wait(30) or not connack_ok(rc_box[0]):
        raise RuntimeError(f"Publisher connect failed: {rc_box[0]}")

    interval = 1.0 / args.rate if args.rate > 0 else 0
    for seq in range(args.count):
        client.publish(args.topic, str(seq), qos=args.qos)
        stats.record_sent(seq)
        if seq and seq % 10000 == 0:
            print(f"[pub] seq={seq} {json.dumps(stats.report())}", flush=True)
        if interval:
            time.sleep(interval)

    time.sleep(5)
    client.loop_stop()
    client.disconnect()
    return stats.report()


def main() -> int:
    parser = argparse.ArgumentParser(description="EMQX message durability test")
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--topic", default="test/durability/seq")
    parser.add_argument("--qos", type=int, default=1, choices=[1, 2])
    parser.add_argument("--count", type=int, default=1_000_000)
    parser.add_argument("--rate", type=int, default=5000, help="messages per second")
    parser.add_argument("--mode", choices=["pub", "sub", "both"], default="both")
    parser.add_argument("--pub-client-id", default="durability-pub-01")
    parser.add_argument("--sub-client-id", default="durability-sub-01")
    parser.add_argument("--clean-session", action="store_true", help="Use clean session on subscriber")
    args = parser.parse_args()

    if args.mode in ("sub", "both"):
        thread = threading.Thread(target=run_subscriber, args=(args,), daemon=True)
        thread.start()
        time.sleep(2)

    if args.mode == "sub":
        while True:
            time.sleep(60)

    result = run_publisher(args)
    if args.mode == "both":
        time.sleep(10)
        result = stats.report()

    print("\n=== FINAL RESULT ===")
    print(json.dumps(result, indent=2))

    passed = result["lost"] == 0 and result["received_unique"] >= result["sent"]
    if args.qos == 2 and result.get("duplicates", 0) > 0:
        passed = False
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
