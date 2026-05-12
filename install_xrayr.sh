#!/usr/bin/env bash
set -euo pipefail

XRAYR_VERSION="${XRAYR_VERSION:-v0.9.4}"
XRAYR_REPO="${XRAYR_REPO:-XrayR-project/XrayR}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/XrayR}"
CONFIG_DIR="${CONFIG_DIR:-/etc/XrayR}"
SERVICE_NAME="${SERVICE_NAME:-XrayR}"
START_SERVICE="${START_SERVICE:-auto}"
ENABLE_SERVICE="${ENABLE_SERVICE:-1}"

PANEL_TYPE="${PANEL_TYPE:-}"
API_HOST="${API_HOST:-}"
API_KEY="${API_KEY:-}"
NODE_ID="${NODE_ID:-}"
NODE_TYPE="${NODE_TYPE:-V2ray}"
LISTEN_IP="${LISTEN_IP:-0.0.0.0}"
SEND_IP="${SEND_IP:-0.0.0.0}"
CERT_MODE="${CERT_MODE:-none}"
CERT_DOMAIN="${CERT_DOMAIN:-}"
LOG_LEVEL="${LOG_LEVEL:-warning}"

usage() {
  cat <<'EOF'
Usage:
  bash install_xrayr.sh [options]

Options:
  --version <tag>       XrayR version tag, default: v0.9.4
  --repo <owner/repo>   GitHub repo, default: XrayR-project/XrayR
  --start              Start service after install, even if config is unchanged
  --no-start           Do not start service after install
  --no-enable          Do not enable service at boot
  -h, --help           Show help

Optional environment variables for one-command panel config:
  PANEL_TYPE           SSpanel, NewV2board, PMpanel, Proxypanel, V2RaySocks, GoV2Panel, BunPanel
  API_HOST             Panel API URL, for example: https://panel.example.com
  API_KEY              Panel node key/token
  NODE_ID              Panel node ID
  NODE_TYPE            V2ray, Vmess, Vless, Shadowsocks, Trojan, Shadowsocks-Plugin. Default: V2ray
  CERT_MODE            none, file, http, tls, dns. Default: none
  CERT_DOMAIN          Certificate domain, optional
  XRAYR_VERSION        Same as --version
  XRAYR_REPO           Same as --repo

Examples:
  bash install_xrayr.sh

  PANEL_TYPE=NewV2board API_HOST=https://panel.example.com API_KEY=xxx NODE_ID=1 \
    NODE_TYPE=V2ray bash install_xrayr.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      XRAYR_VERSION="${2:?missing version}"
      shift 2
      ;;
    --repo)
      XRAYR_REPO="${2:?missing repo}"
      shift 2
      ;;
    --start)
      START_SERVICE="1"
      shift
      ;;
    --no-start)
      START_SERVICE="0"
      shift
      ;;
    --no-enable)
      ENABLE_SERVICE="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

log() {
  printf '\033[1;32m[install-xrayr]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[install-xrayr]\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"
  else
    OS_ID=""
  fi
}

install_deps() {
  detect_os
  case "${OS_ID}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y ca-certificates curl wget unzip tar socat
      ;;
    centos|rhel|rocky|almalinux|fedora)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl wget unzip tar socat
      else
        yum install -y ca-certificates curl wget unzip tar socat
      fi
      ;;
    *)
      log "Unknown OS '${OS_ID:-unknown}', skipping package install."
      ;;
  esac

  require_cmd curl
  require_cmd unzip
  require_cmd systemctl
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    armv7l) echo "arm32-v7a" ;;
    armv6l) echo "arm32-v6" ;;
    armv5l) echo "arm32-v5" ;;
    s390x) echo "s390x" ;;
    ppc64le) echo "ppc64le" ;;
    riscv64) echo "riscv64" ;;
    mips) echo "mips32" ;;
    mipsle) echo "mips32le" ;;
    mips64) echo "mips64" ;;
    mips64le) echo "mips64le" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

