#!/usr/bin/env python3
"""Heal aobai SSPanel traffic watermarks stuck after process restart.

After sbox-server restarts, live per-user counters reset but Redis
`last_reported_*` on tagged protocol keys (e.g. hysteria2_5uf-hysteria2-209)
can remain high. SSPanel reporting then sees rx_delta=0 forever, so panel
radacct stops updating for that node even while the user is online.

Strategy:
- For each active session, read Redis proto hash.
- If tagged key last_reported_* > live session cumulative, reset last_reported
  to 0 and clear deltas so the next report catch-up includes post-restart traffic
  that was never sent to the panel.
- Clear orphan bare-protocol pending deltas (hysteria2 / https-connect / vless-xray)
  that are not used by tag-scoped compatible_sspanel reporters.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.request

DEFAULT_REDIS = ["/home/ops/aobai-node/bin/redis-cli-embedded", "-p", "6382"]
DEFAULT_SESSIONS = "http://127.0.0.1:28910/api/v1/sessions/sessions"
PREFIX = "sbox:5uf-multi:monitor:proto:"


def redis(args: list[str], redis_bin: list[str]) -> str:
    out = subprocess.check_output(redis_bin + args, text=True)
    return out.strip()


def load_sessions(url: str) -> list[dict]:
    with urllib.request.urlopen(url, timeout=10) as resp:
        data = json.load(resp)
    return (data.get("data") or {}).get("sessions") or data.get("sessions") or []


def tag_key(protocol: str, inbound_tag: str) -> str:
    return f"{protocol}_{inbound_tag}"


def heal_user(uuid: str, protocol: str, inbound_tag: str, live_tx: int, live_rx: int,
              redis_bin: list[str], apply: bool) -> dict:
    key = PREFIX + uuid
    field = tag_key(protocol, inbound_tag)
    raw = redis(["HGET", key, field], redis_bin)
    result = {
        "uuid": uuid,
        "field": field,
        "live_tx": live_tx,
        "live_rx": live_rx,
        "action": "skip",
    }
    if not raw:
        result["action"] = "missing_tag_key"
        return result
    d = json.loads(raw)
    lr_tx = int(d.get("last_reported_tx_bytes") or 0)
    lr_rx = int(d.get("last_reported_rx_bytes") or 0)
    result["last_reported_tx"] = lr_tx
    result["last_reported_rx"] = lr_rx
    stuck = lr_rx > live_rx + 1024 or lr_tx > live_tx + 1024
    if not stuck:
        result["action"] = "ok"
        return result

    new = {
        "protocol": field,
        "tx_delta": 0,
        "rx_delta": 0,
        # Zero watermark so catch-up reports post-restart unreported traffic.
        "last_reported_tx_bytes": 0,
        "last_reported_rx_bytes": 0,
    }
    result["action"] = "heal_stuck_watermark"
    result["new"] = new
    if apply:
        redis(["HSET", key, field, json.dumps(new, separators=(",", ":"))], redis_bin)
        # Drop orphan bare-protocol pending buckets that confuse monitor totals.
        for bare in ("hysteria2", "https-connect", "vless-xray", "vless"):
            redis(["HDEL", key, bare], redis_bin)
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="Write Redis changes")
    ap.add_argument("--sessions-url", default=DEFAULT_SESSIONS)
    ap.add_argument("--redis-cli", default=",".join(DEFAULT_REDIS))
    args = ap.parse_args()
    redis_bin = args.redis_cli.split(",")

    sessions = load_sessions(args.sessions_url)
    healed = []
    ok = 0
    missing = 0
    for s in sessions:
        uuid = s.get("user_uuid") or ""
        protocol = s.get("protocol") or ""
        tag = s.get("inbound_tag") or ""
        if not uuid or not protocol or not tag:
            continue
        # Session API uses protocol names like hysteria2 / https-connect / vless-xray
        r = heal_user(
            uuid,
            protocol,
            tag,
            int(s.get("cumulative_tx") or 0),
            int(s.get("cumulative_rx") or 0),
            redis_bin,
            args.apply,
        )
        if r["action"] == "ok":
            ok += 1
        elif r["action"] == "missing_tag_key":
            missing += 1
        else:
            healed.append(r)

    summary = {
        "apply": bool(args.apply),
        "sessions": len(sessions),
        "ok": ok,
        "missing_tag_key": missing,
        "healed": len(healed),
        "samples": healed[:20],
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
