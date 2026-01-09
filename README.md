[English](/README.md) | [Русский](/README_RU.md)

[Telegram group](https://t.me/+96HVPF3Ww6o3YTNi)

# 🇬🇧 Description in English

**xray-proxy-ros** is a Docker container based on [**Xray**](https://github.com/XTLS/Xray-core) for Mikrotik RouterOS.

Goal: to make a simple container that accepts links and supports the **XHTTP** transport.

Advantages:
- Setting a proxy link: `vless://`, `vmess://`, `ss://`, `trojan://` via the ENV environment variable `LINK`.
- Applying any type of Xray outbound by mounting the file `outbound.json` into the container directory `/etc/xray/mount`.
- The container also works in DNS server mode, returning a fakeip for each DNS request. The fakeip pool must be routed to the container IP in order to access resources through the proxy. [Example of working with fakeip](https://github.com/Medium1992/Mihomo-FakeIP-RoS) (I will add a description here later).

> If you have mounted the `outbound.json` file and a link is set via `LINK`, then the active proxy will be taken from the mounted `outbound.json` file.

## ENV description

| Variable               | Default                               | Description |
|------------------------|----------------------------------------|------------|
| `LINK`                 | —                                      | Proxy link `vless://` or `vmess://` or `ss://` or `trojan://`. |
| `LOG_LEVEL`            | `error`                                | `Xray` log level [DOCs](https://xtls.github.io/en/config/log.html#logobject). |
| `FAKE_IP_RANGE`        | `198.18.0.0/15`                        | Fake-IP pool range [DOCs](https://xtls.github.io/en/config/fakedns.html) |
| `MUX`                  | `false`                                | Enable multiplexing [DOCs](https://xtls.github.io/en/config/outbound.html#muxobject) |
| `MUX_CONCURRENCY`      | `8`                                    | Maximum number of concurrent TCP connections [DOCs](https://xtls.github.io/en/config/outbound.html#muxobject) |
| `MUX_XUDPCONCURRENCY`  | `MUX_CONCURRENCY`                      | Maximum number of concurrent UDP connections [DOCs](https://xtls.github.io/en/config/outbound.html#muxobject) |
| `MUX_XUDPPROXYUDP443`  | `reject`                               | Control handling of proxied UDP/443 (QUIC) traffic [DOCs](https://xtls.github.io/en/config/outbound.html#muxobject) |
| `TPROXY`               | `true`                                 | In RoS>=7.21 on `arm64` and `adm64` architectures, `NFTables` is used by default in the container. If the `TPROXY` ENV is set to `true`, inbound TProxy (tcp, udp) will be used; if set to `false`, inbound Redirect (tcp) + TUN (udp) will be used |
| `QUIC_DROP`            | `false`                                | `true` adds a rule to drop QUIC (443/UDP) in Xray routing rules. |

> For suggestions and comments, write in [Telegram](https://t.me/Medium_csgo).

## Example of an outbound.json file mounted into the container

```json
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "",
        "port": 443,
        "users": [
          {
            "id": "",
            "encryption": "none",
            "flow": "",
            "level": 0
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "xhttpSettings": {
      "host": "",
      "mode": "auto"
    },
    "realitySettings": {
      "serverName": "",
      "fingerprint": "chrome",
      "shortId": "",
      "password": "",
      "spiderX": "/"
    }
  }
}
```

> You can view examples of client outbounds in the [examples](https://github.com/XTLS/Xray-examples). Or create your own outbound according to the Xray [documentation](https://xtls.github.io/ru/config/).

## Installation example on RouterOS Mikrotik

First, make sure that the `container` package is installed and that the required device-mode features are allowed.
```bash
/system/device-mode/print
```
Enable device-mode if necessary.
Follow the instructions after running the command below: you are given 5 minutes to reboot by power cycling or briefly pressing any button on the device (I recommend using any button).
```bash
/system/device-mode/update mode=advanced container=yes
```

Installation without routing, using the syntax for RouterOS version 7.21; when installing on another version, the syntax of some commands may differ.

```bash
/interface/veth/add name=XrayProxyRoS address=192.168.255.14/30 gateway=192.168.255.13
/ip/address/add address=192.168.255.13/30 interface=XrayProxyRoS
/ip/dns/forwarders/add name=XrayProxyRoS dns-servers=192.168.255.14 verify-doh-cert=no
/routing/table/add name=XrayProxyRoS fib comment="XrayProxyRoS"
/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.255.14 routing-table=XrayProxyRoS comment="XrayProxyRoS"
/ip/route/add dst-address=198.18.0.0/15 gateway=192.168.255.14 comment="XrayProxyRoS"
/container/envs/add key=LINK list=XrayProxyRoS value=""
/container/envs/add key=LOG_LEVEL list=XrayProxyRoS value=error
/container/envs/add key=FAKE_IP_RANGE list=XrayProxyRoS value=198.18.0.0/15
/container/envs/add key=MUX list=XrayProxyRoS value=false
/container/envs/add key=MUX_CONCURRENCY list=XrayProxyRoS value=8
/container/envs/add key=MUX_XUDPCONCURRENCY list=XrayProxyRoS value=""
/container/envs/add key=MUX_XUDPPROXYUDP443 list=XrayProxyRoS value=reject
/container/envs/add key=TPROXY list=XrayProxyRoS value=true
/container/envs/add key=QUIC_DROP list=XrayProxyRoS value=true
/file/add name=xray_outbound type=directory
/container/mounts/add src=/xray_outbound/ dst=/etc/xray/mount/ list=xray_outbound comment="XrayProxyRoS"
/container/add remote-image="ghcr.io/medium1992/xray-proxy-ros" envlists=XrayProxyRoS mountlists=xray_outbound interface=XrayProxyRoS root-dir=/Containers/XrayProxyRoS start-on-boot=yes comment="XrayProxyRoS"
```

## 💖 Project support
If this project is useful to you, you can support it with a donation:
**USDT (TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**

**https://boosty.to/petersolomon/donate**

<img width="150" height="150" alt="petersolomon-donate" src="https://github.com/user-attachments/assets/fcf40baa-a09e-4188-a036-7ad3a77f06ea" />


