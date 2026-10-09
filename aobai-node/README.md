# AoBai 节点一键部署

香港节点 `hk1`（节点 16）、`hk2`（节点 17）、`hk3`（节点 18）和
`hk5`（节点 144）的 CDN/HTTP2 入站会自动将 AI 域名流量转发到美国
出口。由于 ChatGPT App 等客户端的 QUIC 流量可能只显示目标 IP，香港
节点的全部 UDP 流量也会转发到美国出口；其他 TCP 流量仍使用香港出口。

安装器会从 SSPanel 的 `/mod_mu/nodes/<节点ID>/info` 读取 Reality、Host、Path
等协议参数，下载预编译 Linux 发布包，生成配置、申请证书并安装 systemd 服务。
CDN/VLESS-XHTTP 服务端统一使用 `mode: auto`，兼容 Shadowrocket，同时继续
接受客户端的 `stream-up` GET/POST 会话。

## 最短用法

```bash
wget https://raw.githubusercontent.com/5UFKEFU/XrayR-release/master/aobai-node/install-aobai-node.sh
bash install-aobai-node.sh fr2.xinhuanet.network vless 38573 196
```

同一台机器一次安装多个协议：

```bash
bash install-aobai-node.sh fr2.xinhuanet.network \
  anytls,vless,cdn,naive,http2,hysteria2 \
  38553,38573,443,38574,55584,38590 \
  182,196,197,198,182,195
```

三组逗号列表必须一一对应。支持的协议名称为：
`anytls`、`vless`、`cdn`、`naive`、`http2`、`hysteria2`。

目标安装目录已有 `etc/deployment.json` 时，安装器不会再静默覆盖。交互
运行会提示选择追加（推荐）、覆盖或取消；非交互运行默认取消，必须显式传入：

```bash
# 保留全部已有服务并追加
bash install-aobai-node.sh hk4.febbox.cn cdn 443 193 \
  --existing-action append

# 明确重建并覆盖原部署
bash install-aobai-node.sh example.com vless 38573 196 \
  --existing-action overwrite
```

追加模式会保留现有源站域名和证书。面板中的 CDN Host 可以使用其他域名；
多个 CDN 节点允许使用不同 Host/SNI 共享 `443`，Nginx 会为每个 Host 生成
独立虚拟主机。非 CDN 服务出现端口冲突时安装器会拒绝继续。

需要使用不同面板或 mu_key 时：

```bash
MU_KEY='实际值' PANEL_URL='https://www.5ufkefu.com' \
  bash install-aobai-node.sh fr2.xinhuanet.network cdn 443 197
```

CDN 使用系统 Nginx；HTTP2 使用随发布包提供的 HAProxy。
部署时会按服务器公网 IP 自动获取测速节点的城市、国家、经纬度和时区，
写入 `speedtestd` 的 systemd 环境，避免所有节点回退为发布包内置的香港位置。

香港过渡节点（当前为节点 `17`、`144`）默认保持香港直出，但 OpenAI、
ChatGPT、Claude、Gemini、Perplexity 等 AI 服务域名会优先通过
`egress-usa` 美国 Reality 出口访问；该规则同时覆盖节点的 CDN 和 HTTP2
入站，并排在香港默认出口规则之前。

移除已有部署中的单个协议或端口：

```bash
sudo bash install-aobai-node.sh sg1.xinhuanet.network --remove-service anytls
sudo bash install-aobai-node.sh sg1.xinhuanet.network --remove-service 443
```

移除操作会读取 `etc/deployment.json`，重新生成其余服务的完整配置并清理
不再使用的 Nginx 前端。至少需要保留一个服务。

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

## Cloudflare DNS 证书

域名尚未创建 A 记录，或者服务器无法开放 80 端口时，使用 Cloudflare
DNS-01 模式：

```bash
bash install-aobai-node.sh uk4.xinhuanet.network \
  anytls,vless,cdn,naive,http2,hysteria2 \
  38553,38573,443,38574,55584,38590 \
  199,201,202,203,199,200 \
  --cert-mode cloudflare \
  --cloudflare-token 'Cloudflare_API_Token' \
  --email admin@example.com
```

Token 只需授予目标 Zone 的 `DNS:Edit` 权限。安装器把 Token 保存到 root
专用文件 `/etc/aobai-node/cloudflare.token`（权限 `600`），不再写进任何
crontab。Certbot 运行期间只在内存文件系统 `/run` 临时生成权限为 `600` 的
凭证，运行结束立即删除。注意直接在命令行传 Token 会留在 shell history。

