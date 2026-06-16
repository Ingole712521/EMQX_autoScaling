"""Shared MQTT helpers for load tests, probes, and cluster proof scripts."""

from __future__ import annotations


def connack_ok(reason_code: object) -> bool:
    if reason_code is None:
        return False
    return getattr(reason_code, "value", reason_code) == 0
