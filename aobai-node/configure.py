#!/usr/bin/env python3
"""Generate one aobai-node instance from SSPanel node-info endpoints."""

import argparse
import json
import pathlib
import re
import urllib.request


TRANSITION_EGRESS = {
    17: "hk",
    21: "jp",
    139: "uk",
    153: "usa",
    185: "sg",
    186: "tw",
    187: "vn",
    188: "kr",
    189: "th",
    190: "au",
    191: "in",
    192: "de",
}

HK_NODE_IDS = {16, 17, 18, 144}
AI_DOMAIN_SUFFIXES = [
    "openai.com",
    "chatgpt.com",
    "oaistatic.com",
    "oaiusercontent.com",
    "anthropic.com",
    "claude.ai",
    "gemini.google.com",
    "generativelanguage.googleapis.com",
    "ai.google.dev",
    "aistudio.google.com",
    "bard.google.com",
    "perplexity.ai",
    "grok.com",
    "x.ai",
    "poe.com",
    "character.ai",
    "midjourney.com",
]


def split_csv(value):
    return [item.strip() for item in value.split(",") if item.strip()]


def node_info(panel_url, node_id):
    url = f"{panel_url.rstrip('/')}/mod_mu/nodes/{node_id}/info"
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 AoBai-Node-Installer/1.0"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = json.load(response)
    if not payload.get("ret"):
        raise RuntimeError(f"node {node_id} endpoint returned ret={payload.get('ret')}")
    return payload["data"]


def tls(domain, root, alpn):
    cert_dir = f"{root}/ssl/{domain}"
    return {
        "enabled": True,
        "alpn": alpn,
        "certificate_path": f"{cert_dir}/fullchain.pem",
        "key_path": f"{cert_dir}/privkey.pem",
        "server_name": domain,
    }