download_and_install() {
  local arch asset base_url tmpdir
  arch="$(detect_arch)"
  asset="XrayR-linux-${arch}.zip"
  base_url="https://github.com/${XRAYR_REPO}/releases/download/${XRAYR_VERSION}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  log "Downloading ${XRAYR_REPO} ${XRAYR_VERSION} (${asset})"
  curl -fL --retry 3 --connect-timeout 20 -o "${tmpdir}/${asset}" "${base_url}/${asset}"

  if curl -fsSL --retry 3 --connect-timeout 20 -o "${tmpdir}/${asset}.dgst" "${base_url}/${asset}.dgst"; then
    local expected actual
    expected="$(awk -F'= ' '/SHA2-256/{print $2}' "${tmpdir}/${asset}.dgst" | tr -d '[:space:]')"
    actual="$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')"
    [[ -z "${expected}" || "${expected}" == "${actual}" ]] || die "SHA256 mismatch for ${asset}"
    log "SHA256 verified: ${actual}"
  else
    log "Digest file not found; continuing without release digest verification."
  fi

  rm -rf "${INSTALL_DIR}.new"
  mkdir -p "${INSTALL_DIR}.new" "${CONFIG_DIR}"
  unzip -oq "${tmpdir}/${asset}" -d "${INSTALL_DIR}.new"
  chmod 755 "${INSTALL_DIR}.new/XrayR"

  if [[ -d "${INSTALL_DIR}" ]]; then
    local backup="${INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    mv "${INSTALL_DIR}" "${backup}"
    log "Previous install moved to ${backup}"
  fi
  mv "${INSTALL_DIR}.new" "${INSTALL_DIR}"

  cp -n "${INSTALL_DIR}/config.yml" "${CONFIG_DIR}/config.yml"
  for file in dns.json route.json custom_inbound.json custom_outbound.json rulelist; do
    [[ -f "${INSTALL_DIR}/${file}" ]] && cp -n "${INSTALL_DIR}/${file}" "${CONFIG_DIR}/${file}"
  done
  for file in geoip.dat geosite.dat; do
    [[ -f "${INSTALL_DIR}/${file}" ]] && cp -f "${INSTALL_DIR}/${file}" "${CONFIG_DIR}/${file}"
  done

  chmod 700 "${CONFIG_DIR}"
  chmod 600 "${CONFIG_DIR}/config.yml"
}

write_config_if_requested() {
  if [[ -z "${PANEL_TYPE}" && -z "${API_HOST}" && -z "${API_KEY}" && -z "${NODE_ID}" ]]; then
    return 0
  fi

  [[ -n "${PANEL_TYPE}" ]] || die "PANEL_TYPE is required when writing config."
  [[ -n "${API_HOST}" ]] || die "API_HOST is required when writing config."
  [[ -n "${API_KEY}" ]] || die "API_KEY is required when writing config."
  [[ -n "${NODE_ID}" ]] || die "NODE_ID is required when writing config."

  local cert_domain_line
  if [[ -n "${CERT_DOMAIN}" ]]; then
    cert_domain_line="        CertDomain: \"${CERT_DOMAIN}\""
  else
    cert_domain_line="        CertDomain:"
  fi

  log "Writing ${CONFIG_DIR}/config.yml from environment variables"
  install -m 600 /dev/stdin "${CONFIG_DIR}/config.yml" <<EOF
Log:
  Level: ${LOG_LEVEL}
  AccessPath:
  ErrorPath:
DnsConfigPath:
RouteConfigPath:
InboundConfigPath:
OutboundConfigPath:
ConnectionConfig:
  Handshake: 4
  ConnIdle: 30
  UplinkOnly: 2
  DownlinkOnly: 4
  BufferSize: 64
Nodes:
  - PanelType: "${PANEL_TYPE}"
    ApiConfig:
      ApiHost: "${API_HOST}"
      ApiKey: "${API_KEY}"
      NodeID: ${NODE_ID}
      NodeType: ${NODE_TYPE}
      Timeout: 30
      EnableVless: false
      VlessFlow: "xtls-rprx-vision"
      SpeedLimit: 0
      DeviceLimit: 0
      RuleListPath:
      DisableCustomConfig: false
    ControllerConfig:
      ListenIP: ${LISTEN_IP}
      SendIP: ${SEND_IP}
      UpdatePeriodic: 60
      EnableDNS: false
      DNSType: AsIs
      EnableProxyProtocol: false
      AutoSpeedLimitConfig:
        Limit: 0
        WarnTimes: 0
        LimitSpeed: 0
        LimitDuration: 0
      GlobalDeviceLimitConfig:
        Enable: false
        RedisNetwork: tcp
        RedisAddr: 127.0.0.1:6379
        RedisUsername:
        RedisPassword:
        RedisDB: 0
        Timeout: 5
        Expiry: 60
      EnableFallback: false
      FallBackConfigs: []
      DisableLocalREALITYConfig: false
      EnableREALITY: false
      REALITYConfigs:
        Show: false
        Dest: www.amazon.com:443
        ProxyProtocolVer: 0
        ServerNames:
          - www.amazon.com
        PrivateKey:
        MinClientVer:
        MaxClientVer:
        MaxTimeDiff: 0
        ShortIds:
          - ""
      CertConfig:
        CertMode: ${CERT_MODE}
${cert_domain_line}
        CertFile:
        KeyFile:
        Provider:
        Email:
        DNSEnv: {}
EOF
}

