# aobai-node --update-binaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 `install-aobai-node.sh` 增加 `--update-binaries`，只替换已有部署的 `bin/` 可执行文件并重启服务，同时更新 README。

**Architecture:** 在脚本顶部（与 `--remove-service` 同级）增加独立早期分支：解析 `--update-binaries` / `--install-root`，校验 `deployment.json`，下载发布包到临时目录后仅 `install` 五个二进制到 `$INSTALL_ROOT/bin/`，保留 HAProxy glibc 回退，再 `systemctl restart` 三个服务。不进入完整安装主流程。

**Tech Stack:** Bash、curl、tar、systemd、现有 pinned `ARCHIVE_URL`

## Global Constraints

- 只更新 `bin/` 中：`sbox-server-embedded`、`redis-server-embedded`、`redis-cli-embedded`、`speedtestd`、`haproxy`
- 不动配置、`deployment.json`、证书、env、systemd unit、crontab、apt、`configure.py` / `report_online_real.sh` / `tier1-egress.json`
- 必须已有 `$INSTALL_ROOT/etc/deployment.json`
- 自动重启 `aobai-node-redis`、`aobai-node-speedtestd`、`aobai-node-sbox`
- 用法：`bash install-aobai-node.sh --update-binaries [--install-root DIR]`
- 不主动 git commit，除非用户明确要求

---

## File map

| File | Responsibility |
|------|----------------|
| `aobai-node/install-aobai-node.sh` | 新增 `--update-binaries` 分支；更新 `usage()` |
| `aobai-node/README.md` | 文档：只更新二进制的用法与边界 |

---

### Task 1: 安装脚本增加 `--update-binaries` 模式

**Files:**
- Modify: `aobai-node/install-aobai-node.sh`（`usage()` 与 `--remove-service` 分支之前/并列）

**Interfaces:**
- Consumes: 现有 `ARCHIVE_URL`、`AOBAI_ARCHIVE_URL`、`AOBAI_RUN_USER` / `SUDO_USER`、二进制列表与 HAProxy 回退逻辑
- Produces: CLI `--update-binaries`；成功时重启三个服务；失败时非 0 退出且下载失败时不改现有 `bin/`

- [ ] **Step 1: 更新 `usage()`**

在「选项:」段加入（建议放在 `--remove-service` 之后）：

```bash
  --update-binaries     只更新已有部署的 bin/ 二进制并重启服务，
                        不改配置与参数。例如：
                        bash install-aobai-node.sh --update-binaries
                        bash install-aobai-node.sh --update-binaries \
                          --install-root /home/jeff/aobai-node
```

- [ ] **Step 2: 在 `--remove-service` 分支之前插入更新模式**

在 `if [[ $# -ge 3 && "$2" == "--remove-service" ]]; then` **之前**加入：

```bash
if [[ $# -ge 1 && "$1" == "--update-binaries" ]]; then
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-root) INSTALL_ROOT="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "更新二进制模式不支持参数: $1" >&2; exit 2 ;;
    esac
  done
  if [[ "${EUID}" -ne 0 ]]; then
    update_args=(--update-binaries)
    [[ -n "$INSTALL_ROOT" ]] && update_args+=(--install-root "$INSTALL_ROOT")
    exec sudo -E env AOBAI_RUN_USER="${USER}" bash "$0" "${update_args[@]}"
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

  tmp_dir="$(mktemp -d)"
  staging_bin="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir" "$staging_bin"' EXIT
  echo "下载发布包: $ARCHIVE_URL"
  curl -fL --retry 3 --connect-timeout 20 "$ARCHIVE_URL" -o "$tmp_dir/release.tar.gz"
  tar -xzf "$tmp_dir/release.tar.gz" -C "$tmp_dir"
  # 发布包顶层可能是扁平目录或单层包装；兼容 bin/ 在解压根或一级子目录。
  src_bin=""
  if [[ -d "$tmp_dir/bin" ]]; then
    src_bin="$tmp_dir/bin"
  else
    for candidate in "$tmp_dir"/*/bin; do
      if [[ -d "$candidate" ]]; then
        src_bin="$candidate"
        break
      fi
    done
  fi
  [[ -n "$src_bin" ]] || {
    echo "发布包中找不到 bin/ 目录" >&2
    exit 1
  }

  mkdir -p "$INSTALL_ROOT/bin"
  for binary in sbox-server-embedded redis-server-embedded redis-cli-embedded speedtestd haproxy; do
    [[ -f "$src_bin/$binary" ]] || {
      echo "发布包缺少 bin/$binary" >&2
      exit 1
    }
    # 先落到 staging，全部就绪后再进目标目录，避免半截更新。
    install -m 0755 "$src_bin/$binary" "$staging_bin/$binary"
  done
  if ! "$staging_bin/haproxy" -vv >/dev/null 2>&1; then
    install -m 0755 /usr/sbin/haproxy "$staging_bin/haproxy"
  fi
  for binary in sbox-server-embedded redis-server-embedded redis-cli-embedded speedtestd haproxy; do
    [[ -x "$staging_bin/$binary" ]] || {
      echo "暂存二进制不可执行: $binary" >&2
      exit 1
    }
    install -m 0755 -o "$RUN_USER" -g "$RUN_USER" \
      "$staging_bin/$binary" "$INSTALL_ROOT/bin/$binary"
  done

  echo "重启服务以加载新二进制..."
  systemctl restart aobai-node-redis aobai-node-speedtestd aobai-node-sbox || {
    echo "服务重启失败；二进制可能已更新。请检查: systemctl status aobai-node-{redis,speedtestd,sbox}" >&2
    exit 1
  }
  sleep 3
  systemctl --no-pager --full status aobai-node-sbox | sed -n '1,12p'
  echo "二进制更新完成: $INSTALL_ROOT/bin"
  exit 0
fi
```

