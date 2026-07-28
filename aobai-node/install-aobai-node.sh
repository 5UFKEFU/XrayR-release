#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="${AOBAI_REPO_RAW:-https://raw.githubusercontent.com/5UFKEFU/XrayR-release/master/aobai-node}"
ARCHIVE_REVISION="9ebce20"
ARCHIVE_URL="${AOBAI_ARCHIVE_URL:-https://raw.githubusercontent.com/5UFKEFU/XrayR-release/$ARCHIVE_REVISION/aobai-node/aobai-node-linux-amd64.tar.gz}"
PANEL_URL="${PANEL_URL:-https://www.5ufkefu.com}"
MU_KEY="${MU_KEY:-5uf5uf}"
INSTALL_ROOT="${INSTALL_ROOT:-}"
CERT_MODE="${CERT_MODE:-letsencrypt}"
LE_EMAIL="${LE_EMAIL:-}"
CLOUDFLARE_TOKEN="${CLOUDFLARE_TOKEN:-}"
PREPARE_ONLY=0

usage() {
  cat <<'EOF'
用法:
  bash install-aobai-node.sh 域名 协议 端口 节点ID [选项]

单协议:
  bash install-aobai-node.sh fr2.example.com vless 38573 196

同机多协议（四组参数顺序必须一致）:
  bash install-aobai-node.sh fr2.example.com \
    anytls,vless,cdn,naive,http2,hysteria2 \
    38553,38573,443,38574,55584,38590 \
    182,196,197,198,182,195

协议: anytls, vless, cdn, naive, http2, hysteria2

选项:
  --remove-service P    从已有部署移除一个协议或端口，例如：
                        bash install-aobai-node.sh sg1.example.com --remove-service anytls
                        bash install-aobai-node.sh sg1.example.com --remove-service 443
  --panel-url URL       面板地址，默认 https://www.5ufkefu.com
  --mu-key KEY          SSPanel mu_key，默认读取 MU_KEY，未设置时为 5uf5uf
  --install-root DIR    安装目录，默认 /home/<sudo调用者>/aobai-node
  --cert-mode MODE      letsencrypt、cloudflare 或 existing
  --cloudflare-token T  Cloudflare API Token（直接写入用户 crontab 命令）
  --email EMAIL         Let's Encrypt 邮箱
  --prepare-only        只下载、解压和校验，不生成配置、不启动

Cloudflare DNS-01 示例（域名无需预先解析，80端口无需开放）:
  bash install-aobai-node.sh ... \
    --cert-mode cloudflare \
    --cloudflare-token 'Cloudflare_API_Token'

注意：直接传 Token 可能保存在 shell history；建议部署后清理对应历史记录。
EOF
}

