#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -n "$0" "$@"
fi

MONITOR_URL="${MONITOR_URL:-http://127.0.0.1:28910/monitor/status}"
SSM_API_URL="${SSM_API_URL:-http://127.0.0.1:28912}"
ONLINE_WINDOW_SEC="${ONLINE_WINDOW_SEC:-300}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-10}"
API_HOST="${API_HOST:-5ufradius.5ufkefu.com}"
API_AUTH="${API_AUTH:-iaodsiu}"
INSTALL_ROOT="${INSTALL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export MONITOR_URL SSM_API_URL ONLINE_WINDOW_SEC SAMPLE_SECONDS API_HOST API_AUTH INSTALL_ROOT

python3 - <<'PY'
import datetime
import glob
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

monitor_url = os.environ["MONITOR_URL"]
ssm_api_url = os.environ["SSM_API_URL"].rstrip("/")
online_window_sec = int(os.environ["ONLINE_WINDOW_SEC"])
sample_seconds = int(os.environ["SAMPLE_SECONDS"])
api_host = os.environ["API_HOST"]
auth = os.environ["API_AUTH"]
root = os.environ["INSTALL_ROOT"]
state_path = os.path.join(root, "etc", "deployment.json")

with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
panel_url = state["panel_url"].rstrip("/")
mu_key = state["mu_key"]
node_ids = list(dict.fromkeys(int(value) for value in state["node_ids"]))

def panel_get(path):
    separator = "&" if "?" in path else "?"
    url = f"{panel_url}{path}{separator}key={urllib.parse.quote(mu_key)}&muKey={urllib.parse.quote(mu_key)}"
    request = urllib.request.Request(url, headers={"User-Agent": "AoBai-Online-Reporter/2.0"})
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = json.load(response)
    if payload.get("ret") != 1:
        raise RuntimeError(f"panel returned ret={payload.get('ret')} for {path}")
    return payload.get("data")

servers = {}
uuid_to_user = {}
for node_id in node_ids:
    info = panel_get(f"/mod_mu/nodes/{node_id}/info") or {}
    servers[node_id] = str(info.get("server") or "").strip()
    users = panel_get(f"/mod_mu/users?node_id={node_id}") or []
    uuid_to_user[node_id] = {
        str(user.get("uuid") or "").strip(): str(user.get("id"))
        for user in users
        if user.get("uuid") and user.get("id") is not None
    }

combined = {node_id: set() for node_id in node_ids}
new_counts = {node_id: set() for node_id in node_ids}

# SSM 的 tcpSessions/udpSessions 是累计值，不能用来判断当前在线。采样两次
# per-user/per-inbound 流量计数，仅把采样期间有字节或包增量的用户续活。
ssm_protocols = ("vless-xray", "https-connect")

def fetch_ssm_counters():
    counters = {}
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
            raw_user = str(entry.get("username") or "").strip()
            if raw_user.startswith("aobai-"):
                raw_user = raw_user[6:]
            if not raw_user:
                continue
            for tag, traffic in (entry.get("inboundTraffic") or {}).items():
                match = re.search(r"-(\d+)$", str(tag))
                if not match:
                    continue
                node_id = int(match.group(1))
                if node_id not in combined:
                    continue
                counters[(node_id, raw_user)] = sum(
                    int(traffic.get(field) or 0)
                    for field in (
                        "uplinkBytes", "downlinkBytes",
                        "uplinkPackets", "downlinkPackets",
                    )
                )
    return counters

before = fetch_ssm_counters()
time.sleep(max(1, sample_seconds))
after = fetch_ssm_counters()
now = int(time.time())
activity_path = os.path.join(root, "var", "online-activity.json")
os.makedirs(os.path.dirname(activity_path), exist_ok=True)
try:
    with open(activity_path, encoding="utf-8") as handle:
        activity = json.load(handle)
except (FileNotFoundError, ValueError):
    activity = {}

for key, value in after.items():
    if value > before.get(key, value):
        node_id, raw_user = key
        activity[f"{node_id}|{raw_user}"] = now

activity = {
    key: int(last_seen)
    for key, last_seen in activity.items()
    if now - int(last_seen) <= online_window_sec
}
tmp_activity_path = activity_path + ".tmp"
with open(tmp_activity_path, "w", encoding="utf-8") as handle:
    json.dump(activity, handle, separators=(",", ":"))
os.replace(tmp_activity_path, activity_path)

for key in activity:
    node_text, raw_user = key.split("|", 1)
    node_id = int(node_text)
    user = uuid_to_user[node_id].get(raw_user, f"uuid:{raw_user}")
    combined[node_id].add(user)
    new_counts[node_id].add(user)

# During migration, merge users seen by still-running legacy XrayR instances.
cutoff = datetime.datetime.now() - datetime.timedelta(minutes=5)
timestamp_re = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) ")
user_re = re.compile(r"\|\|(\d+)\s*$")
old_counts = {node_id: set() for node_id in node_ids}
for config_path in glob.glob("/etc/XrayR/service*/config.yml"):
    service = os.path.basename(os.path.dirname(config_path))
    active = subprocess.run(
        ["systemctl", "is-active", "--quiet", f"XrayR@{service}"],
        check=False,
    ).returncode == 0
    if not active:
        continue
    text = open(config_path, encoding="utf-8", errors="ignore").read()
    node_match = re.search(r"^\s*NodeID:\s*(\d+)\s*$", text, re.MULTILINE)
    log_match = re.search(r"^\s*AccessPath:\s*(\S+)\s*$", text, re.MULTILINE)
    if not node_match or not log_match:
        continue
    node_id = int(node_match.group(1))
    log_path = log_match.group(1)
    if node_id not in combined or not os.path.isfile(log_path):
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
        combined[node_id].add(user)
        old_counts[node_id].add(user)

failures = 0
for node_id in node_ids:
    server = servers.get(node_id)
    if not server:
        print(f"node={node_id} error=missing-server")
        failures += 1
        continue
    params = urllib.parse.urlencode({
        "api": "update_online",
        "server": server,
        "online": str(len(combined[node_id])),
        "auth": auth,
    })
    url = f"http://{api_host}/5uf_api/client_online.php?{params}"
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            body = response.read().decode("utf-8", errors="ignore")
            print(
                f"node={node_id} server={server} online={len(combined[node_id])} "
                f"new={len(new_counts[node_id])} legacy={len(old_counts[node_id])} "
                f"http={response.status} body={body[:120]}"
            )
    except Exception as error:
        failures += 1
        print(f"node={node_id} server={server} error={error}")

raise SystemExit(1 if failures else 0)
PY
