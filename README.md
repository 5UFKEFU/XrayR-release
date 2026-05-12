# XRayR
A Xray backend framework that can easily support many panels.

一个基于 Xray 的后端框架，支持 V2Ray、Trojan、Shadowsocks 协议，极易扩展，支持多面板对接。

- **本仓库**（一键安装脚本、systemd 单元、管理脚本与示例配置）：[5UFKEFU/XrayR-release](https://github.com/5UFKEFU/XrayR-release)
- **XrayR 程序源码**（Go 主项目）：[XrayR-project/XrayR](https://github.com/XrayR-project/XrayR)

# 详细使用教程

[教程](https://xrayr-project.github.io/XrayR-doc/)

# 一键安装

```
bash <(curl -Ls https://raw.githubusercontent.com/5UFKEFU/XrayR-release/master/install.sh)
```

# install_xrayr.sh（进阶安装）

适合需要**指定版本 / 指定 GitHub 仓库**、或希望用**环境变量一次性写入面板配置**的场景。需 **root** 运行；默认从 `XrayR-project/XrayR` 的 Release 下载对应架构的 `XrayR-linux-*.zip`（可用变量覆盖），安装到 `/usr/local/XrayR`，配置目录 `/etc/XrayR`，并注册默认服务名 `XrayR`。

常用选项（完整说明见脚本内 `usage`）：

- `--version <tag>`：发行标签，默认 `v0.9.4`
- `--repo <owner/repo>`：二进制所在仓库，默认 `XrayR-project/XrayR`
- `--start` / `--no-start`：安装后是否启动服务
- `--no-enable`：不设置开机自启

仅安装（不写面板配置，与经典 `install.sh` 行为类似，但流程与默认版本不同）：

```
curl -fsSL https://raw.githubusercontent.com/5UFKEFU/XrayR-release/master/install_xrayr.sh -o install_xrayr.sh
bash install_xrayr.sh
```

安装并**通过环境变量生成** `config.yml`（需同时提供 `PANEL_TYPE`、`API_HOST`、`API_KEY`、`NODE_ID`；可选 `NODE_TYPE`、`CERT_MODE`、`CERT_DOMAIN` 等）：

```
PANEL_TYPE=NewV2board API_HOST=https://panel.example.com API_KEY=你的密钥 NODE_ID=1 \
  NODE_TYPE=V2ray bash install_xrayr.sh
```

也可将脚本克隆到本机后执行：`bash install_xrayr.sh --version v0.9.4 --repo owner/XrayR`。

# add-xrayr-instance.sh（多实例）

在同一台机器上跑**多个 XrayR 节点**时，用 **systemd 模板单元** `XrayR@实例名` 管理各实例配置。

**前提：**

- 已安装可执行文件 `/usr/local/XrayR/XrayR`
- 已存在模板配置 **`/etc/XrayR/service2/config.yml`**（脚本固定以该路径为模板复制）

**用法：**

```
bash add-xrayr-instance.sh [--start] <实例名> [更多实例名...]
```

- 会为每个实例创建目录 `/etc/XrayR/<实例名>/`，并复制模板为 `config.yml`
- 服务名为 **`XrayR@<实例名>.service`**；默认**不自动启动**，避免与模板端口、NodeID 等冲突；改好各实例配置后手工启动，或加上 `--start` 在创建后立刻 `enable --now`
- 实例名只能包含字母、数字、`.`、`_`、`-`；名称 `service2` 会被跳过（模板实例）

示例（先准备好 `service2` 模板配置，再新增 `service3`、`service4`）：

```
bash add-xrayr-instance.sh service3 service4
# 分别编辑 /etc/XrayR/service3/config.yml、/etc/XrayR/service4/config.yml 后：
systemctl enable --now XrayR@service3 XrayR@service4
```

若模板单元 `/etc/systemd/system/XrayR@.service` 不存在，脚本会自动创建。

# Docker 一键启动

下列命令中的镜像为社区构建的示例；也可在本仓库根目录使用 `Dockerfile` 自行构建镜像后再运行。

```
docker run -d   --name xrayr   --network host   --restart always  \
  -e ApiHost=your_api_host  \
  -e ApiKey=your_api_key  \
  -e NodeID=1  \
  -e NodeType=Vless  \
  -e EnableREALITY=true  \
  ghcr.io/rebecca554owen/xrayr:latest

```

