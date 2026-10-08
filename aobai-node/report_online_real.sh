#!/usr/bin/env bash
# 每分钟由节点运行用户（非 root、无需 sudo）的 crontab 调用：
#   * * * * * <INSTALL_ROOT>/tools/report_online_real.sh >> /tmp/report_online_real.log 2>&1
# 需要：etc/deployment.json 对运行用户可读（安装器设为 root:<运行用户> 0640），
#       env/aobai-node.env 中的 ONLINE_REPORT_AUTH（上报认证串，不写进仓库）。
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
AOBAI_ENV_FILE="${AOBAI_ENV_FILE:-$INSTALL_ROOT/env/aobai-node.env}"
export INSTALL_ROOT AOBAI_ENV_FILE

# 防止上一轮还没跑完时重叠执行。
lock_dir="$INSTALL_ROOT/var"
[[ -d "$lock_dir" && -w "$lock_dir" ]] || lock_dir="${TMPDIR:-/tmp}"
exec 9>"$lock_dir/online-report.lock"
if ! flock -n 9; then
  echo "$(date '+%F %T') skip: previous run still active"
  exit 0
fi

exec python3 - <<'PY'
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

root = os.environ["INSTALL_ROOT"]
env_file = os.environ["AOBAI_ENV_FILE"]


def load_env_file(path):
    values = {}
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


file_env = load_env_file(env_file)


def setting(name, default=""):
    # 进程环境变量优先，其次 env/aobai-node.env，最后默认值。
    value = os.environ.get(name)
    if value is None or value == "":
        value = file_env.get(name, "")
    return value if value != "" else default


ssm_port = setting("MULTI_SSM_PORT", "28912")
ssm_api_url = setting("SSM_API_URL", f"http://127.0.0.1:{ssm_port}").rstrip("/")
online_window_sec = int(setting("ONLINE_WINDOW_SEC", "300"))
sample_seconds = int(setting("SAMPLE_SECONDS", "10"))
api_host = setting("API_HOST", "5ufradius.5ufkefu.com")
# API_AUTH 仅为兼容旧的手工覆盖方式；正式配置写在 env 文件的 ONLINE_REPORT_AUTH。
auth = setting("ONLINE_REPORT_AUTH") or setting("API_AUTH")
ssm_protocols = tuple(
    item.strip()
    for item in setting("SSM_PROTOCOLS", "hysteria2,https-connect,vless-xray").split(",")
    if item.strip()
)

if not auth:
    print(
        f"{datetime.datetime.now():%F %T} error=missing-auth "
        f"hint=set ONLINE_REPORT_AUTH in {env_file}"
    )
    raise SystemExit(2)

state_path = os.path.join(root, "etc", "deployment.json")
try:
    with open(state_path, encoding="utf-8") as handle:
        state = json.load(handle)
except PermissionError:
    print(
        f"{datetime.datetime.now():%F %T} error=cannot-read {state_path} "
        "hint=chgrp <run-user> deployment.json && chmod 0640 deployment.json"
    )
    raise SystemExit(2)
panel_url = state["panel_url"].rstrip("/")
mu_key = state["mu_key"]
node_ids = list(dict.fromkeys(int(value) for value in state["node_ids"]))


def panel_get(path):
    separator = "&" if "?" in path else "?"
    url = f"{panel_url}{path}{separator}key={urllib.parse.quote(mu_key)}&muKey={urllib.parse.quote(mu_key)}"
    request = urllib.request.Request(url, headers={"User-Agent": "AoBai-Online-Reporter/3.0"})
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = json.load(response)
    if payload.get("ret") != 1:
        raise RuntimeError(f"panel returned ret={payload.get('ret')} for {path.split('?')[0]}")
    return payload.get("data")


# 只需要每个节点 ID 对应的 server 名称（小请求，结果缓存 1 小时，面板
# 暂时不可用时沿用缓存）。不再逐节点拉 /mod_mu/users：每个用户的 UUID
# 全局唯一，直接按 UUID 去重即可；拉全量用户表每次约 20 秒、近 500KB，
# 十几个节点 ID 会让每轮上报超过一分钟。
server_cache_path = os.path.join(root, "var", "online-servers.json")
server_cache_ttl = int(setting("SERVER_CACHE_TTL", "3600"))
try:
    with open(server_cache_path, encoding="utf-8") as handle:
        server_cache = json.load(handle)
