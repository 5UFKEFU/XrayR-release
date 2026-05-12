#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_NAME="service2"
BASE_CONFIG="/etc/XrayR/${TEMPLATE_NAME}/config.yml"
INSTANCE_ROOT="/etc/XrayR"
UNIT_TEMPLATE="/etc/systemd/system/XrayR@.service"
XRAYR_BIN="/usr/local/XrayR/XrayR"
AUTO_START=0

log() {
  printf "[%s] %s\n" "$(date +"%F %T")" "$*"
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请用 root 运行此脚本" >&2
    exit 1
  fi
}

ensure_files() {
  if [[ ! -x "$XRAYR_BIN" ]]; then
    echo "未找到 XrayR 二进制: $XRAYR_BIN" >&2
    exit 1
  fi

  if [[ ! -f "$BASE_CONFIG" ]]; then
    echo "未找到模板配置文件: $BASE_CONFIG" >&2
    exit 1
  fi

  if [[ ! -f "$UNIT_TEMPLATE" ]]; then
    log "创建 systemd 模板: $UNIT_TEMPLATE"
    cat > "$UNIT_TEMPLATE" <<"UNIT"
[Unit]
Description=XrayR Service %i
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/XrayR/
ExecStart=/usr/local/XrayR/XrayR --config /etc/XrayR/%i/config.yml
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi
}

usage() {
  cat <<USAGE
用法:
  $(basename "$0") [--start] service3 [service4 ...]

说明:
  - 固定以 /etc/XrayR/${TEMPLATE_NAME}/config.yml 作为模板复制
  - 默认只创建实例目录和配置，不自动启动，避免复制模板后端口/NodeID 冲突
  - 为每个实例创建 /etc/XrayR/<实例名>/config.yml
  - systemd 服务名为 XrayR@<实例名>
  - 如果实例目录或服务已存在，则自动跳过
  - 如果确认配置已修改完成，可加 --start 自动启用并启动服务
USAGE
}

parse_args() {
  local names=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --start)
        AUTO_START=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
      *)
        names+=("$1")
        shift
        ;;
    esac
  done

  while [[ "$#" -gt 0 ]]; do
    names+=("$1")
    shift
  done

  if [[ "${#names[@]}" -eq 0 ]]; then
    usage
    exit 1
  fi

  INSTANCE_NAMES=("${names[@]}")
}

create_instance() {
  local name="$1"
  local config_dir="$INSTANCE_ROOT/$name"
  local config_file="$config_dir/config.yml"
  local unit_name="XrayR@${name}.service"

  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log "跳过 $name: 实例名只能包含字母、数字、点、下划线、短横线"
    return 0
  fi

  if [[ "$name" == "$TEMPLATE_NAME" ]]; then
    log "跳过 $name: 这是模板实例"
    return 0
  fi

  if [[ -d "$config_dir" ]] || systemctl list-unit-files --full --all | grep -Fq "$unit_name"; then
    log "跳过 $name: 实例已存在"
    return 0
  fi

  mkdir -p "$config_dir"
  cp "$BASE_CONFIG" "$config_file"
  systemctl daemon-reload

  log "已基于模板 ${TEMPLATE_NAME} 创建实例 $name"
  log "模板配置: $BASE_CONFIG"
  log "配置文件: $config_file"
  log "服务名: $unit_name"
  log "请先修改配置中的 NodeID、端口、证书、SendIP 等参数"

  if [[ "$AUTO_START" -eq 1 ]]; then
    systemctl enable --now "$unit_name"
    log "已启动实例 $name"
  else
    log "未启动 $name；如需启动，执行: systemctl enable --now $unit_name"
  fi
}

main() {
  ensure_root
  parse_args "$@"
  ensure_files

  for name in "${INSTANCE_NAMES[@]}"; do
    create_instance "$name"
  done
}

main "$@"