if [[ $# -ge 3 && "$2" == "--remove-service" ]]; then
  DOMAIN="$1"
  REMOVE_SERVICE="$3"
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-root) INSTALL_ROOT="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "移除模式不支持参数: $1" >&2; exit 2 ;;
    esac
  done
  if [[ "${EUID}" -ne 0 ]]; then
    remove_args=("$DOMAIN" --remove-service "$REMOVE_SERVICE")
    [[ -n "$INSTALL_ROOT" ]] && remove_args+=(--install-root "$INSTALL_ROOT")
    exec sudo -E env AOBAI_RUN_USER="${USER}" bash "$0" "${remove_args[@]}"
  fi
  RUN_USER="${AOBAI_RUN_USER:-${SUDO_USER:-jeff}}"
  [[ "$RUN_USER" != root ]] || RUN_USER="${AOBAI_RUN_USER:-jeff}"
  RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  INSTALL_ROOT="${INSTALL_ROOT:-$RUN_HOME/aobai-node}"
  state_file="$INSTALL_ROOT/etc/deployment.json"
  [[ -s "$state_file" ]] || {
    echo "找不到部署状态 $state_file；请先用新版安装脚本完整部署一次。" >&2
    exit 1
  }
  mapfile -t kept_rows < <(
    jq -r --arg target "${REMOVE_SERVICE,,}" '
      [range(0; (.protocols | length)) as $i |
       {protocol: .protocols[$i], port: .ports[$i], node_id: .node_ids[$i]} |
       select((.protocol | ascii_downcase) != $target and (.port | tostring) != $target)] |
      .[] | [.protocol, (.port | tostring), (.node_id | tostring)] | @tsv
    ' "$state_file"
  )
  [[ "${#kept_rows[@]}" -gt 0 ]] || {
    echo "不能移除最后一个服务；如需卸载整套节点请使用专用卸载流程。" >&2
    exit 1
  }
  before_count="$(jq '.protocols | length' "$state_file")"
  [[ "${#kept_rows[@]}" -lt "$before_count" ]] || {
    echo "当前部署中找不到协议或端口: $REMOVE_SERVICE" >&2
    exit 1
  }
  protocols=""; ports=""; node_ids=""
  for row in "${kept_rows[@]}"; do
    IFS=$'\t' read -r protocol port node_id <<<"$row"
    protocols+="${protocols:+,}$protocol"
    ports+="${ports:+,}$port"
    node_ids+="${node_ids:+,}$node_id"
  done
  panel_url="$(jq -r '.panel_url' "$state_file")"
  mu_key="$(jq -r '.mu_key' "$state_file")"
  echo "移除 $REMOVE_SERVICE；保留: $protocols / $ports / $node_ids"
  exec bash "$0" "$DOMAIN" "$protocols" "$ports" "$node_ids" \
    --panel-url "$panel_url" --mu-key "$mu_key" \
    --install-root "$INSTALL_ROOT" --cert-mode existing
fi

[[ $# -ge 4 ]] || { usage; exit 2; }
DOMAIN="$1"; PROTOCOLS="$2"; PORTS="$3"; NODE_IDS="$4"; shift 4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel-url) PANEL_URL="${2:?}"; shift 2 ;;
    --mu-key) MU_KEY="${2:?}"; shift 2 ;;
    --install-root) INSTALL_ROOT="${2:?}"; shift 2 ;;
    --cert-mode) CERT_MODE="${2:?}"; shift 2 ;;
    --cloudflare-token) CLOUDFLARE_TOKEN="${2:?}"; shift 2 ;;
    --email) LE_EMAIL="${2:?}"; shift 2 ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  sudo_args=("$DOMAIN" "$PROTOCOLS" "$PORTS" "$NODE_IDS"
    --panel-url "$PANEL_URL" --mu-key "$MU_KEY" --cert-mode "$CERT_MODE")
  [[ -n "$INSTALL_ROOT" ]] && sudo_args+=(--install-root "$INSTALL_ROOT")
  [[ -n "$LE_EMAIL" ]] && sudo_args+=(--email "$LE_EMAIL")
  [[ -n "$CLOUDFLARE_TOKEN" ]] && sudo_args+=(--cloudflare-token "$CLOUDFLARE_TOKEN")
  [[ "$PREPARE_ONLY" == 1 ]] && sudo_args+=(--prepare-only)
  exec sudo -E bash "$0" "${sudo_args[@]}"
fi

RUN_USER="${AOBAI_RUN_USER:-${SUDO_USER:-jeff}}"
[[ "$RUN_USER" != root ]] || RUN_USER="${AOBAI_RUN_USER:-jeff}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
INSTALL_ROOT="${INSTALL_ROOT:-$RUN_HOME/aobai-node}"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl jq nginx certbot python3-certbot-dns-cloudflare \
  cron openssl python3 liblua5.4-0 haproxy >/dev/null

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"; rm -f /run/aobai-node-cloudflare.ini' EXIT
curl -fL --retry 3 --connect-timeout 20 "$ARCHIVE_URL" -o "$tmp_dir/release.tar.gz"
mkdir -p "$INSTALL_ROOT"
tar -xzf "$tmp_dir/release.tar.gz" -C "$INSTALL_ROOT"
# Keep deployment logic independently updatable from the large pinned binary
# archive. This lets installer fixes ship without rebuilding all binaries.
curl -fL --retry 3 --connect-timeout 20 \
  "$REPO_RAW/configure.py" -o "$INSTALL_ROOT/tools/configure.py"
curl -fL --retry 3 --connect-timeout 20 \
  "$REPO_RAW/report_online_real.sh" \
  -o "$INSTALL_ROOT/tools/report_online_real.sh"
