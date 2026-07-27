# AoBai 节点一键部署

香港节点 `hk1`（节点 16）、`hk2`（节点 17）、`hk3`（节点 18）和
`hk5`（节点 144）的 CDN/HTTP2 入站会自动将 AI 域名流量转发到美国
出口。由于 ChatGPT App 等客户端的 QUIC 流量可能只显示目标 IP，香港
节点的全部 UDP 流量也会转发到美国出口；其他 TCP 流量仍使用香港出口。

安装器会从 SSPanel 的 `/mod_mu/nodes/<节点ID>/info` 读取 Reality、Host、Path
等协议参数，下载预编译 Linux 发布包，生成配置、申请证书并安装 systemd 服务。

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

Token 只需授予目标 Zone 的 `DNS:Edit` 权限。脚本会将 Token 直接写入
部署用户的 `crontab -l` 命令。Certbot 运行期间只在内存文件系统 `/run`
临时生成权限为 `600` 的凭证，运行结束立即删除，不长期保存凭证文件。
Token 会同时出现在 shell history 和用户 crontab 中。

用户 crontab 每周一 03:17 执行续签检查。Certbot 只在证书进入续签窗口
时真正续签；成功后会同步项目证书、无中断 reload Nginx，并重启 sbox。
Cloudflare DNS 验证期间不需要停止或重启 Nginx。

## 在线人数上报

安装器会把 `tools/report_online_real.sh` 部署为 root 所有、由节点运行用户
通过 `sudo -n` 执行，并在该用户的 `crontab -l` 中加入每分钟任务。脚本读取
本机 `http://127.0.0.1:28910/monitor/status`，从入站 Tag 识别节点 ID，
按节点分别对唯一用户去重并提交到对应服务器域名。迁移期间还会读取仍在运行
的旧 XrayR 访问日志，将近 5 分钟的旧协议用户与新协议用户合并后只提交一次，
避免新旧计划任务互相覆盖。

迁移旧服务器时，安装器会删除 root crontab 中调用旧
`report_online_real.sh` 或 `report_xray_online.py` 的任务，避免重复上报。

## 部署前提

- Ubuntu/Debian x86_64。
- HTTP-01 模式要求域名 A 记录指向服务器，并放行 80 端口。
- Cloudflare DNS-01 模式申请证书时不要求 A 记录或开放 80 端口。
- 服务投入使用前仍需为域名配置正确的 A 记录并放行业务端口。
- 当前用户可以使用 sudo。

发布包不包含证书、Cloudflare Token、面板私钥或任何服务器运行数据。