def build_inbound(protocol, port, node_id, domain, root, info):
    custom = info.get("custom_config") or {}
    supported = {
        re.sub(r"[^a-z0-9]", "", str(item).lower())
        for item in (info.get("supported_protocols") or [])
    }
    expected_support = {
        "anytls": "anytls",
        "vless": "vless",
        "cdn": "cdn",
        "naive": "naivehttp",
        "http2": "http2",
        "https-connect": "http2",
        "hysteria2": "hysteria2",
        "hy2": "hysteria2",
    }.get(protocol)
    if supported and expected_support not in supported:
        raise ValueError(
            f"node {node_id} does not support {protocol}; endpoint says "
            f"{info.get('supported_protocols')}"
        )
    endpoint_ports = {
        int(value)
        for value in (
            custom.get("offset_port_node"),
            custom.get("offset_port_user"),
        )
        if str(value or "").isdigit()
    }
    if endpoint_ports and protocol not in ("http2", "https-connect"):
        if port not in endpoint_ports:
            raise ValueError(
                f"node {node_id} port mismatch: argument={port}, "
                f"endpoint ports={sorted(endpoint_ports)}"
            )
    tag = f"5uf-{protocol}-{node_id}"
    protocol_id_base = {
        "anytls": 10000,
        "vless": 20000,
        "cdn": 30000,
        "naive": 40000,
        "http2": 50000,
        "https-connect": 50000,
        "hysteria2": 60000,
        "hy2": 60000,
    }
    inbound_id = protocol_id_base.get(protocol, 90000) + int(node_id)
    base = {
        "id": inbound_id,
        "tag": tag,
        "users": [],
    }
    if protocol == "anytls":
        base.update(type="anytls", listen="0.0.0.0", listen_port=port)
        base["tls"] = tls(domain, root, ["h2", "http/1.1"])
    elif protocol == "naive":
        base.update(type="naive", listen="0.0.0.0", listen_port=port)
        base["tls"] = tls(domain, root, ["h2"])
    elif protocol in ("hysteria2", "hy2"):
        protocol = "hysteria2"
        tag = f"5uf-{protocol}-{node_id}"
        base.update(tag=tag, type="hysteria2", listen="0.0.0.0",
                    listen_port=port, ignore_client_bandwidth=True)
        base["tls"] = tls(domain, root, ["h3"])
    elif protocol == "vless":
        reality = custom.get("reality-opts") or {}
        destination = str(reality.get("dest") or "www.apple.com:443")
        server, _, server_port = destination.rpartition(":")
        base.update(
            type="vless",
            listen="0.0.0.0",
            listen_port=port,
            flow=custom.get("flow") or "xtls-rprx-vision",
            tls={
                "enabled": True,
                "server_name": (custom.get("host") or server),
                "reality": {
                    "enabled": True,
                    "private_key": reality.get("private_key", ""),
                    "short_id": [x for x in reality.get("short_ids", []) if x],
                    "max_time_difference": f"{int(reality.get('max_time_diff', 600))}s",
                    "handshake": {
                        "server": server,
                        "server_port": int(server_port or 443),
                    },
                },
            },
        )
    elif protocol == "cdn":
        inner_port = 49000 + (int(node_id) % 900)
        path = custom.get("path") or "/speedtest/api/probe"
        path = "/" + path.strip("/")
        base.update(
            type="vless-xray",
            listen="127.0.0.1",
            listen_port=inner_port,
            xhttp_settings={
                "host": custom.get("host") or domain,
                "path": path + "/",
                # `auto` accepts the same GET-downlink/POST-stream-up flow and
                # is compatible with Shadowrocket variants that do not behave
                # consistently when the server is pinned to `stream-up`.
                "mode": "auto",
                "sessionPlacement": "header",
                "sessionKey": "X-Speedtest-Session",
                "seqPlacement": "header",
                "seqKey": "X-Speedtest-Seq",
                "xPaddingBytes": {"from": 0, "to": 0},
            },
        )
        base["_nginx"] = {
            "public_port": port,
            "inner_port": inner_port,
            "path": path,
            "server_name": custom.get("host") or domain,
        }
    elif protocol in ("http2", "https-connect"):
        protocol = "http2"
        tag = f"5uf-{protocol}-{node_id}"
        inner_port = 38000 + (int(node_id) % 900)
        base.update(
            tag=tag,
            type="https-connect",
            listen="127.0.0.1",
            listen_port=inner_port,
            proxy_type="mixed",
            nginx_front={
                "enabled": True,
                "front_engine": "haproxy",
                "listen_port": port,
                "bridge_listen_port": 48000 + (int(node_id) % 900),
                "connect_proxy_pass": f"http://127.0.0.1:{inner_port}",
                "relay_mode": "connect_proxy",
                "server_name": domain,
                "decoy_profile": "speedtest",
                "locations": [{"type": "proxy", "proxy_pass": "http://127.0.0.1:18771"}],
                "tls": {
                    "certificate_path": f"{root}/ssl/{domain}/fullchain.pem",
                    "key_path": f"{root}/ssl/{domain}/privkey.pem",
                },
            },
        )
    else:
        raise ValueError(f"unsupported protocol: {protocol}")
    return protocol, tag, inbound_id, base