curl -fL --retry 3 --connect-timeout 20 \
  "${AOBAI_EGRESS_URL:-$REPO_RAW/tier1-egress.json}" \
  -o "$INSTALL_ROOT/etc/sbox/tier1-egress.json"
chown -R "$RUN_USER:$RUN_USER" "$INSTALL_ROOT"

for binary in sbox-server-embedded redis-server-embedded redis-cli-embedded speedtestd haproxy; do
  [[ -x "$INSTALL_ROOT/bin/$binary" ]] || {
    echo "发布包缺少 bin/$binary" >&2
    exit 1
  }
done

# The release HAProxy is built on a recent Ubuntu. Older supported hosts may
# have an older glibc, so use the distro HAProxy when the bundled one cannot
# start on the target host.
if ! "$INSTALL_ROOT/bin/haproxy" -vv >/dev/null 2>&1; then
  install -m 0755 /usr/sbin/haproxy "$INSTALL_ROOT/bin/haproxy"
  chown "$RUN_USER:$RUN_USER" "$INSTALL_ROOT/bin/haproxy"
fi

if [[ "$PREPARE_ONLY" == 1 ]]; then
  echo "准备完成: $INSTALL_ROOT"
  exit 0
fi

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org)"
MONITOR_IP="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
SERVER_CITY="Server"
SERVER_COUNTRY="Unknown"
SERVER_COUNTRY_CODE=""
SERVER_LATITUDE="0"
SERVER_LONGITUDE="0"
SERVER_TIMEZONE="UTC"
geo_json="$(curl -4 -fsS --retry 2 --max-time 15 "https://ipwho.is/$PUBLIC_IP" || true)"
if jq -e '.success == true' >/dev/null 2>&1 <<<"$geo_json"; then
  SERVER_CITY="$(jq -r '.city // "Server"' <<<"$geo_json")"
  SERVER_COUNTRY="$(jq -r '.country // "Unknown"' <<<"$geo_json")"
  SERVER_COUNTRY_CODE="$(jq -r '.country_code // ""' <<<"$geo_json")"
  SERVER_LATITUDE="$(jq -r '.latitude // 0' <<<"$geo_json")"
  SERVER_LONGITUDE="$(jq -r '.longitude // 0' <<<"$geo_json")"
  SERVER_TIMEZONE="$(jq -r '.timezone.id // "UTC"' <<<"$geo_json")"
else
  echo "警告：无法查询公网 IP 地理位置，测速页将显示通用服务端位置。" >&2
fi
case "$SERVER_COUNTRY_CODE" in
  SG) SERVER_CITY_ZH="新加坡"; SERVER_COUNTRY_ZH="新加坡" ;;
  HK) SERVER_CITY_ZH="香港"; SERVER_COUNTRY_ZH="香港" ;;
  FR) SERVER_CITY_ZH="$SERVER_CITY"; SERVER_COUNTRY_ZH="法国" ;;
  GB) SERVER_CITY_ZH="$SERVER_CITY"; SERVER_COUNTRY_ZH="英国" ;;
  DE) SERVER_CITY_ZH="$SERVER_CITY"; SERVER_COUNTRY_ZH="德国" ;;
  JP) SERVER_CITY_ZH="$SERVER_CITY"; SERVER_COUNTRY_ZH="日本" ;;
  US) SERVER_CITY_ZH="$SERVER_CITY"; SERVER_COUNTRY_ZH="美国" ;;
  *) SERVER_CITY_ZH="$SERVER_CITY"; SERVER_COUNTRY_ZH="$SERVER_COUNTRY" ;;
esac
CERT_DIR="$INSTALL_ROOT/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

needs_certificate=0
IFS=',' read -ra protocol_list <<<"$PROTOCOLS"
IFS=',' read -ra port_list <<<"$PORTS"
http2_uses_port80=0
for i in "${!protocol_list[@]}"; do
  case "${protocol_list[$i],,}:${port_list[$i]:-}" in
    http2:80|https-connect:80) http2_uses_port80=1 ;;
  esac
done
for protocol in "${protocol_list[@]}"; do
  case "${protocol,,}" in
    anytls|cdn|naive|http2|https-connect|hysteria2|hy2) needs_certificate=1 ;;
  esac
