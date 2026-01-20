[English](/README.md) | [Russian](/README_RU.md)

[Telegram group](https://t.me/+96HVPF3Ww6o3YTNi)

# 🇬🇧 Description in Russian

**xray-proxy-ros** is a Docker container based on [**Xray**](https://github.com/XTLS/Xray-core) for Mikrotik RouterOS.

Purpose: to create a simple container that accepts links and supports **XHTTP** transport.

Advantages:
- Setting proxy links: `vless://`, `vmess://`, `ss://`, `trojan://`; via the ENV `LINK` environment variable.
- Flexible configuration extension by mounting json files to the `/etc/xray/` folder in accordance with the [documentation](https://xtls.github.io/ru/config/features/multiple.html). By default, the files `20_log.json`, `21_dns.json`, `22_routing.json`, `23_inbounds.json`, `24_outbounds.json`, and `25_outbound.json` are created (proxy from the ENV `LINK` reference, if it is not empty).
- The container also works in DNS server mode, which returns a fake IP address by default for each DNS request. The fake IP pool must be registered on the container's IP address for the resource to exit through the proxy. [Example of working with fake IP addresses](https://github.com/Medium1992/Mihomo-FakeIP-RoS). If you want the xray DNS server to work without returning fakeip, set ENV `DNS_MODE`=real-ip, which will enable parallel DoH requests to Google, CloudFlare, and Quad9.

## Description of ENVs

| Variable             | Default                         | Description |
|------------------------|---------------------------------------|---------|
| `LINK`                 | —                                     | Proxy link `vless://` or `vmess://` or `ss://` or `trojan://`. |
| `LOG_LEVEL`            | `error`                               | `Xray` log level [DOCs](https://xtls.github.io/en/config/log.html#logobject). |
| `DNS_MODE`             | `fake-ip`                             | If fake-ip is set, fakeip will be returned for each DNS request. Any value other than `fake-ip` will disable them and enable parallel DoH requests to Google, CloudFlare, and Quad9 with real IP domains returned. |
| `FAKE_IP_RANGE`        | `198.18.0.0/15`                       | Fake-IP pool range [DOCs](https://xtls.github.io/en/config/fakedns.html) |
| `MUX`                  | `false`                               | Enable multiplexing [DOCs](https://xtls.github.io/en/config/outbound.html#muxobject) |
| `MUX_CONCURRENCY`      | `8`                                   | Maximum number of concurrent TCP connections [DOCs](https://xtls.github.io/en/config/outbound.html#muxobject)|
| `MUX_XUDPCONCURRENCY`  | `MUX_CONCURRENCY`                     | Maximum number of concurrent UDP connections [DOCs](https://xtls.github.io/en/config/outbound.html#muxobject) |
| `MUX_XUDPPROXYUDP443`  | `reject`                              | Control of proxied UDP/443 (QUIC) traffic handling [DOCs](https://xtls.github.io/en/config/outbound.html#muxobject) |
| `TPROXY`               | `true`                                | In RoS>=7. 21 architectures `arm64` and `adm64`, `NFTables` is used by default in the container. If ENV `TPROXY` is set to `true`, inbound TProxy(tcp,udp) will be used; if set to `false`, inbound Redirect(tcp)+TUN(udp) will be used. |
| `QUIC_DROP`            | `false`                               | `true` adds a QUIC(443/UDP) drop rule to the Xray routing rules. |

> Please send your suggestions and comments to [Telegram](https://t.me/Medium_csgo).

## Example installation on Mikrotik RouterOS.

First, make sure you have the `container` package installed and that the necessary device-mode functions are enabled.
```bash
/system/device-mode/print
```
Enable device-mode if necessary.
Follow the instructions after executing the command below. You have 5 minutes to reboot the power supply or briefly press any button on the device (I recommend using any button).
```bash
/system/device-mode/update mode=advanced container=yes
```

Installation without routing with syntax for RouterOS version 7.21. When installing on a different version, the syntax of some commands may differ.
```bash
/interface/veth/add name=XrayProxyRoS address=192.168.255.14/30 gateway=192.168.255.13
/ip/address/add address=192.168.255.13/30 interface=XrayProxyRoS
/ip/dns/forwarders/add name=XrayProxyRoS dns-servers=192.168.255.14 verify-doh-cert=no
/routing/table/add name=XrayProxyRoS fib comment="XrayProxyRoS"
/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.255.14 routing-table=XrayProxyRoS comment="XrayProxyRoS"
/ip/route/add dst-address=198.18.0.0/15 gateway=192.168.255.14 comment="XrayProxyRoS"
/container/envs/add key=LINK list=XrayProxyRoS value=""
/container/envs/add key=LOG_LEVEL list=XrayProxyRoS value=error
/container/envs/add key=DNS_MODE list=XrayProxyRoS value="fake-ip"
/container/envs/add key=FAKE_IP_RANGE list=XrayProxyRoS value=198.18.0.0/15
/container/envs/add key=MUX list=XrayProxyRoS value=false
/container/envs/add key=MUX_CONCURRENCY list=XrayProxyRoS value=8
/container/envs/add key=MUX_XUDPCONCURRENCY list=XrayProxyRoS value=""
/container/envs/add key=MUX_XUDPPROXYUDP443 list=XrayProxyRoS value=reject
/container/envs/add key=TPROXY list=XrayProxyRoS value=true
/container/envs/add key=QUIC_DROP list=XrayProxyRoS value=true
/file/add name=xray_configs type=directory
/container/mounts/add src=/xray_configs/ dst=/etc/xray/ list=xray_configs comment="XrayProxyRoS"
/container/add remote-image=“ghcr.io/medium1992/xray-proxy-ros” envlists=XrayProxyRoS mountlists=xray_configs interface=XrayProxyRoS root-dir=/Containers/XrayProxyRoS start-on-boot=yes comment="XrayProxyRoS"
```

## 💖 Support the project

If you find this project useful, you can support it with a donation:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**

**https://boosty.to/petersolomon/donate**

<img width="150" height="150" alt="petersolomon-donate" src="https://github.com/user-attachments/assets/fcf40baa-a09e-4188-a036-7ad3a77f06ea" />
