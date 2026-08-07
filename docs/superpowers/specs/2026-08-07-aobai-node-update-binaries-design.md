# aobai-node 只更新二进制设计

日期：2026-08-07

## 背景

`install-aobai-node.sh` 目前只有完整部署、追加/覆盖、`--prepare-only`、`--remove-service`。没有「只换二进制、不动配置参数、不重装」的入口。`--prepare-only` 会解压整包并覆盖 `tools/` 与 `tier1-egress.json`，不满足该需求。

## 目标

在现有一键安装脚本中增加 `--update-binaries` 模式：

- 只更新 `$INSTALL_ROOT/bin/` 中的可执行文件
- 自动重启相关 systemd 服务使新二进制生效
- 不修改协议/端口/节点 ID、配置、证书、env、systemd unit、crontab
- 不跑 apt、不重新生成配置、不碰面板参数

## 非目标

- 不更新 `configure.py`、`report_online_real.sh`、`tier1-egress.json`
- 不提供版本回滚
- 不新增独立更新脚本

## 用法

```bash
sudo bash install-aobai-node.sh --update-binaries
sudo bash install-aobai-node.sh --update-binaries --install-root /home/jeff/aobai-node
```

规则：

- 不需要域名 / 协议 / 端口 / 节点 ID
- 非 root 时自动 `sudo -E` 提权
- 默认安装目录：`/home/<调用者>/aobai-node`（可用 `--install-root` 覆盖）
- 必须已有 `etc/deployment.json`，否则报错退出

## 更新流程

1. 校验 `$INSTALL_ROOT/etc/deployment.json` 存在
2. 使用脚本内现有 `ARCHIVE_URL` 下载发布包（可用环境变量 `AOBAI_ARCHIVE_URL` 覆盖）到临时目录
3. 解压到临时目录，仅将下列文件安装到 `$INSTALL_ROOT/bin/`：
   - `sbox-server-embedded`
   - `redis-server-embedded`
   - `redis-cli-embedded`
   - `speedtestd`
   - `haproxy`
4. 校验可执行；若捆绑 `haproxy` 无法启动，回退到系统 `/usr/sbin/haproxy`（与安装逻辑一致）
5. `chown` 给运行用户
6. `systemctl restart aobai-node-redis aobai-node-speedtestd aobai-node-sbox`
7. 打印简短 status，清理临时目录

明确不动：配置、`deployment.json`、证书、env、systemd unit、crontab、apt、部署脚本与出口规则文件。

## 错误处理

- 无 `deployment.json` → 明确提示先完整部署，非 0 退出
- 下载失败或发布包缺二进制 → 非 0 退出，不修改现有 `bin/`
- 先写入临时目标再替换，避免半截更新
- 重启失败 → 非 0 退出，并提示用 `systemctl status` 排查（此时二进制可能已替换）

## 文档

- `usage()` 增加 `--update-binaries` 说明
- `aobai-node/README.md` 增加「只更新二进制」小节（用法 + 不动配置的说明）

## 改动文件

- `aobai-node/install-aobai-node.sh`
- `aobai-node/README.md`

## 验收标准

- 已部署节点执行 `--update-binaries` 后，`bin/` 可执行文件被替换为发布包版本
- `etc/deployment.json`、业务配置、证书、env、crontab 内容不变
- 三个 aobai-node systemd 服务已重启
- 未部署节点执行时报错且不创建半套目录
- README 与 `--help` 均能看到该用法