except (FileNotFoundError, ValueError, PermissionError):
    server_cache = {}

servers = {}
cache_dirty = False
for node_id in node_ids:
    cached = server_cache.get(str(node_id)) or {}
    fresh = cached.get("server") and time.time() - float(cached.get("ts") or 0) < server_cache_ttl
    if fresh:
        servers[node_id] = cached["server"]
        continue
    try:
        info = panel_get(f"/mod_mu/nodes/{node_id}/info") or {}
        server = str(info.get("server") or "").strip()
        if server:
            server_cache[str(node_id)] = {"server": server, "ts": int(time.time())}
            cache_dirty = True
        servers[node_id] = server or cached.get("server", "")
    except Exception as error:
        print(f"warn=node-info-failed node={node_id} error={error.__class__.__name__}")
        servers[node_id] = cached.get("server", "")
if cache_dirty:
    try:
        tmp_path = f"{server_cache_path}.{os.getpid()}.tmp"
        with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(server_cache, handle, separators=(",", ":"))
        os.replace(tmp_path, server_cache_path)
    except OSError:
        pass


def normalize_user(raw):
    raw = str(raw or "").strip()
    # hysteria2 入站的用户名带 aobai- 前缀，https-connect / vless-xray 直接是 UUID。
    if raw.startswith("aobai-"):
        raw = raw[6:]
    return raw


# SSM 的 tcpSessions/udpSessions 是累计值，不能用来判断当前在线。采样两次
# per-user/per-inbound 流量计数，采样期间有字节或包增量、或当前仍有活动连接
# （tcpActiveConnections/udpActiveConnections，新版 sbox 才有）的用户续活。
def fetch_ssm_counters():
    counters = {}
    active = set()
    for protocol in ssm_protocols:
        url = f"{ssm_api_url}/{protocol}/server/v1/stats"
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                users = (json.load(response) or {}).get("users") or []
        except urllib.error.HTTPError as error:
            if error.code == 404:
                continue
            raise
        for entry in users:
            raw_user = normalize_user(entry.get("username"))
            if not raw_user:
                continue
            for tag, traffic in (entry.get("inboundTraffic") or {}).items():
                match = re.search(r"-(\d+)$", str(tag))
                if not match:
                    continue
                node_id = int(match.group(1))
                if node_id not in servers:
                    continue
                key = (node_id, raw_user)
                counters[key] = counters.get(key, 0) + sum(
                    int(traffic.get(field) or 0)
                    for field in (
                        "uplinkBytes", "downlinkBytes",
                        "uplinkPackets", "downlinkPackets",
                    )
                )
                if int(traffic.get("tcpActiveConnections") or 0) + int(traffic.get("udpActiveConnections") or 0) > 0:
                    active.add(key)
    return counters, active


before, _ = fetch_ssm_counters()
time.sleep(max(1, sample_seconds))
after, active_now = fetch_ssm_counters()
now = int(time.time())
activity_path = os.path.join(root, "var", "online-activity.json")
try:
    with open(activity_path, encoding="utf-8") as handle:
        activity = json.load(handle)
except (FileNotFoundError, ValueError, PermissionError):
    activity = {}

for key, value in after.items():
    if value > before.get(key, value) or key in active_now:
        node_id, raw_user = key
        activity[f"{node_id}|{raw_user}"] = now

activity = {
    key: int(last_seen)
    for key, last_seen in activity.items()
    if now - int(last_seen) <= online_window_sec
}
try:
    os.makedirs(os.path.dirname(activity_path), exist_ok=True)
    tmp_activity_path = f"{activity_path}.{os.getpid()}.tmp"
    with open(tmp_activity_path, "w", encoding="utf-8") as handle:
        json.dump(activity, handle, separators=(",", ":"))
    os.replace(tmp_activity_path, activity_path)
except OSError as error:
    print(f"warn=activity-state-not-saved error={error.__class__.__name__}")

# 同一个 server（面板里的节点地址）可能对应多个节点 ID / 协议，按 server 合并
# 后对用户 ID 去重，只上报一次，避免同一 server 被多次覆盖写入。
combined = {}
new_counts = {}
for key in activity:
    node_text, raw_user = key.split("|", 1)
    node_id = int(node_text)
    if node_id not in servers:
        continue
    combined.setdefault(node_id, set()).add(f"uuid:{raw_user}")
    new_counts.setdefault(node_id, set()).add(f"uuid:{raw_user}")