实现时注意：

- 保持与现有 `--remove-service` 相同的 `RUN_USER` / `INSTALL_ROOT` 解析方式
- `set -euo pipefail` 下 `curl -fL` / `tar` 失败会直接退出，且因 staging 未拷到目标，现有 `bin/` 不受影响
- 不要调用 apt、不要写配置、不要 curl `configure.py`

- [ ] **Step 3: 语法检查**

Run:

```bash
bash -n aobai-node/install-aobai-node.sh
```

Expected: 无输出，退出码 0

- [ ] **Step 4: 帮助文案可见**

Run:

```bash
bash aobai-node/install-aobai-node.sh --help | grep -A2 update-binaries
```

Expected: 输出包含 `--update-binaries` 与示例用法

（若当前 `--help` 只在参数解析里处理，确认 `usage` 在 `[[ $# -ge 4 ]]` 失败时打印；`--update-binaries` 分支内的 `-h|--help` 也应可用。另可额外测：`bash aobai-node/install-aobai-node.sh --update-binaries -h`）

- [ ] **Step 5: 未部署应失败**

Run（在不存在部署目录时）:

```bash
bash aobai-node/install-aobai-node.sh --update-binaries --install-root /tmp/aobai-node-missing-$$
```

Expected: 非 0 退出；stderr 含「找不到部署状态」；不创建完整部署

---

### Task 2: 更新 README

**Files:**
- Modify: `aobai-node/README.md`

**Interfaces:**
- Consumes: Task 1 的最终 CLI
- Produces: 运维可读的「只更新二进制」小节

- [ ] **Step 1: 在「移除已有部署…」小节附近新增一节**

建议放在「移除已有部署中的单个协议或端口」之后、「Cloudflare DNS 证书」之前：

```markdown
## 只更新二进制

已部署节点只需替换可执行文件、保留全部配置与参数时：

```bash
sudo bash install-aobai-node.sh --update-binaries
# 或指定安装目录
sudo bash install-aobai-node.sh --update-binaries \
  --install-root /home/jeff/aobai-node
```

该模式会下载当前脚本锁定的发布包，只覆盖 `bin/` 中的
`sbox-server-embedded`、`redis-server-embedded`、`redis-cli-embedded`、
`speedtestd`、`haproxy`，然后重启 `aobai-node-redis`、
`aobai-node-speedtestd`、`aobai-node-sbox`。不会改动
`etc/deployment.json`、业务配置、证书、env、systemd unit 或 crontab。
需要先有一次完整部署（存在 `etc/deployment.json`）。
可用环境变量 `AOBAI_ARCHIVE_URL` 覆盖发布包地址。
```

注意：外层 README 已有多层 markdown 代码块时，实现时用正确围栏，避免嵌套 fence 破坏渲染；若冲突，改为缩进代码块或拆开示例。

- [ ] **Step 2: 目视确认 README 结构**

确认新小节标题层级为 `##`，与「最短用法」「Cloudflare DNS 证书」一致；示例命令与脚本一致。

---

### Task 3: 本地自检清单

**Files:**
- 无新增文件

- [ ] **Step 1: 再次 `bash -n`**

```bash
bash -n aobai-node/install-aobai-node.sh
```

Expected: 退出码 0

- [ ] **Step 2: 对照 spec 验收标准逐项核对**

对照 `docs/superpowers/specs/2026-08-07-aobai-node-update-binaries-design.md`：

1. CLI 无需域名/协议/端口/节点 ID
2. 仅更新列出的五个二进制
3. 自动重启三个服务
4. 文档与 `--help` 均有说明
5. 无部署时失败且不半套安装

- [ ] **Step 3: 如用户要求再提交**

默认不 commit。若用户明确要求提交，再按仓库风格提交 `install-aobai-node.sh` 与 `README.md`（spec/plan 是否纳入由用户决定）。