done
if [[ "$needs_certificate" == 1 ]]; then
  if [[ "$CERT_MODE" == "letsencrypt" ]]; then
    domain_ips="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)"
    if ! grep -Fxq "$PUBLIC_IP" <<<"$domain_ips"; then
      echo "域名 $DOMAIN 尚未解析到本机公网 IP $PUBLIC_IP" >&2
      echo "当前 IPv4 解析: ${domain_ips:-无}" >&2
      echo "请先创建 DNS-only A 记录，等待解析生效后重新运行脚本。" >&2
      exit 1
    fi

    nginx_was_active=0
    if systemctl is-active --quiet nginx; then
      nginx_was_active=1
      systemctl stop nginx
    fi
    if ss -H -ltn 'sport = :80' | grep -q .; then
      [[ "$nginx_was_active" == 1 ]] && systemctl start nginx
      echo "80 端口仍被其他程序占用，无法完成 Let's Encrypt HTTP-01 验证：" >&2
      ss -ltnp 'sport = :80' >&2 || true
      exit 1
    fi

    cert_args=(certonly --standalone --non-interactive --agree-tos -d "$DOMAIN")
    renewal_config="/etc/letsencrypt/renewal/$DOMAIN.conf"
    if [[ -f "$renewal_config" ]] &&
       ! grep -Eq '^authenticator *= *standalone$' "$renewal_config"; then
      echo "检测到证书验证方式发生变化，将重新签发一次以切换到 HTTP-01。"
      cert_args+=(--force-renewal)
    fi
    if [[ -n "$LE_EMAIL" ]]; then
      cert_args+=(--email "$LE_EMAIL")
    else
      cert_args+=(--register-unsafely-without-email)
    fi
    if ! certbot "${cert_args[@]}"; then
      [[ "$nginx_was_active" == 1 ]] && systemctl start nginx
      echo "Let's Encrypt 证书申请失败；nginx 已恢复到申请前状态。" >&2
      exit 1
    fi
    cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
    cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
    [[ "$nginx_was_active" == 1 ]] && systemctl start nginx
  elif [[ "$CERT_MODE" == "cloudflare" ]]; then
    [[ -n "$CLOUDFLARE_TOKEN" ]] || {
      echo "cloudflare 模式必须提供 --cloudflare-token" >&2
      exit 2
    }
    # 从 HTTP-01 迁移时，先移除旧的停启 Nginx hook，确保 DNS-01 全程不停机。
    rm -f \
      /etc/letsencrypt/renewal-hooks/pre/aobai-node-stop-nginx \
      /etc/letsencrypt/renewal-hooks/post/aobai-node-start-nginx
    [[ "$CLOUDFLARE_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || {
      echo "Cloudflare Token 包含不支持的字符" >&2
      exit 2
    }
    CLOUDFLARE_CREDENTIALS="/run/aobai-node-cloudflare.ini"
    printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_TOKEN" \
      >"$CLOUDFLARE_CREDENTIALS"
    chmod 0600 "$CLOUDFLARE_CREDENTIALS"
    cert_args=(certonly --dns-cloudflare
      --dns-cloudflare-credentials "$CLOUDFLARE_CREDENTIALS"
      --dns-cloudflare-propagation-seconds 30
      --non-interactive --agree-tos -d "$DOMAIN")
    renewal_config="/etc/letsencrypt/renewal/$DOMAIN.conf"
    if [[ -f "$renewal_config" ]] &&
       ! grep -Eq '^authenticator *= *dns-cloudflare$' "$renewal_config"; then
      echo "检测到证书验证方式发生变化，将重新签发一次以切换到 Cloudflare DNS-01。"
      cert_args+=(--force-renewal)
    fi
    if [[ -n "$LE_EMAIL" ]]; then
      cert_args+=(--email "$LE_EMAIL")
    else
      cert_args+=(--register-unsafely-without-email)
    fi
    certbot "${cert_args[@]}"
    cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
    cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
  elif [[ "$CERT_MODE" == "existing" ]]; then
    [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || {
      echo "existing 模式需要 $CERT_DIR/fullchain.pem 和 privkey.pem" >&2
      exit 1
    }
  else
    echo "未知 cert-mode: $CERT_MODE（支持 letsencrypt、cloudflare、existing）" >&2
    exit 2
  fi
  chown -R "$RUN_USER:$RUN_USER" "$CERT_DIR"
  chmod 0750 "$CERT_DIR"
  chmod 0640 "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem"
fi

python3 "$INSTALL_ROOT/tools/configure.py" \
  --root "$INSTALL_ROOT" --domain "$DOMAIN" \
  --protocols "$PROTOCOLS" --ports "$PORTS" --node-ids "$NODE_IDS" \
  --panel-url "$PANEL_URL" --mu-key "$MU_KEY" \
  --bind-ip "$PUBLIC_IP" --monitor-ip "$MONITOR_IP"

cat >"$INSTALL_ROOT/env/aobai-node.env" <<EOF
AOBAI_ROOT=$INSTALL_ROOT
PUBLIC_BIND_IP=0.0.0.0
AOBAI_BIND_IP=0.0.0.0
MONITOR_BIND_IP=$MONITOR_IP
AOBAI_REDIS_PORT=6382
MULTI_SPEEDTEST_PORT=18771
MULTI_MONITOR_PORT=28910
MULTI_SSM_PORT=28912
NODE_TLS_HOST=$DOMAIN
CDN_XHTTP_HOST=$DOMAIN
HTTPS_CONNECT_DIRECT_HOST=$DOMAIN
EOF
chown "$RUN_USER:$RUN_USER" "$INSTALL_ROOT/env/aobai-node.env"

cat >"$INSTALL_ROOT/etc/redis/redis.conf" <<EOF
bind 127.0.0.1
port 6382
# This instance is strictly loopback-only. Some older fleet images incorrectly
# classify loopback clients under Redis protected mode, so disable that second
# guard while retaining the explicit 127.0.0.1 bind.
protected-mode no
daemonize no
databases 32
dir $INSTALL_ROOT/var/redis/data
pidfile $INSTALL_ROOT/var/redis/redis.pid
appendonly no
EOF
mkdir -p "$INSTALL_ROOT/var/redis/data" "$INSTALL_ROOT/log/sbox-server"
chown -R "$RUN_USER:$RUN_USER" "$INSTALL_ROOT/var" "$INSTALL_ROOT/log"

cat >/etc/systemd/system/aobai-node-redis.service <<EOF
[Unit]
Description=AoBai Node Redis
After=network-online.target
[Service]
User=$RUN_USER
WorkingDirectory=$INSTALL_ROOT
ExecStart=$INSTALL_ROOT/bin/redis-server-embedded $INSTALL_ROOT/etc/redis/redis.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/aobai-node-speedtestd.service <<EOF
[Unit]
Description=AoBai Node Speedtest
After=network-online.target
[Service]
User=$RUN_USER
Environment=SPEEDTESTD_ADDR=127.0.0.1:18771
Environment="SPEEDTESTD_SERVER_LABEL=$SERVER_CITY · Speedtest node"
Environment="SPEEDTESTD_SERVER_CITY=$SERVER_CITY"
Environment="SPEEDTESTD_SERVER_CITY_EN=$SERVER_CITY"
Environment="SPEEDTESTD_SERVER_CITY_ZH=$SERVER_CITY_ZH"
Environment="SPEEDTESTD_SERVER_COUNTRY=$SERVER_COUNTRY"
Environment="SPEEDTESTD_SERVER_COUNTRY_EN=$SERVER_COUNTRY"
Environment="SPEEDTESTD_SERVER_COUNTRY_ZH=$SERVER_COUNTRY_ZH"
Environment="SPEEDTESTD_SERVER_COUNTRY_CODE=$SERVER_COUNTRY_CODE"
Environment="SPEEDTESTD_SERVER_LATITUDE=$SERVER_LATITUDE"
Environment="SPEEDTESTD_SERVER_LONGITUDE=$SERVER_LONGITUDE"
Environment="SPEEDTESTD_SERVER_TIMEZONE=$SERVER_TIMEZONE"
Environment="SPEEDTESTD_SERVER_HOST=$DOMAIN"
WorkingDirectory=$INSTALL_ROOT
ExecStart=$INSTALL_ROOT/bin/speedtestd
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/aobai-node-sbox.service <<EOF
[Unit]
Description=AoBai Node SBox
After=network-online.target aobai-node-redis.service aobai-node-speedtestd.service
Requires=aobai-node-redis.service
[Service]
User=$RUN_USER
Environment=HOME=$RUN_HOME
Environment=AOBAI_ROOT=$INSTALL_ROOT
EnvironmentFile=$INSTALL_ROOT/env/aobai-node.env
WorkingDirectory=$INSTALL_ROOT
ExecStart=$INSTALL_ROOT/bin/sbox-server-embedded -c $INSTALL_ROOT/etc/sbox/config.yaml
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF

if [[ -f "$INSTALL_ROOT/generated/nginx-$DOMAIN.conf" ]]; then
  if [[ "$http2_uses_port80" == 1 ]]; then
    # Port 80 is a valid TLS port for HTTPS-CONNECT on networks that filter
    # arbitrary high ports. Remove the generated HTTP-to-HTTPS redirect so
    # HAProxy can own port 80 while CDN remains on 443.
    python3 - "$INSTALL_ROOT/generated/nginx-$DOMAIN.conf" <<'PY'
import re
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()
result = re.sub(
    r"\Aserver \{\n\s+listen 80;\n\s+listen \[::\]:80;.*?\n\}\n\n",
    "",
    source,
    count=1,
    flags=re.S,
)
if result == source:
    raise SystemExit(f"expected nginx port-80 redirect block not found: {path}")
open(path, "w", encoding="utf-8").write(result)
PY
    if [[ -f /etc/nginx/conf.d/default.conf ]] &&
       grep -Eq 'listen[[:space:]]+80([[:space:];]|$)' /etc/nginx/conf.d/default.conf; then
      mv /etc/nginx/conf.d/default.conf \
        /etc/nginx/conf.d/default.conf.disabled-aobai
    fi
  fi
  speedtest_web_root="/var/www/aobai-speedtest-$DOMAIN"
  install -d -m 0755 "$speedtest_web_root"
  cp -a "$INSTALL_ROOT/opt/www/vhost/speedtest/." "$speedtest_web_root/"
  chown -R root:root "$speedtest_web_root"
  chmod -R a+rX "$speedtest_web_root"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  install -m 0644 "$INSTALL_ROOT/generated/nginx-$DOMAIN.conf" \
    "/etc/nginx/sites-available/aobai-$DOMAIN"
  ln -sfn "/etc/nginx/sites-available/aobai-$DOMAIN" \
    "/etc/nginx/sites-enabled/aobai-$DOMAIN"
  # Debian/Ubuntu nginx includes sites-enabled. Official nginx.org packages
  # include only conf.d, so make the same vhost visible there when necessary.
  # Do not use grep -q here: with pipefail it closes the pipe early and nginx's
  # SIGPIPE makes an included sites-enabled tree look absent.
  if nginx -T 2>&1 | grep -F "/etc/nginx/sites-enabled/" >/dev/null; then
    rm -f "/etc/nginx/conf.d/aobai-$DOMAIN.conf"
  else
    ln -sfn "/etc/nginx/sites-available/aobai-$DOMAIN" \
      "/etc/nginx/conf.d/aobai-$DOMAIN.conf"
  fi
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
else
  rm -f \
    "/etc/nginx/sites-enabled/aobai-$DOMAIN" \
    "/etc/nginx/sites-available/aobai-$DOMAIN" \
    "/etc/nginx/conf.d/aobai-$DOMAIN.conf"
  nginx -t
  systemctl is-active --quiet nginx && systemctl reload nginx
fi

systemctl daemon-reload
systemctl enable --now aobai-node-redis aobai-node-speedtestd
systemctl restart aobai-node-redis aobai-node-speedtestd
systemctl restart aobai-node-sbox
systemctl enable aobai-node-sbox

if [[ "$needs_certificate" == 1 && "$CERT_MODE" != "existing" ]]; then
  install -d -m 0755 \
    /etc/letsencrypt/renewal-hooks/pre \
    /etc/letsencrypt/renewal-hooks/deploy \
    /etc/letsencrypt/renewal-hooks/post
  if [[ "$CERT_MODE" == "letsencrypt" ]]; then
    cat >/etc/letsencrypt/renewal-hooks/pre/aobai-node-stop-nginx <<'EOF'
#!/usr/bin/env bash
systemctl stop nginx
EOF
    cat >/etc/letsencrypt/renewal-hooks/post/aobai-node-start-nginx <<'EOF'
#!/usr/bin/env bash
systemctl start nginx
EOF
    chmod 0755 \
      /etc/letsencrypt/renewal-hooks/pre/aobai-node-stop-nginx \
      /etc/letsencrypt/renewal-hooks/post/aobai-node-start-nginx
  else
    rm -f \
      /etc/letsencrypt/renewal-hooks/pre/aobai-node-stop-nginx \
      /etc/letsencrypt/renewal-hooks/post/aobai-node-start-nginx
  fi
  cat >"/etc/letsencrypt/renewal-hooks/deploy/aobai-node-$DOMAIN" <<EOF
#!/usr/bin/env bash
set -e
cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
chown -R "$RUN_USER:$RUN_USER" "$CERT_DIR"
chmod 0750 "$CERT_DIR"
chmod 0640 "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem"
systemctl is-active --quiet nginx && systemctl reload nginx
systemctl restart aobai-node-sbox
EOF
  chmod 0755 "/etc/letsencrypt/renewal-hooks/deploy/aobai-node-$DOMAIN"

  cat >/usr/local/sbin/aobai-cert-renew <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
credentials=/run/aobai-node-cloudflare.ini
cloudflare_token="${1:-}"
[[ $# -gt 0 ]] && shift
cleanup() {
  rm -f "$credentials"
}
trap cleanup EXIT
if [[ -n "$cloudflare_token" ]]; then
  umask 077
  printf 'dns_cloudflare_api_token = %s\n' "$cloudflare_token" >"$credentials"
  certbot renew --quiet --no-random-sleep-on-renew \
    --dns-cloudflare-credentials "$credentials" "$@"
else
  certbot renew --quiet --no-random-sleep-on-renew "$@"
fi
EOF
  chmod 0755 /usr/local/sbin/aobai-cert-renew

  if [[ "$CERT_MODE" == "cloudflare" ]]; then
    cron_command="17 3 * * 1 sudo -n /usr/local/sbin/aobai-cert-renew '$CLOUDFLARE_TOKEN' # aobai-node-cert-renew"
  else
    cron_command="17 3 * * 1 sudo -n /usr/local/sbin/aobai-cert-renew # aobai-node-cert-renew"
  fi
  {
    crontab -u "$RUN_USER" -l 2>/dev/null |
      grep -v 'aobai-node-cert-renew' || true
    echo "$cron_command"
  } | crontab -u "$RUN_USER" -

  rm -f /etc/cron.d/aobai-node-cert-renew
  rm -f /etc/letsencrypt/credentials/aobai-node-cloudflare.ini
  systemctl enable --now cron
  systemctl disable --now certbot.timer 2>/dev/null || true
fi

[[ -f "$INSTALL_ROOT/tools/report_online_real.sh" ]] || {
  echo "发布包缺少 tools/report_online_real.sh" >&2
  exit 1
}
chmod 0755 "$INSTALL_ROOT/tools/report_online_real.sh"
chown root:root "$INSTALL_ROOT/tools/report_online_real.sh"
online_cron="* * * * * sudo -n $INSTALL_ROOT/tools/report_online_real.sh >> /tmp/report_online_real.log 2>&1 # aobai-online-report"
{
  crontab -u "$RUN_USER" -l 2>/dev/null |
    grep -Ev 'aobai-online-report|report_online_real\.sh' || true
  echo "$online_cron"
} | crontab -u "$RUN_USER" -

# 旧部署可能从 root 调用旧版统计脚本；迁移后只保留运行用户这一份。
root_cron="$(crontab -u root -l 2>/dev/null || true)"
if grep -Eq 'report_online_real\.sh|report_xray_online\.py' <<<"$root_cron"; then
  grep -Ev 'report_online_real\.sh|report_xray_online\.py' <<<"$root_cron" | crontab -u root -
fi

sleep 8
systemctl --no-pager --full status aobai-node-sbox | sed -n '1,12p'
echo "部署完成: $INSTALL_ROOT"
echo "公网 IP: $PUBLIC_IP"
echo "检查: systemctl status aobai-node-{redis,speedtestd,sbox}"
