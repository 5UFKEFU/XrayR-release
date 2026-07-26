#!/usr/bin/env bash
set -euo pipefail

MONITOR_URL="${MONITOR_URL:-http://127.0.0.1:28910/monitor/status}"
API_HOST="${API_HOST:-5ufradius.5ufkefu.com}"
API_AUTH="${API_AUTH:-iaodsiu}"
SERVER_NAME="${SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}"

python3 - <<'PY'
import json
import os
import urllib.parse
import urllib.request

monitor_url = os.getenv("MONITOR_URL", "http://127.0.0.1:28910/monitor/status")
api_host = os.getenv("API_HOST", "5ufradius.5ufkefu.com")
auth = os.getenv("API_AUTH", "iaodsiu")
server = os.getenv("SERVER_NAME") or os.uname().nodename

with urllib.request.urlopen(monitor_url, timeout=10) as response:
    sessions = json.load(response)

users = set()
protocol_counts = {}
for session in sessions if isinstance(sessions, list) else []:
    online = session.get("Online")
    status = str(session.get("Status", "")).lower()
    if not (online in (1, True, "1") or status == "active"):
        continue
    user_id = str(session.get("UserID", "")).strip()
    if not user_id:
        continue
    users.add(user_id)
    protocol = str(session.get("Protocol", "unknown")).strip() or "unknown"
    protocol_counts.setdefault(protocol, set()).add(user_id)

online = len(users)
params = urllib.parse.urlencode({
    "api": "update_online",
    "server": server,
    "online": str(online),
    "auth": auth,
})
url = f"http://{api_host}/5uf_api/client_online.php?{params}"

with urllib.request.urlopen(url, timeout=10) as response:
    body = response.read().decode("utf-8", errors="ignore")
    breakdown = ",".join(
        f"{protocol}:{len(protocol_users)}"
        for protocol, protocol_users in sorted(protocol_counts.items())
    )
    print(
        f"server={server} online={online} protocols={breakdown or 'none'} "
        f"http={response.status} body={body[:120]}"
    )
PY
