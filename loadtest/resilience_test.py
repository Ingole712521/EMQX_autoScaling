#!/usr/bin/env python3
"""
Cluster resilience validation orchestrator.
Runs controlled failure scenarios and records cluster/MQTT health.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field

import paho.mqtt.client as mqtt
import requests


@dataclass
class Check:
    name: str
    passed: bool
    detail: str


@dataclass
class Report:
    checks: list[Check] = field(default_factory=list)

    def add(self, name: str, passed: bool, detail: str) -> None:
        self.checks.append(Check(name, passed, detail))
        tag = "PASS" if passed else "FAIL"
        print(f"[{tag}] {name}")
        for line in detail.splitlines():
            print(f"      {line}")

    def ok(self) -> bool:
        return all(c.passed for c in self.checks)


def aws_json(cmd: list[str]) -> dict | list | None:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, timeout=120)
        return json.loads(out) if out.strip() else None
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError) as exc:
        return {"error": str(exc)}


def emqx_token(core_ip: str, user: str, password: str) -> str | None:
    try:
        r = requests.post(
            f"http://{core_ip}:18083/api/v5/login",
            json={"username": user, "password": password},
            timeout=15,
        )
        if r.status_code == 200:
            return r.json().get("token")
    except requests.RequestException:
        pass
    return None


def client_count(core_ip: str, token: str) -> int | None:
    try:
        r = requests.get(
            f"http://{core_ip}:18083/api/v5/clients",
            headers={"Authorization": f"Bearer {token}"},
            params={"limit": 1, "page": 1},
            timeout=15,
        )
        r.raise_for_status()
        meta = r.json().get("meta") or {}
        if "count" in meta:
            return int(meta["count"])
    except (requests.RequestException, TypeError, ValueError):
        pass
    return None


def cluster_status_ssm(region: str, instance_id: str) -> str:
    data = aws_json(
        [
            "aws", "ssm", "send-command",
            "--region", region,
            "--instance-ids", instance_id,
            "--document-name", "AWS-RunShellScript",
            "--parameters", json.dumps({"commands": ["emqx ctl cluster status"]}),
            "--output", "json",
        ]
    )
    if not isinstance(data, dict):
        return "SSM command failed"
    cmd_id = data.get("Command", {}).get("CommandId")
    if not cmd_id:
        return "No command id"
    for _ in range(30):
        time.sleep(2)
        inv = aws_json(
            [
                "aws", "ssm", "get-command-invocation",
                "--region", region,
                "--command-id", cmd_id,
                "--instance-id", instance_id,
                "--output", "json",
            ]
        )
        if isinstance(inv, dict) and inv.get("Status") in ("Success", "Failed"):
            return inv.get("StandardOutputContent", "") or inv.get("StatusDetails", "")
    return "SSM timeout"


def mqtt_holders(host: str, port: int, count: int, topic: str) -> tuple[threading.Event, list[threading.Thread]]:
    stop = threading.Event()
    threads: list[threading.Thread] = []

    def worker(i: int) -> None:
        ready = threading.Event()
        rc_box: list[object] = [None]

        def on_connect(_c, _u, _f, rc, _p) -> None:
            rc_box[0] = rc
            ready.set()

        c = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"resilience-{i}-{int(time.time())}",
            protocol=mqtt.MQTTv311,
        )
        c.on_connect = on_connect
        try:
            c.connect(host, port, 60)
            c.loop_start()
            if not ready.wait(20):
                return
            while not stop.is_set():
                c.publish(topic, json.dumps({"i": i}), qos=1)
                time.sleep(0.5)
        except Exception:
            pass
        finally:
            try:
                c.loop_stop()
                c.disconnect()
            except Exception:
                pass

    for i in range(count):
        t = threading.Thread(target=worker, args=(i,), daemon=True)
        t.start()
        threads.append(t)
    time.sleep(min(15, 3 + count * 0.1))
    return stop, threads


def pick_replicant_instance(region: str, asg_name: str, core_instance_id: str) -> str | None:
    data = aws_json(
        [
            "aws", "autoscaling", "describe-auto-scaling-groups",
            "--region", region,
            "--auto-scaling-group-names", asg_name,
            "--output", "json",
        ]
    )
    if not isinstance(data, dict):
        return None
    groups = data.get("AutoScalingGroups") or []
    if not groups:
        return None
    for inst in groups[0].get("Instances", []):
        iid = inst.get("InstanceId")
        if iid and iid != core_instance_id and inst.get("LifecycleState") == "InService":
            return iid
    return None


def terminate_instance(region: str, instance_id: str) -> bool:
    try:
        subprocess.check_call(
            ["aws", "ec2", "terminate-instances", "--region", region, "--instance-ids", instance_id],
            timeout=60,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def reboot_core_ssm(region: str, core_instance_id: str) -> bool:
    data = aws_json(
        [
            "aws", "ssm", "send-command",
            "--region", region,
            "--instance-ids", core_instance_id,
            "--document-name", "AWS-RunShellScript",
            "--parameters", json.dumps({"commands": ["sudo systemctl restart emqx"]}),
            "--output", "json",
        ]
    )
    return isinstance(data, dict) and "Command" in data


def main() -> int:
    p = argparse.ArgumentParser(description="EMQX cluster resilience tests")
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "ap-south-1"))
    p.add_argument("--core-ip", default=os.environ.get("EMQX_CORE_IP", ""))
    p.add_argument("--core-instance-id", default=os.environ.get("EMQX_CORE_INSTANCE_ID", ""))
    p.add_argument("--mqtt-host", default=os.environ.get("MQTT_HOST", ""))
    p.add_argument("--mqtt-port", type=int, default=1883)
    p.add_argument("--asg-name", default=os.environ.get("ASG_NAME", ""))
    p.add_argument("--dashboard-user", default=os.environ.get("EMQX_DASHBOARD_USERNAME", "admin"))
    p.add_argument("--dashboard-password", default=os.environ.get("EMQX_DASHBOARD_PASSWORD", ""))
    p.add_argument("--load-clients", type=int, default=100)
    p.add_argument(
        "--scenario",
        choices=["replicant-terminate", "core-reboot", "all"],
        default="replicant-terminate",
    )
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    if not args.mqtt_host or not args.core_ip:
        print("Set --mqtt-host and --core-ip", file=sys.stderr)
        return 1
    if not args.dashboard_password:
        print("Set --dashboard-password or EMQX_DASHBOARD_PASSWORD", file=sys.stderr)
        return 1

    report = Report()
    token = emqx_token(args.core_ip, args.dashboard_user, args.dashboard_password)
    if not token:
        report.add("Dashboard login", False, "Cannot authenticate")
        return 1

    before = client_count(args.core_ip, token)
    report.add("Baseline client count", before is not None, f"clients={before}")

    stop, threads = mqtt_holders(args.mqtt_host, args.mqtt_port, args.load_clients, "test/resilience/#")
    during = client_count(args.core_ip, token)
    report.add("MQTT load connected", (during or 0) >= min(args.load_clients // 2, 10), f"clients={during}")

    if args.scenario in ("replicant-terminate", "all"):
        target = pick_replicant_instance(args.region, args.asg_name, args.core_instance_id)
        if not target:
            report.add("Pick replicant", False, "No in-service replicant found")
        elif args.dry_run:
            report.add("Replicant termination (dry-run)", True, f"Would terminate {target}")
        else:
            report.add("Replicant pick", True, f"terminating {target}")
            ok = terminate_instance(args.region, target)
            report.add("Replicant terminate API", ok, f"instance={target}")
            time.sleep(30)
            after = client_count(args.core_ip, token)
            recovered = after is not None and after >= max((during or 0) * 0.8, 10)
            report.add(
                "Client count after replicant failure",
                recovered,
                f"before={during} after={after} (expect >=80% recovery in 30s)",
            )
            if args.core_instance_id:
                status = cluster_status_ssm(args.region, args.core_instance_id)
                report.add("Cluster status after failure", "running_nodes" in status, status[:500])

    if args.scenario in ("core-reboot", "all"):
        if not args.core_instance_id:
            report.add("Core reboot", False, "Set --core-instance-id")
        elif args.dry_run:
            report.add("Core reboot (dry-run)", True, f"Would restart emqx on {args.core_instance_id}")
        else:
            ok = reboot_core_ssm(args.region, args.core_instance_id)
            report.add("Core reboot command", ok, args.core_instance_id)
            time.sleep(45)
            token2 = emqx_token(args.core_ip, args.dashboard_user, args.dashboard_password)
            after = client_count(args.core_ip, token2) if token2 else None
            report.add(
                "Clients after core reboot",
                after is not None and after >= max((during or 0) * 0.5, 5),
                f"clients={after}",
            )

    stop.set()
    for t in threads:
        t.join(timeout=5)

    print("\n" + "=" * 60)
    if report.ok():
        print("=== RESILIENCE: ALL CHECKS PASSED ===")
        return 0
    print("=== RESILIENCE: SOME CHECKS FAILED ===")
    print("Failed:", ", ".join(c.name for c in report.checks if not c.passed))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
