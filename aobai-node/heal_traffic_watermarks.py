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
import os
import subprocess
import sys
import urllib.error
import urllib.request

# tools/ 的上一级就是安装目录（例如 /home/ops/aobai-node）。
DEFAULT_ROOT = os.environ.get(
    "AOBAI_ROOT",
    os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")),
)
PREFIX = "sbox:5uf-multi:monitor:proto:"
SESSIONS_PATH = "/api/v1/sessions/sessions"


def load_env_file(path: str) -> dict:
    values: dict = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                if key.startswith("export "):
                    key = key[7:].strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                    value = value[1:-1]
                values[key] = value
    except FileNotFoundError:
        pass
    return values


def setting(name: str, file_env: dict, default: str = "") -> str:
    """进程环境变量优先，其次 env/aobai-node.env，最后默认值。"""
    value = os.environ.get(name) or file_env.get(name) or ""
    return value or default


def mask(value: str) -> str:
    value = str(value or "")
    return value[:8] + "…" if len(value) > 8 else value


def redis(args: list[str], redis_bin: list[str]) -> str:
    out = subprocess.check_output(redis_bin + args, text=True)
    return out.strip()


def load_sessions(url: str, token: str) -> list[dict]:
    headers = {"User-Agent": "aobai-heal-watermarks/2"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
        headers["X-Monitor-Token"] = token
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=10) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise SystemExit(
                f"monitor API 拒绝访问 (HTTP {error.code})：检查 MONITOR_AUTH_TOKEN"
            )
        raise
    return (data.get("data") or {}).get("sessions") or data.get("sessions") or []


def tag_key(protocol: str, inbound_tag: str) -> str:
    return f"{protocol}_{inbound_tag}"


def heal_user(uuid: str, protocol: str, inbound_tag: str, live_tx: int, live_rx: int,
              redis_bin: list[str], apply: bool) -> dict:
    key = PREFIX + uuid
    field = tag_key(protocol, inbound_tag)
    raw = redis(["HGET", key, field], redis_bin)
    result = {
        "uuid": mask(uuid),
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
    ap.add_argument("--i-know-this-double-reports", action="store_true",
                    help="--apply 的确认开关（见下方警告）")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="aobai-node 安装目录")
    ap.add_argument("--env-file", default=None,
                    help="默认 <root>/env/aobai-node.env")
    ap.add_argument("--sessions-url", default=None,
                    help="默认 http://$MONITOR_BIND_IP:$MULTI_MONITOR_PORT" + SESSIONS_PATH)
    ap.add_argument("--token", default=None,
                    help="默认读取 MONITOR_AUTH_TOKEN（环境变量或 env 文件）")
    ap.add_argument("--redis-cli", default=None,
                    help="逗号分隔，默认 <root>/bin/redis-cli-embedded,-p,$AOBAI_REDIS_PORT")
    args = ap.parse_args()
    # 警告（2026-10-09 jp4 实测）：本工具用单个会话的累计值对比按用户+tag 汇总的
    # last_reported 水位，多会话/重连的用户会被误判为“卡住”。--apply 把这些水位清零后，
    # 下一轮 SSPanel 上报会把整段累计流量重新上报一遍（jp4 一次多报约 20GB）。
    # 只读模式可用于排查；除非逐个核实确实是重启后水位卡死，否则不要 --apply。
    if args.apply and not args.i_know_this_double_reports:
        print("refusing --apply: false positives cause double-reported traffic; "
              "re-run with --i-know-this-double-reports after verifying each user", file=sys.stderr)
        return 2

    env_file = args.env_file or os.path.join(args.root, "env", "aobai-node.env")
    file_env = load_env_file(env_file)
    host = setting("MONITOR_BIND_IP", file_env, "127.0.0.1")
    port = setting("MULTI_MONITOR_PORT", file_env, "28910")
    sessions_url = args.sessions_url or f"http://{host}:{port}{SESSIONS_PATH}"
    token = args.token if args.token is not None else setting("MONITOR_AUTH_TOKEN", file_env)
    redis_port = setting("AOBAI_REDIS_PORT", file_env, "6382")
    redis_cli = args.redis_cli or ",".join(
        [os.path.join(args.root, "bin", "redis-cli-embedded"), "-p", redis_port]
    )
    redis_bin = redis_cli.split(",")

    sessions = load_sessions(sessions_url, token)
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
        "sessions_url": sessions_url,
        "auth": "token" if token else "none",
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
