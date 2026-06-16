#!/usr/bin/env python3
"""
End-to-end proof for EMQX on AWS:
  1) NLB targets healthy
  2) MQTT connect + publish via NLB
  3) Cluster nodes visible in EMQX API
  4) MQTT clients spread across replicant nodes (not all on one)
  5) ASG capacity reported
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

import paho.mqtt.client as mqtt
import requests

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "loadtest"))
from mqtt_common import connack_ok  # noqa: E402


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str


@dataclass
class ProofReport:
    results: list[CheckResult] = field(default_factory=list)

    def add(self, name: str, passed: bool, detail: str) -> None:
        self.results.append(CheckResult(name, passed, detail))
        tag = "PASS" if passed else "FAIL"
        print(f"[{tag}] {name}")
        for line in detail.splitlines():
            print(f"      {line}")

    def ok(self) -> bool:
        return all(r.passed for r in self.results)


def aws_json(cmd: list[str]) -> dict | list | None:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, timeout=60)
        return json.loads(out) if out.strip() else None
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError) as exc:
        return {"error": str(exc)}


def aws_text(cmd: list[str]) -> str | None:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, timeout=60).strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        return None


def check_nlb_targets(report: ProofReport, region: str, project: str) -> list[str]:
    tg_name = f"{project}-mqtt-tg"
    arn = aws_text(
        [
            "aws", "elbv2", "describe-target-groups",
            "--region", region,
            "--names", tg_name,
            "--query", "TargetGroups[0].TargetGroupArn",
            "--output", "text",
        ]
    )
    if not arn or arn == "None":
        report.add("NLB target group", False, f"Cannot find {tg_name}")
        return []
    health = aws_json(
        [
            "aws", "elbv2", "describe-target-health",
            "--region", region,
            "--target-group-arn", arn,
            "--output", "json",
        ]
    )
    if not isinstance(health, dict):
        report.add("NLB target health", False, "AWS CLI failed")
        return []

    targets = health.get("TargetHealthDescriptions", [])
    healthy = [t for t in targets if t.get("TargetHealth", {}).get("State") == "healthy"]
    lines = [f"healthy={len(healthy)} total={len(targets)}"]
    for t in targets:
        tid = t.get("Target", {}).get("Id", "?")
        state = t.get("TargetHealth", {}).get("State", "?")
        lines.append(f"  instance {tid}: {state}")

    report.add(
        "NLB target health",
        len(healthy) > 0,
        "\n".join(lines) if lines else "no targets",
    )
    return [t["Target"]["Id"] for t in healthy]


def check_asg(report: ProofReport, region: str, asg_name: str) -> None:
    data = aws_json(
        [
            "aws", "autoscaling", "describe-auto-scaling-groups",
            "--region", region,
            "--auto-scaling-group-names", asg_name,
            "--output", "json",
        ]
    )
    if not isinstance(data, dict) or not data.get("AutoScalingGroups"):
        report.add("Auto Scaling Group", False, f"ASG {asg_name} not found")
        return

    g = data["AutoScalingGroups"][0]
    detail = (
        f"desired={g.get('DesiredCapacity')} "
        f"min={g.get('MinSize')} max={g.get('MaxSize')} "
        f"instances={len(g.get('Instances', []))}"
    )
    report.add("Auto Scaling Group", g.get("DesiredCapacity", 0) >= 1, detail)


def emqx_login(core_ip: str, user: str, password: str) -> str | None:
    url = f"http://{core_ip}:18083/api/v5/login"
    try:
        r = requests.post(url, json={"username": user, "password": password}, timeout=15)
        if r.status_code != 200:
            return None
        return r.json().get("token")
    except requests.RequestException:
        return None


def emqx_nodes(core_ip: str, token: str) -> list[dict]:
    url = f"http://{core_ip}:18083/api/v5/nodes"
    r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=15)
    r.raise_for_status()
    data = r.json()
    if isinstance(data, list):
        return data
    return data.get("data", data.get("nodes", []))


def node_connections(node: dict) -> int:
    for key in ("live_connections", "connections", "conn_count", "connected"):
        val = node.get(key)
        if val is not None:
            try:
                return int(val)
            except (TypeError, ValueError):
                pass
    for container in (node.get("stats"), node.get("metrics"), node):
        if not isinstance(container, dict):
            continue
        for key in ("live_connections", "connections", "connections.count", "conn_count"):
            if key in container and container[key] is not None:
                try:
                    return int(container[key])
                except (TypeError, ValueError):
                    pass
    return 0


def emqx_clients_count(core_ip: str, token: str) -> int | None:
    """Cluster-wide live client count while MQTT sessions are active."""
    url = f"http://{core_ip}:18083/api/v5/clients"
    try:
        r = requests.get(
            url,
            headers={"Authorization": f"Bearer {token}"},
            params={"limit": 1, "page": 1},
            timeout=15,
        )
        r.raise_for_status()
        data = r.json()
        meta = data.get("meta") or {}
        if "count" in meta:
            return int(meta["count"])
    except (requests.RequestException, TypeError, ValueError):
        pass
    return None


def check_cluster_api(
    report: ProofReport,
    core_ip: str,
    user: str,
    password: str,
) -> list[dict]:
    token = emqx_login(core_ip, user, password)
    if not token:
        report.add("EMQX cluster API", False, "Dashboard login failed (check IP, password, port 18083)")
        return []

    try:
        nodes = emqx_nodes(core_ip, token)
    except requests.RequestException as exc:
        report.add("EMQX cluster API", False, str(exc))
        return []

    lines = []
    for n in nodes:
        name = n.get("node", n.get("node_name", "?"))
        role = n.get("role", n.get("type", "?"))
        conns = node_connections(n)
        lines.append(f"  {name} role={role} connections={conns}")

    report.add(
        "EMQX cluster API",
        len(nodes) >= 2,
        f"nodes={len(nodes)}\n" + "\n".join(lines) if lines else "no nodes",
    )
    return nodes


def mqtt_load_clients(
    host: str,
    port: int,
    count: int,
    topic: str,
    before_release: Callable[[], None] | None = None,
) -> tuple[int, int]:
    """Connect count clients with stagger; return (ok, fail)."""
    ok = 0
    fail = 0
    lock = threading.Lock()
    hold = threading.Event()
    hold.set()

    def worker(i: int) -> None:
        nonlocal ok, fail
        ready = threading.Event()
        rc_box: list[object] = [None]

        def on_connect(_c, _u, _f, rc, _p) -> None:
            rc_box[0] = rc
            ready.set()

        c = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"prove-{i}-{int(time.time())}",
            protocol=mqtt.MQTTv311,
        )
        c.on_connect = on_connect
        try:
            time.sleep(i * 0.1)
            c.connect(host, port, keepalive=60)
            c.loop_start()
            if not ready.wait(20) or not connack_ok(rc_box[0]):
                with lock:
                    fail += 1
                return
            while hold.is_set():
                c.publish(topic, json.dumps({"i": i}), qos=0)
                time.sleep(0.2)
            with lock:
                ok += 1
        except Exception:
            with lock:
                fail += 1
        finally:
            try:
                c.loop_stop()
                c.disconnect()
            except Exception:
                pass

    threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(count)]
    for t in threads:
        t.start()
    time.sleep(min(25, 5 + count * 0.12))
    if before_release:
        before_release()
    hold.clear()
    for t in threads:
        t.join(timeout=10)
    return ok, fail


def check_load_balance(
    report: ProofReport,
    nodes_before: list[dict],
    nodes_after: list[dict],
    asg_desired: int,
    cluster_clients: int | None = None,
) -> None:
    before = {
        n.get("node", n.get("node_name", "")): node_connections(n) for n in nodes_before
    }
    after = {
        n.get("node", n.get("node_name", "")): node_connections(n) for n in nodes_after
    }

    lines = ["Connections per node (after load):"]
    total = 0
    with_traffic = 0
    for name, c in sorted(after.items()):
        lines.append(f"  {name}: {c}")
        total += c
        if c > 0:
            with_traffic += 1

    gained = sum(1 for n, c in after.items() if c > before.get(n, 0))
    lines.append(f"total_connections={total} nodes_with_connections={with_traffic} nodes_gained_load={gained}")
    if cluster_clients is not None:
        lines.append(f"cluster_live_clients_api={cluster_clients}")

    if asg_desired >= 2:
        spread_ok = with_traffic >= 2 or gained >= 2
        lines.append(
            f"ASG desired={asg_desired}: NLB spreads TCP flows — need 2+ nodes with connections "
            "(run staged load test first if this fails)."
        )
    else:
        spread_ok = total > 0 or gained >= 1 or (cluster_clients is not None and cluster_clients > 0)
        lines.append("ASG=1: all MQTT via single replicant (expected until scale-out).")

    report.add("Load spread across nodes", spread_ok, "\n".join(lines))


def check_mqtt_probe(report: ProofReport, host: str, port: int) -> bool:
    ready = threading.Event()
    rc_box: list[object] = [None]

    def on_connect(_c, _u, _f, rc, _p) -> None:
        rc_box[0] = rc
        ready.set()

    c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="prove-probe", protocol=mqtt.MQTTv311)
    c.on_connect = on_connect
    try:
        c.connect(host, port, 30)
        c.loop_start()
        if not ready.wait(20):
            report.add("MQTT via NLB", False, "CONNACK timeout")
            return False
        if not connack_ok(rc_box[0]):
            report.add("MQTT via NLB", False, f"CONNACK={rc_box[0]} — enable anonymous MQTT on brokers")
            return False
        c.publish("loadtest/prove", "{}", qos=0)
        time.sleep(0.5)
        report.add("MQTT via NLB", True, f"{host}:{port} connect + publish OK")
        return True
    except Exception as exc:
        report.add("MQTT via NLB", False, str(exc))
        return False
    finally:
        try:
            c.loop_stop()
            c.disconnect()
        except Exception:
            pass


def main() -> int:
    p = argparse.ArgumentParser(description="Prove EMQX cluster, load spread, and ASG.")
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "ap-south-1"))
    p.add_argument("--project", default=os.environ.get("PROJECT_NAME", "emqx-prod"))
    p.add_argument("--core-ip", default=os.environ.get("EMQX_CORE_IP", ""))
    p.add_argument("--mqtt-host", default=os.environ.get("MQTT_HOST", ""))
    p.add_argument("--mqtt-port", type=int, default=1883)
    p.add_argument("--asg-name", default=os.environ.get("ASG_NAME", ""))
    p.add_argument("--dashboard-user", default=os.environ.get("EMQX_DASHBOARD_USERNAME", "admin"))
    p.add_argument("--dashboard-password", default=os.environ.get("EMQX_DASHBOARD_PASSWORD", ""))
    p.add_argument("--load-clients", type=int, default=50, help="Clients for load-spread test (use 50+ when ASG has 2+ nodes)")
    p.add_argument("--skip-load", action="store_true")
    args = p.parse_args()

    if not args.mqtt_host or not args.core_ip:
        print("Set --mqtt-host and --core-ip (or MQTT_HOST / EMQX_CORE_IP)", file=sys.stderr)
        return 1
    if not args.dashboard_password:
        print("Set --dashboard-password or EMQX_DASHBOARD_PASSWORD", file=sys.stderr)
        return 1

    asg = args.asg_name or f"{args.project}-replicants-asg"
    report = ProofReport()

    print("=" * 60)
    print("EMQX CLUSTER PROOF REPORT")
    print("=" * 60)

    check_nlb_targets(report, args.region, args.project)
    check_asg(report, args.region, asg)

    if not check_mqtt_probe(report, args.mqtt_host, args.mqtt_port):
        print("\n=== SUMMARY: FAILED (fix MQTT before load test) ===")
        return 1

    nodes_before = check_cluster_api(report, args.core_ip, args.dashboard_user, args.dashboard_password)

    asg_data = aws_json(
        [
            "aws", "autoscaling", "describe-auto-scaling-groups",
            "--region", args.region,
            "--auto-scaling-group-names", asg,
            "--output", "json",
        ]
    )
    asg_desired = 1
    if isinstance(asg_data, dict) and asg_data.get("AutoScalingGroups"):
        asg_desired = int(asg_data["AutoScalingGroups"][0].get("DesiredCapacity", 1))

    if not args.skip_load:
        print(f"\nConnecting {args.load_clients} MQTT clients through NLB (staggered)...")
        snapshot: dict[str, object] = {"nodes": [], "clients": None}

        def capture_load_snapshot() -> None:
            token = emqx_login(args.core_ip, args.dashboard_user, args.dashboard_password)
            if not token:
                return
            try:
                snapshot["nodes"] = emqx_nodes(args.core_ip, token)
                snapshot["clients"] = emqx_clients_count(args.core_ip, token)
            except requests.RequestException:
                pass

        ok, fail = mqtt_load_clients(
            args.mqtt_host,
            args.mqtt_port,
            args.load_clients,
            "loadtest/prove",
            before_release=capture_load_snapshot,
        )
        report.add(
            "MQTT load clients",
            ok > 0 and fail == 0,
            f"connected_ok={ok} failed={fail}",
        )
        nodes_after = snapshot["nodes"] if isinstance(snapshot["nodes"], list) else []
        clients_count = snapshot["clients"] if isinstance(snapshot["clients"], int) else None
        if nodes_after or clients_count:
            check_load_balance(
                report, nodes_before, nodes_after, asg_desired, cluster_clients=clients_count
            )
        else:
            report.add(
                "Load spread across nodes",
                False,
                "Could not read connection metrics while clients were connected",
            )

    print("\n" + "=" * 60)
    if report.ok():
        print("=== SUMMARY: ALL CHECKS PASSED ===")
        print("You have proof that:")
        print("  - NLB reaches healthy EMQX replicants")
        print("  - MQTT clients connect through the NLB")
        print("  - EMQX nodes form a cluster (API)")
        print("  - Connection load appears on broker nodes (not only one, when scaled)")
        print("Run staged load test for autoscaling: .\\scripts\\run_staged_load_test.ps1 -FromTerraform")
        return 0

    print("=== SUMMARY: SOME CHECKS FAILED ===")
    failed = [r.name for r in report.results if not r.passed]
    print("Failed:", ", ".join(failed))
    print("\nFix order:")
    print("  1. powershell -File scripts/fix_mqtt_anonymous_ssm.ps1")
    print("  2. terraform apply")
    print("  3. aws autoscaling start-instance-refresh --auto-scaling-group-name", asg)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
