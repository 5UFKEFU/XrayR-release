#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="${AOBAI_REPO_RAW:-https://raw.githubusercontent.com/5UFKEFU/XrayR-release/master/aobai-node}"
ARCHIVE_VERSION="20260724-2"
ARCHIVE_URL="${AOBAI_ARCHIVE_URL:-$REPO_RAW/aobai-node-linux-amd64.tar.gz?v=$ARCHIVE_VERSION}"
PANEL_URL="${PANEL_URL:-https://www.5ufkefu.com}"
MU_KEY="${MU_KEY:-5uf5uf}"
INSTALL_ROOT="${INSTALL_ROOT:-}"
CERT_MODE="${CERT_MODE:-letsencrypt}"
LE_EMAIL="${LE_EMAIL:-}"
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
  --panel-url URL       面板地址，默认 https://www.5ufkefu.com
  --mu-key KEY          SSPanel mu_key，默认读取 MU_KEY，未设置时为 5uf5uf
  --install-root DIR    安装目录，默认 /home/<sudo调用者>/aobai-node
  --cert-mode MODE      letsencrypt 或 existing
  --email EMAIL         Let's Encrypt 邮箱
  --prepare-only        只下载、解压和校验，不生成配置、不启动
EOF
}

[[ $# -ge 4 ]] || { usage; exit 2; }
DOMAIN="$1"; PROTOCOLS="$2"; PORTS="$3"; NODE_IDS="$4"; shift 4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel-url) PANEL_URL="${2:?}"; shift 2 ;;
    --mu-key) MU_KEY="${2:?}"; shift 2 ;;
    --install-root) INSTALL_ROOT="${2:?}"; shift 2 ;;
    --cert-mode) CERT_MODE="${2:?}"; shift 2 ;;
    --email) LE_EMAIL="${2:?}"; shift 2 ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$DOMAIN" "$PROTOCOLS" "$PORTS" "$NODE_IDS" \
    --panel-url "$PANEL_URL" --mu-key "$MU_KEY" \
    ${INSTALL_ROOT:+--install-root "$INSTALL_ROOT"} \
    --cert-mode "$CERT_MODE" ${LE_EMAIL:+--email "$LE_EMAIL"} \
    $([[ "$PREPARE_ONLY" == 1 ]] && echo --prepare-only)
fi

RUN_USER="${SUDO_USER:-jeff}"
[[ "$RUN_USER" != root ]] || RUN_USER="${AOBAI_RUN_USER:-jeff}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
INSTALL_ROOT="${INSTALL_ROOT:-$RUN_HOME/aobai-node}"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl jq nginx certbot openssl python3 liblua5.4-0 >/dev/null

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
curl -fL --retry 3 --connect-timeout 20 "$ARCHIVE_URL" -o "$tmp_dir/release.tar.gz"
mkdir -p "$INSTALL_ROOT"
tar -xzf "$tmp_dir/release.tar.gz" -C "$INSTALL_ROOT"
chown -R "$RUN_USER:$RUN_USER" "$INSTALL_ROOT"

for binary in sbox-server-embedded redis-server-embedded redis-cli-embedded speedtestd haproxy; do
  [[ -x "$INSTALL_ROOT/bin/$binary" ]] || {
    echo "发布包缺少 bin/$binary" >&2
    exit 1
  }
done

if [[ "$PREPARE_ONLY" == 1 ]]; then
  echo "准备完成: $INSTALL_ROOT"
  exit 0
fi

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org)"
MONITOR_IP="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
CERT_DIR="$INSTALL_ROOT/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

needs_certificate=0
IFS=',' read -ra protocol_list <<<"$PROTOCOLS"
for protocol in "${protocol_list[@]}"; do
  case "${protocol,,}" in
    anytls|cdn|naive|http2|https-connect|hysteria2|hy2) needs_certificate=1 ;;
  esac
done
if [[ "$needs_certificate" == 1 ]]; then
  if [[ "$CERT_MODE" == "letsencrypt" ]]; then
    systemctl stop nginx 2>/dev/null || true
    cert_args=(certonly --standalone --non-interactive --agree-tos -d "$DOMAIN")
    if [[ -n "$LE_EMAIL" ]]; then
      cert_args+=(--email "$LE_EMAIL")
    else
      cert_args+=(--register-unsafely-without-email)
    fi
    certbot "${cert_args[@]}"
    cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
    cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
  else
    [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || {
      echo "existing 模式需要 $CERT_DIR/fullchain.pem 和 privkey.pem" >&2
      exit 1
    }
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
protected-mode yes
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
  install -m 0644 "$INSTALL_ROOT/generated/nginx-$DOMAIN.conf" \
    "/etc/nginx/sites-available/aobai-$DOMAIN"
  ln -sfn "/etc/nginx/sites-available/aobai-$DOMAIN" \
    "/etc/nginx/sites-enabled/aobai-$DOMAIN"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
fi

systemctl daemon-reload
systemctl enable --now aobai-node-redis aobai-node-speedtestd
systemctl restart aobai-node-sbox
systemctl enable aobai-node-sbox
sleep 8
systemctl --no-pager --full status aobai-node-sbox | sed -n '1,12p'
echo "部署完成: $INSTALL_ROOT"
echo "公网 IP: $PUBLIC_IP"
echo "检查: systemctl status aobai-node-{redis,speedtestd,sbox}"