# 迁移期间合并仍在运行的旧 XrayR 实例看到的用户（无权限读取时跳过）。
cutoff = datetime.datetime.now() - datetime.timedelta(minutes=5)
timestamp_re = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) ")
user_re = re.compile(r"\|\|(\d+)\s*$")
old_counts = {}
for config_path in glob.glob("/etc/XrayR/service*/config.yml"):
    service = os.path.basename(os.path.dirname(config_path))
    active = subprocess.run(
        ["systemctl", "is-active", "--quiet", f"XrayR@{service}"],
        check=False,
    ).returncode == 0
    if not active:
        continue
    try:
        text = open(config_path, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    node_match = re.search(r"^\s*NodeID:\s*(\d+)\s*$", text, re.MULTILINE)
    log_match = re.search(r"^\s*AccessPath:\s*(\S+)\s*$", text, re.MULTILINE)
    if not node_match or not log_match:
        continue
    node_id = int(node_match.group(1))
    log_path = log_match.group(1)
    if node_id not in servers or not os.access(log_path, os.R_OK):
        continue
    output = subprocess.run(
        ["tail", "-n", "50000", log_path],
        check=False,
        capture_output=True,
        text=True,
    ).stdout
    for line in output.splitlines():
        if " accepted " not in line:
            continue
        time_match = timestamp_re.match(line)
        user_match = user_re.search(line)
        if not time_match or not user_match:
            continue
        try:
            timestamp = datetime.datetime.strptime(time_match.group(1), "%Y/%m/%d %H:%M:%S")
        except ValueError:
            continue
        if timestamp < cutoff:
            continue
        user = user_match.group(1)
        combined.setdefault(node_id, set()).add(user)
        old_counts.setdefault(node_id, set()).add(user)

# 只有仍在跑旧 XrayR 的节点（日志里是用户 ID）才需要 UUID→用户 ID 映射来
# 和新协议用户合并去重；这种节点才按需拉一次用户表。
for node_id in list(old_counts):
    try:
        users = panel_get(f"/mod_mu/users?node_id={node_id}") or []
    except Exception as error:
        print(f"warn=user-map-failed node={node_id} error={error.__class__.__name__}")
        continue
    uuid_to_id = {
        str(user.get("uuid") or "").strip(): str(user.get("id"))
        for user in users
        if user.get("uuid") and user.get("id") is not None
    }
    combined[node_id] = {
        uuid_to_id.get(item[5:], item) if item.startswith("uuid:") else item
        for item in combined.get(node_id, set())
    }

by_server = {}
for node_id in node_ids:
    by_server.setdefault(servers.get(node_id) or "", []).append(node_id)

failures = 0
stamp = f"{datetime.datetime.now():%F %T}"
for server, ids in by_server.items():
    if not server:
        print(f"{stamp} nodes={','.join(map(str, ids))} error=missing-server")
        failures += 1
        continue
    users = set().union(*(combined.get(i, set()) for i in ids))
    new_users = set().union(*(new_counts.get(i, set()) for i in ids))
    legacy_users = set().union(*(old_counts.get(i, set()) for i in ids))
    params = urllib.parse.urlencode({
        "api": "update_online",
        "server": server,
        "online": str(len(users)),
    })
    url = f"http://{api_host}/5uf_api/client_online.php?{params}"
    # 认证串放在请求头里，不进 URL，避免出现在服务端访问日志。
    request = urllib.request.Request(url, headers={
        "User-Agent": "AoBai-Online-Reporter/3.0",
        "X-Report-Auth": auth,
    })
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = response.read().decode("utf-8", errors="ignore")
        compact = " ".join(body.split())[:80]
        ok = "int(-1)" not in compact
        if not ok:
            failures += 1
        print(
            f"{stamp} server={server} nodes={','.join(map(str, ids))} online={len(users)} "
            f"new={len(new_users)} legacy={len(legacy_users)} "
            f"http={response.status} {'ok' if ok else 'auth-rejected'} body={compact}"
        )
    except Exception as error:
        failures += 1
        print(f"{stamp} server={server} error={error.__class__.__name__}: {error}")

raise SystemExit(1 if failures else 0)
PY