def write_nginx(root, domain, cdn):
    nginx_dir = pathlib.Path(root) / "generated"
    nginx_dir.mkdir(parents=True, exist_ok=True)
    target = nginx_dir / f"nginx-{domain}.conf"
    if not cdn:
        target.unlink(missing_ok=True)
        return
    servers = []
    virtual_hosts = set()
    for item in cdn:
        port = int(item["public_port"])
        server_name = item["server_name"].lower()
        virtual_host = (port, server_name)
        if virtual_host in virtual_hosts:
            raise ValueError(
                f"duplicate CDN virtual host: {server_name}:{port}"
            )
        virtual_hosts.add(virtual_host)
        servers.append(f"""
server {{
    listen {port} ssl;
    listen [::]:{port} ssl;
    server_name {server_name};
    ssl_certificate {root}/ssl/{domain}/fullchain.pem;
    ssl_certificate_key {root}/ssl/{domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ {item['path']} {{
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Speedtest-Session $http_x_speedtest_session;
        proxy_set_header X-Speedtest-Seq $http_x_speedtest_seq;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 0;
        proxy_pass http://127.0.0.1:{item['inner_port']};
    }}
    location = /client/php.php {{
        default_type text/plain;
        return 200 "$remote_addr\n";
    }}
    location = /client/ip.php {{
        default_type text/plain;
        return 200 "$remote_addr\n";
    }}
    location ^~ /speedtest/api/ {{
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_pass http://127.0.0.1:18771;
    }}
    location / {{
        root /var/www/aobai-speedtest-{domain};
        try_files $uri $uri/ /index.html;
    }}
}}
""")
    target.write_text(f"""server {{
    listen 80;
    listen [::]:80;
    server_name {domain};
    return 301 https://$host$request_uri;
}}

{''.join(servers)}
""")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--protocols", required=True)
    parser.add_argument("--ports", required=True)
    parser.add_argument("--node-ids", required=True)
    parser.add_argument("--panel-url", default="https://www.5ufkefu.com")
    parser.add_argument("--mu-key", default="5uf5uf")
    parser.add_argument("--bind-ip", required=True)
    parser.add_argument("--monitor-ip", required=True)
    args = parser.parse_args()

    protocols = split_csv(args.protocols.lower())
    ports = [int(x) for x in split_csv(args.ports)]
    node_ids = [int(x) for x in split_csv(args.node_ids)]
    if not (len(protocols) == len(ports) == len(node_ids)):
        raise SystemExit("protocols, ports and node IDs must contain the same number of items")

    inbounds = []
    panel_rows = []
    inbound_ids = []
    cdn = []
    egress_inbounds = {}
    hk_inbound_tags = []
    for protocol, port, node_id in zip(protocols, ports, node_ids):
        info = node_info(args.panel_url, node_id)
        actual, tag, inbound_id, inbound = build_inbound(
            protocol, port, node_id, args.domain, args.root, info
        )
        nginx = inbound.pop("_nginx", None)
        if nginx:
            cdn.append(nginx)
        inbounds.append({"data": inbound, "success": True})
        inbound_ids.append(inbound_id)
        panel_rows.append((node_id, tag, actual))
        country = TRANSITION_EGRESS.get(node_id)
        if country:
            egress_inbounds.setdefault(country, []).append(tag)
        if node_id in HK_NODE_IDS:
            hk_inbound_tags.append(tag)

    outbounds = [{"tag": "direct", "type": "direct"},
                 {"tag": "block", "type": "block"}]
    # HTTPS CONNECT 的默认国家为 hk，动态用户路由会将基础 UUID 指向
    # egress-hk。香港本机出口就是 direct，因此必须提供同义出站，
    # 否则服务重启并重新生成路由后，HTTP2 会报 outbound not found。
    if "http2" in protocols:
        outbounds.append({"tag": "egress-hk", "type": "direct"})
    routes = []
    if egress_inbounds or hk_inbound_tags:
        egress_path = pathlib.Path(args.root) / "etc/sbox/tier1-egress.json"
        if not egress_path.is_file():
            raise SystemExit(f"missing country egress map: {egress_path}")
        egress_map = json.loads(egress_path.read_text())
        required_countries = list(egress_inbounds)
        if hk_inbound_tags and "usa" not in required_countries:
            required_countries.append("usa")
        for country in required_countries:
            outbound = dict(egress_map[country])
            outbound["tag"] = f"egress-{country}"
            outbounds.append(outbound)
        if hk_inbound_tags:
            # Mobile apps can send QUIC as bare destination IPs, so domain
            # rules cannot reliably identify AI traffic. Keep UDP functional
            # and route all UDP from Hong Kong nodes through the US exit.
            routes.append({
                "action": "route",
                "inbound": hk_inbound_tags,
                "network": ["udp"],
                "outbound": "egress-usa",
            })
            routes.append({
                "action": "route",
                "inbound": hk_inbound_tags,
                "domain_suffix": AI_DOMAIN_SUFFIXES,
                "outbound": "egress-usa",
            })
        for country, tags in egress_inbounds.items():
            routes.append({
                "action": "route",
                "inbound": tags,
                "outbound": f"egress-{country}",
            })

    bootstrap = {
        "experimental": {},
        "inbounds": inbounds,
        "management": {
            "bind_ip": args.monitor_ip,
            "host_id": f"aobai-{args.domain}",
            "instance_id": "aobai-node",
            "monitor": {"host": args.monitor_ip, "port": 28910},
            "speedtestd": {"host": "127.0.0.1", "port": 18771},
            "ssm": {"host": "127.0.0.1", "port": 28912},
        },
        "nginx_global": {"enabled": False},
        "outbounds": outbounds,
        "route": {},
        "routes": routes,
    }
    root = pathlib.Path(args.root)
    bootstrap_path = root / "etc/sbox/static-bootstrap.json"
    bootstrap_path.write_text(json.dumps(bootstrap, ensure_ascii=False, indent=2) + "\n")

    template = root / "etc/sbox/config.yaml.template"
    config = template.read_text()
    config = re.sub(r'  token_id: .*', '  token_id: 5', config, count=1)
    config = re.sub(r'  instance_id: .*', '  instance_id: "aobai-node"', config, count=1)
    config = re.sub(r'  host_id: .*', f'  host_id: "{args.domain}"', config, count=1)
    config = re.sub(r'  bind_ip: .*', '  bind_ip: "${PUBLIC_BIND_IP}"', config, count=1)
    config = re.sub(r'  inbound_ids: \[[^\n]*\]',
                    f"  inbound_ids: [{', '.join(map(str, inbound_ids))}]", config, count=1)
    panel_tags = {}
    for node_id, tag, _ in panel_rows:
        panel_tags.setdefault(node_id, []).append(tag)

    rows = ["compatible_sspanel:"]
    for node_id, tags in panel_tags.items():
        rows.extend([
            f'  - url: "{args.panel_url}"',
            f'    mu_key: "{args.mu_key}"',
            f"    node_id: {node_id}",
            '    protocol: "sspanel"',
            "    traffic_report_sec: 60",
            "    user_pull_sec: 300",
            "    inbound_tags:",
        ])
        rows.extend(f'      - "{tag}"' for tag in tags)
    config, count = re.subn(
        r"compatible_sspanel:\n.*?(?=\nonline_session:)",
        "\n".join(rows),
        config,
        count=1,
        flags=re.S,
    )
    if count != 1:
        raise SystemExit("compatible_sspanel block not found in template")
    config = re.sub(
        r'(^monitor:\n  listen:)\s*"[^\n]*"',
        r'\1 "${MONITOR_BIND_IP}:28910"',
        config,
        count=1,
        flags=re.M,
    )
    (root / "etc/sbox/config.yaml").write_text(config)
    write_nginx(args.root, args.domain, cdn)
    state = {
        "domain": args.domain,
        "protocols": protocols,
        "ports": ports,
        "node_ids": node_ids,
        "panel_url": args.panel_url,
        "mu_key": args.mu_key,
        "bind_ip": args.bind_ip,
        "monitor_ip": args.monitor_ip,
    }
    state_path = root / "etc/deployment.json"
    state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
    state_path.chmod(0o600)
    print(json.dumps({
        "domain": args.domain,
        "protocols": protocols,
        "ports": ports,
        "node_ids": node_ids,
        "inbound_ids": inbound_ids,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
