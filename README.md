[English](/README.md) | [Russian](/README_RU.md) | [Telegram](https://t.me/+96HVPF3Ww6o3YTNi)

# xray-proxy-ros

> Multi-arch Docker container for **MikroTik RouterOS** based on [Xray-core](https://github.com/XTLS/Xray-core). It accepts a proxy link through ENV, generates modular Xray JSON config, and routes RouterOS Fake-IP traffic through the proxy.

[![Docker Pulls](https://img.shields.io/docker/pulls/medium1992/xray-proxy-ros?logo=docker&label=docker%20pulls)](https://hub.docker.com/r/medium1992/xray-proxy-ros)
[![Docker Image Size](https://img.shields.io/docker/image-size/medium1992/xray-proxy-ros/latest?logo=docker&label=image%20size)](https://hub.docker.com/r/medium1992/xray-proxy-ros)
[![License](https://img.shields.io/github/license/Medium1992/xray-proxy-ros)](./LICENSE)
![Platforms](https://img.shields.io/badge/arch-amd64%20%7C%20arm64%20%7C%20armv7%20%7C%20armv5-blue)
[![Telegram](https://img.shields.io/badge/Telegram-group-blue?logo=telegram)](https://t.me/+96HVPF3Ww6o3YTNi)

## Features

- **Multi-arch image**: `amd64`, `arm64`, `arm/v7`, `arm/v5`.
- **Stable and alpha builds**: `latest` follows stable Xray releases, `alpha` follows Xray prereleases.
- **Proxy link parser** via `LINK`: `vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://` / `hysteria2://`, `wireguard://` / `wg://`.
- **Modern Xray transports** including TCP, WS, HTTPUpgrade, gRPC, XHTTP, HTTP/2, KCP, QUIC and HTTP/3 where supported by the link.
- **Fake-IP DNS mode** by default: RouterOS routes the Fake-IP pool to the container and Xray sends that traffic through the proxy.
- **Real-IP DNS mode** via `DNS_MODE=real-ip`: parallel DoH queries to Google, Cloudflare and Quad9.
- **Modular config**: generated JSON fragments live in `/etc/xray/`, and you can mount extra JSON files there.
- **RouterOS-friendly network rules**: NFTables on `amd64`/`arm64` where available, legacy iptables fallback for older platforms.
- **Fast stop handling**: the container exits cleanly enough for RouterOS without waiting for long shutdown chains.

> Tested primarily with RouterOS 7.21+. Requires the `container` package and `device-mode container=yes`.

## Image Tags

| Tag | Purpose |
|---|---|
| `latest` | Latest stable Xray-core release. |
| `alpha` | Latest Xray-core prerelease. |
| `vX.Y.Z` | Specific Xray-core version or prerelease, when built by workflow. |

Images are published to:

- `ghcr.io/medium1992/xray-proxy-ros`
- `medium1992/xray-proxy-ros`

## How It Works

At startup the entrypoint creates these config fragments:

| File | Purpose |
|---|---|
| `/etc/xray/20_log.json` | Xray logs. |
| `/etc/xray/21_dns.json` | Fake-IP or real-IP DNS. |
| `/etc/xray/22_routing.json` | DNS, Fake-IP and QUIC routing rules. |
| `/etc/xray/23_inbounds.json` | Mixed, transparent and DNS inbounds. |
| `/etc/xray/24_outbounds.json` | DNS, direct and block outbounds. |
| `/etc/xray/25_outbound.json` | Proxy outbound generated from `LINK`. |

Xray is started with `/etc/xray/` as a multi-file config directory, so additional mounted JSON files can extend or override the generated setup according to Xray's multi-file config rules.

## Environment Variables

| ENV | Default | Description |
|---|---|---|
| `LINK` | empty | Proxy URL. Supported schemes: `vless`, `vmess`, `trojan`, `ss`, `hy2`/`hysteria2`, `wireguard`/`wg`. |
| `LOG_LEVEL` | `error` | Xray log level. |
| `LOG_ACCESS` | empty | Access log path. Empty means Xray default. |
| `LOG_ERROR` | empty | Error log path. Empty means Xray default. |
| `LOG_DNS` | `false` | Enables DNS query logging in Xray DNS config. |
| `LOG_MASK` | empty | Xray log masking mode, if supported by the current core. |
| `DNS_MODE` | `fake-ip` | `fake-ip` returns Fake-IP addresses. Any other value enables real-IP DoH mode. |
| `FAKE_IP_RANGE` | `198.18.0.0/15` | Fake-IP pool routed to the container. |
| `MUX` | `false` | Enables Xray outbound mux. |
| `MUX_CONCURRENCY` | `8` | TCP mux concurrency. |
| `MUX_XUDPCONCURRENCY` | `MUX_CONCURRENCY` | UDP mux concurrency. |
| `MUX_XUDPPROXYUDP443` | `reject` | Xray mux UDP/443 handling. |
| `TPROXY` | `true` | With NFTables: `true` uses Redirect TCP + TProxy UDP, `false` uses Redirect TCP + TUN UDP. |
| `QUIC_DROP` | `false` | `true` adds an Xray routing rule that blocks UDP/443. |

## RouterOS Install

First, make sure the `container` package is installed and container support is enabled:

```routeros
/system/device-mode/print
/system/device-mode/update mode=advanced container=yes
```

You have about 5 minutes to confirm the change by power-cycling the device or pressing a physical button.

Example install for RouterOS 7.21+:

```routeros
/interface/veth/add name=XrayProxyRoS address=192.168.255.14/30 gateway=192.168.255.13
/ip/address/add address=192.168.255.13/30 interface=XrayProxyRoS
/ip/dns/forwarders/add name=XrayProxyRoS dns-servers=192.168.255.14 verify-doh-cert=no
/routing/table/add name=XrayProxyRoS fib comment="XrayProxyRoS"
/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.255.14 routing-table=XrayProxyRoS comment="XrayProxyRoS"
/ip/route/add dst-address=198.18.0.0/15 gateway=192.168.255.14 comment="XrayProxyRoS"
/container/envs/add key=LINK list=XrayProxyRoS value=""
/container/envs/add key=LOG_LEVEL list=XrayProxyRoS value=error
/container/envs/add key=DNS_MODE list=XrayProxyRoS value=fake-ip
/container/envs/add key=FAKE_IP_RANGE list=XrayProxyRoS value=198.18.0.0/15
/container/envs/add key=MUX list=XrayProxyRoS value=false
/container/envs/add key=MUX_CONCURRENCY list=XrayProxyRoS value=8
/container/envs/add key=MUX_XUDPCONCURRENCY list=XrayProxyRoS value=""
/container/envs/add key=MUX_XUDPPROXYUDP443 list=XrayProxyRoS value=reject
/container/envs/add key=TPROXY list=XrayProxyRoS value=true
/container/envs/add key=QUIC_DROP list=XrayProxyRoS value=true
/file/add name=xray_configs type=directory
/container/mounts/add src=/xray_configs/ dst=/etc/xray/ list=xray_configs comment="XrayProxyRoS"
/container/add remote-image=ghcr.io/medium1992/xray-proxy-ros:latest envlists=XrayProxyRoS mountlists=xray_configs interface=XrayProxyRoS root-dir=/Containers/XrayProxyRoS start-on-boot=yes comment="XrayProxyRoS"
```

Then put your proxy URL into `LINK` and restart the container.

## Notes

- In Fake-IP mode, route `FAKE_IP_RANGE` to the container IP. This is what makes domain-selected traffic leave through Xray.
- For real DNS answers, set `DNS_MODE=real-ip`.
- To test prerelease Xray builds, use `ghcr.io/medium1992/xray-proxy-ros:alpha`.
- The container does not build Xray itself; it downloads official Xray-core release archives during Docker build.

## Support

If this project saved you time configuring MikroTik:

- **USDT (TRC20):** `TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ`
- [boosty.to/petersolomon/donate](https://boosty.to/petersolomon/donate)

<img width="150" height="150" alt="petersolomon-donate" src="https://github.com/user-attachments/assets/fcf40baa-a09e-4188-a036-7ad3a77f06ea" />
