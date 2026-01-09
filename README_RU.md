[English](/README.md) | [Русский](/README_RU.md)

[Telegram группа](https://t.me/+96HVPF3Ww6o3YTNi)

# 🇷🇺 Описание на русском

**xray-proxy-ros** — это Docker-контейнер на базе [**Xray**](https://github.com/XTLS/Xray-core) для Mikrotik RouterOS.

Цель: сделать простой контейнер который воспринимает ссылки и поддерживает транспорт **XHTTP**

Преимущества:
- Задание ссылки прокси: `vless://`, `vmess://`, `ss://`, `trojan://`; через переменную окружения ENV `LINK`.
- Применения любого вида outbound xray при помощи маунта в папку контейнера `/etc/xray/mount` файла `outbound.json`
- Контейнер также работает в режиме DNS-сервера который выдает на каждый DNS запрос fakeip. Пул fakeip необходимо зароутить на IP контейнера для выхода ресурса через прокси. [Пример описания работы с fakeip](https://github.com/Medium1992/Mihomo-FakeIP-RoS)(Позже добавлю описание тут).

> Если у вас выполнен маунт файла `outbound.json` и задана ссылка через `LINK`, то активный прокси будет из маунт файла `outbound.json`.

## Описание ENVs

| Переменная             | По умолчанию                         | Описание |
|------------------------|---------------------------------------|---------|
| `LINK`                 | —                                     | Прокси-ссылка `vless://` или `vmess://` или `ss://` или `trojan://`. |
| `LOG_LEVEL`            | `error`                               | Уровень логов `Xray` [DOCs](https://xtls.github.io/ru/config/log.html#logobject). |
| `FAKE_IP_RANGE`        | `198.18.0.0/15`                       | Диапазон Fake-IP пула [DOCs](https://xtls.github.io/ru/config/fakedns.html) |
| `MUX`                  | `false`                               | Включение мультиплексирования [DOCs](https://xtls.github.io/ru/config/outbound.html#muxobject) |
| `MUX_CONCURRENCY`      | `8`                                   | Максимальное количество одновременных TCP соединений [DOCs](https://xtls.github.io/ru/config/outbound.html#muxobject)|
| `MUX_XUDPCONCURRENCY`  | `MUX_CONCURRENCY`                     | Максимальное количество одновременных UDP соединений [DOCs](https://xtls.github.io/ru/config/outbound.html#muxobject) |
| `MUX_XUDPPROXYUDP443`  | `reject`                              | Управление обработкой проксируемого трафика UDP/443 (QUIC) [DOCs](https://xtls.github.io/ru/config/outbound.html#muxobject) |
| `IPTABLES`             | `false`                               | IPtables используется всегда в RoS<7.21 и в RoS>=7.21 архитектуры `arm32`. В RoS>=7.21 архитектуры `arm64` и `adm64` по умолчанию в контейнере используется `NFTables`, если ENV `IPTABLES` не задан `true` |
| `QUIC_DROP`            | `false`                               | `true` добавляет правило дропа QUIC(443/UDP) в правилах routing Xray. |

> По предложениям и замечаниям пишите в [Telegram](https://t.me/Medium_csgo).

## Пример файла outbound.json который маунтиться в контейнер

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

> Вы можете посмотреть примеры клиентских outbound в [примерах](https://github.com/XTLS/Xray-examples). Или выполнить outbound сами по [документации Xray](https://xtls.github.io/ru/config/).

## Пример установки на RouterOS Mikrotik.

Предварительно убедитесь что у вас установлен пакет `container`, а также разрешены нужные функции device-mode.
```bash
/system/device-mode/print
```
Разрешите device-mode если необходимо.
Следуйте указаниям после выполнения команды ниже, даётся 5 минут на перезагрузку электропитанием или кратковременно нажать на любую кнопку на устройстве, я рекомендую использовать любую кнопку)
```bash
/system/device-mode/update mode=advanced container=yes
```

Установка без роутинга с синтаксисом для версии RouterOS 7.21, при установке на другую версию синтаксис некоторых команд может отличаться.
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
/container/envs/add key=IPTABLES list=XrayProxyRoS value=false
/container/envs/add key=QUIC_DROP list=XrayProxyRoS value=true
/file/add name=xray_outbound type=directory
/container/mounts/add src=/xray_outbound/ dst=/etc/xray/mount/ list=xray_outbound comment="XrayProxyRoS"
/container/add remote-image="ghcr.io/medium1992/xray-proxy-ros" envlists=XrayProxyRoS mountlists=xray_outbound interface=XrayProxyRoS root-dir=/Containers/XrayProxyRoS start-on-boot=yes comment="XrayProxyRoS"
```

## 💖 Поддержка проекта

Если вам полезен этот проект, вы можете поддержать его донатом:  
**USDT(TRC20): TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ**