续签由 root 的 `/etc/cron.d/aobai-cert-renew` 每周一 03:17 执行
`/usr/local/sbin/aobai-cert-renew`（日志 `/var/log/aobai-cert-renew.log`），
不依赖运行用户的 sudo 权限；安装器会删除旧版写在运行用户 crontab 里的
`sudo -n aobai-cert-renew` 任务。Certbot 只在证书进入续签窗口时真正续签；
成功后会同步项目证书、无中断 reload Nginx，并重启 sbox。Cloudflare DNS
验证期间不需要停止或重启 Nginx。

## 在线人数上报

安装器把 `tools/report_online_real.sh` 加进节点运行用户的 `crontab -l`
每分钟执行，**不使用 sudo**：

```
* * * * * <安装目录>/tools/report_online_real.sh >> /tmp/report_online_real.log 2>&1 # aobai-online-report
```

脚本只需读取 `etc/deployment.json`（安装器设为 `root:<运行用户> 0640`）和
`env/aobai-node.env`（运行用户 `600`）。上报认证串不写在仓库里，而是放在
env 文件的 `ONLINE_REPORT_AUTH`，安装时用 `--online-report-auth` 传入（已有
部署重装时自动保留），并通过 `X-Report-Auth` 请求头发送，不出现在 URL 里。

脚本从本机 SSM API（`MULTI_SSM_PORT`，默认 28912）的 `hysteria2`、
`https-connect`、`vless-xray` 三类入站连续采集两次按用户、按入站的流量计数，
采样期间有字节/数据包增量、或当前仍有活动连接（`tcpActiveConnections` /
`udpActiveConnections`）的用户续入 5 分钟在线窗口；按面板节点 `server` 合并
同一服务器的多个节点 ID / 协议，对用户 ID 去重后每个 server 只上报一次。
不能使用 SSM 的 `tcpSessions` / `udpSessions` 判断在线，因为它们是进程启动
以来的累计连接次数。迁移期间还会读取仍在运行的旧 XrayR 访问日志（有读权限
时），将近 5 分钟的旧协议用户与新协议用户合并后只提交一次。

迁移旧服务器时，安装器会删除 root crontab 中调用旧
`report_online_real.sh` 或 `report_xray_online.py` 的任务，避免重复上报。

## 监控接口与水位修复工具

监控接口（`MULTI_MONITOR_PORT`，默认 28910）只监听 `MONITOR_BIND_IP`，并要求
`MONITOR_AUTH_TOKEN`（`Authorization: Bearer <token>` 或 `X-Monitor-Token`）。
安装器会保留 env 文件中已有的 token，没有时自动生成。
`tools/heal_traffic_watermarks.py` 默认从 `env/aobai-node.env` 读取地址和
token（可用 `--sessions-url`、`--token`、`--env-file` 或同名环境变量覆盖），
不带 `--apply` 时只读检查。

## 部署前提

- Ubuntu/Debian x86_64。
- HTTP-01 模式要求域名 A 记录指向服务器，并放行 80 端口。
- Cloudflare DNS-01 模式申请证书时不要求 A 记录或开放 80 端口。
- 服务投入使用前仍需为域名配置正确的 A 记录并放行业务端口。
- 执行安装器的用户可以使用 sudo（仅安装时需要；日常上报与续签不依赖 sudo）。

发布包不包含证书、Cloudflare Token、面板私钥或任何服务器运行数据。

### 在线人数上报补充（2026-10-09）

- `SSM_PROTOCOLS` 默认值扩展为 `hysteria2,https-connect,vless-xray,trojan,naive,anytls,vless,shadowsocks,tuic`，
  只跑 trojan（如 hk8）或 naive（如 hk9）的节点不再报 0；不存在的端点会被跳过。
- 同一批节点 ID 被多台机器部署时（迁移后旧机仍保留配置），在非主力机器的 env 里设置
  `ONLINE_REPORT_EXCLUDE_NODES=185,186,...` 跳过这些节点 ID，或用 `ONLINE_REPORT_NODES=144,193`
  只上报列出的节点 ID，避免两台机器轮流覆盖同一服务器的在线数。
- `heal_traffic_watermarks.py --apply` 已加确认开关：该工具会把正常推进中的水位误判为卡住，
  清零后导致整段流量重复上报。默认只读排查，确需写入时加 `--i-know-this-double-reports`。