write_service() {
  log "Writing systemd service"
  install -m 0644 /dev/stdin "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=XrayR Service
Documentation=https://github.com/${XRAYR_REPO}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/XrayR -c ${CONFIG_DIR}/config.yml
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  install -m 0755 /dev/stdin /usr/bin/XrayR <<EOF
#!/usr/bin/env bash
set -euo pipefail
SERVICE="${SERVICE_NAME}"
BIN="${INSTALL_DIR}/XrayR"
CONFIG="${CONFIG_DIR}/config.yml"
case "\${1:-help}" in
  start) systemctl start "\${SERVICE}" ;;
  stop) systemctl stop "\${SERVICE}" ;;
  restart) systemctl restart "\${SERVICE}" ;;
  reload) systemctl reload-or-restart "\${SERVICE}" ;;
  status) systemctl status "\${SERVICE}" --no-pager ;;
  enable) systemctl enable "\${SERVICE}" ;;
  disable) systemctl disable "\${SERVICE}" ;;
  log|logs) journalctl -u "\${SERVICE}" -e --no-pager ;;
  follow) journalctl -u "\${SERVICE}" -f ;;
  config) \${EDITOR:-vi} "\${CONFIG}" ;;
  version) "\${BIN}" version ;;
  x25519) "\${BIN}" x25519 ;;
  *) echo "Usage: XrayR {start|stop|restart|status|enable|disable|log|follow|config|version|x25519}" ;;
esac
EOF
  ln -sf /usr/bin/XrayR /usr/bin/xrayr

  systemctl daemon-reload
  systemd-analyze verify "/etc/systemd/system/${SERVICE_NAME}.service"
}

maybe_start() {
  if [[ "${ENABLE_SERVICE}" == "1" ]]; then
    systemctl enable "${SERVICE_NAME}" >/dev/null
  fi

  if [[ "${START_SERVICE}" == "1" || ( "${START_SERVICE}" == "auto" && -n "${PANEL_TYPE}" && -n "${API_HOST}" && -n "${API_KEY}" && -n "${NODE_ID}" ) ]]; then
    log "Starting ${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    systemctl status "${SERVICE_NAME}" --no-pager
  else
    log "Installed but not started. Edit ${CONFIG_DIR}/config.yml, then run: XrayR start"
    systemctl is-enabled "${SERVICE_NAME}" || true
    systemctl is-active "${SERVICE_NAME}" || true
  fi
}

main() {
  install_deps
  download_and_install
  write_config_if_requested
  write_service
  "${INSTALL_DIR}/XrayR" version
  maybe_start
}

main "$@"
