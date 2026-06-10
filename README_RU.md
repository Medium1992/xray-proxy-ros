[English](/README.md) | [Русский](/README_RU.md) | [Telegram](https://t.me/+96HVPF3Ww6o3YTNi)

# xray-proxy-ros

> Multi-arch Docker-контейнер для **MikroTik RouterOS** на базе [Xray-core](https://github.com/XTLS/Xray-core). Контейнер принимает прокси-ссылку через ENV, генерирует модульный JSON-конфиг Xray и может работать DNS-сервером с Fake-IP для сценариев роутинга в RouterOS.

[![Docker Pulls](https://img.shields.io/docker/pulls/medium1992/xray-proxy-ros?logo=docker&label=docker%20pulls)](https://hub.docker.com/r/medium1992/xray-proxy-ros)
[![Docker Image Size](https://img.shields.io/docker/image-size/medium1992/xray-proxy-ros/latest?logo=docker&label=image%20size)](https://hub.docker.com/r/medium1992/xray-proxy-ros)
[![License](https://img.shields.io/github/license/Medium1992/xray-proxy-ros)](./LICENSE)
![Platforms](https://img.shields.io/badge/arch-amd64%20%7C%20arm64%20%7C%20armv7%20%7C%20armv5-blue)
[![Telegram](https://img.shields.io/badge/Telegram-group-blue?logo=telegram)](https://t.me/+96HVPF3Ww6o3YTNi)

## ✨ Возможности

- **Multi-arch образ**: `amd64`, `arm64`, `arm/v7`, `arm/v5`.
- **Stable и alpha образы**: `latest` собирается со стабильным релизом Xray-core, `alpha` собирается с последним prerelease Xray-core.
- **Парсер прокси-ссылки** через `LINK`: `vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://` / `hysteria2://`, `wireguard://` / `wg://`.
- **Актуальные транспорты Xray**: TCP, WS, HTTPUpgrade, gRPC, XHTTP, HTTP/2, KCP, QUIC и HTTP/3, если они описаны в ссылке.
- **Fake-IP DNS по умолчанию**: на каждый DNS-запрос контейнер отдает адрес из Fake-IP пула. Этот пул можно смаршрутизировать обратно в контейнер, чтобы дальнейший доступ к ресурсу шел через прокси.
- **Real-IP DNS режим** через `DNS_MODE=real-ip`: выключает Fake-IP ответы и использует параллельные DoH-запросы к Google, Cloudflare и Quad9.
- **Модульный конфиг**: сгенерированные JSON-фрагменты лежат в `/etc/xray/`, туда же можно монтировать свои JSON-файлы.
- **Сетевые правила под RouterOS**: NFTables на `amd64`/`arm64` где доступно, legacy iptables fallback для старых платформ.

> В основном проверяется на RouterOS 7.21+. Нужен пакет `container` и `device-mode container=yes`.

## 🐳 Теги образов

| Тег | Назначение |
|---|---|
| `latest` | Последний стабильный релиз Xray-core. |
| `alpha` | Последний prerelease Xray-core. |
| `vX.Y.Z` | Конкретная версия Xray-core или prerelease, если она собрана workflow. |

Образы публикуются в:

- `ghcr.io/medium1992/xray-proxy-ros`
- `medium1992/xray-proxy-ros`

## ⚙️ Как это работает

При старте entrypoint создает такие фрагменты конфига:

| Файл | Назначение |
|---|---|
| `/etc/xray/20_log.json` | Логи Xray. |
| `/etc/xray/21_dns.json` | DNS в режиме Fake-IP или real-IP. |
| `/etc/xray/22_routing.json` | Правила DNS, Fake-IP и QUIC. |
| `/etc/xray/23_inbounds.json` | Mixed, transparent и DNS inbounds. |
| `/etc/xray/24_outbounds.json` | DNS, direct и block outbounds. |
| `/etc/xray/25_outbound.json` | Прокси outbound, сгенерированный из `LINK`. |

Xray запускается с `/etc/xray/` как директорией multi-file config, поэтому дополнительные смонтированные JSON-файлы могут расширять конфигурацию по правилам Xray.

## 🔧 Переменные окружения

| ENV | По умолчанию | Описание |
|---|---|---|
| `LINK` | пусто | Прокси-ссылка. Поддерживаются схемы: `vless`, `vmess`, `trojan`, `ss`, `hy2`/`hysteria2`, `wireguard`/`wg`. |
| `LOG_LEVEL` | `error` | Уровень логов Xray. [Docs](https://xtls.github.io/ru/config/log.html#logobject). |
| `LOG_ACCESS` | пусто | Путь к access log. Пусто значит поведение Xray по умолчанию. |
| `LOG_ERROR` | пусто | Путь к error log. Пусто значит поведение Xray по умолчанию. |
| `LOG_DNS` | `false` | Включает логирование DNS-запросов в конфиге Xray DNS. [Docs](https://xtls.github.io/ru/config/dns.html#dnsobject). |
| `LOG_MASK` | пусто | Режим маскирования логов Xray, если поддерживается текущим ядром. |
| `DNS_MODE` | `fake-ip` | `fake-ip` выдает адреса из Fake-IP пула. Любое другое значение выключает Fake-IP и возвращает IP-адреса ресурсов через DoH. |
| `FAKE_IP_RANGE` | `198.18.0.0/15` | Диапазон Fake-IP пула. [Docs](https://xtls.github.io/ru/config/fakedns.html). |
| `MUX` | `false` | Включение Xray outbound mux. [Docs](https://xtls.github.io/ru/config/outbound.html#muxobject). |
| `MUX_CONCURRENCY` | `8` | Конкурентность TCP mux. [Docs](https://xtls.github.io/ru/config/outbound.html#muxobject). |
| `MUX_XUDPCONCURRENCY` | `MUX_CONCURRENCY` | Конкурентность UDP mux. [Docs](https://xtls.github.io/ru/config/outbound.html#muxobject). |
| `MUX_XUDPPROXYUDP443` | `reject` | Обработка UDP/443 в Xray mux. [Docs](https://xtls.github.io/ru/config/outbound.html#muxobject). |
| `TPROXY` | `true` | С NFTables: `true` использует Redirect TCP + TProxy UDP, `false` использует Redirect TCP + TUN UDP. |
| `QUIC_DROP` | `false` | `true` добавляет в Xray routing правило блокировки UDP/443. |

## 🛠 Установка в RouterOS

Сначала проверьте, что установлен пакет `container` и включена поддержка контейнеров:

```routeros
/system/device-mode/print
/system/device-mode/update mode=advanced container=yes
```

После команды есть около 5 минут, чтобы подтвердить изменение перезагрузкой питания или нажатием физической кнопки.

Пример установки для RouterOS 7.21+:

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

После этого задайте свою прокси-ссылку в `LINK` и перезапустите контейнер.

## 📝 Заметки

- В Fake-IP режиме Xray DNS возвращает адреса из `FAKE_IP_RANGE`. Этот пул нужно маршрутизировать на IP контейнера, если хотите чтобы запросы к таким ресурсам уходили через прокси.
- Чтобы выключить Fake-IP ответы и возвращать IP-адреса ресурсов через DoH, задайте `DNS_MODE=real-ip`.
- Для проверки prerelease-сборок Xray используйте `ghcr.io/medium1992/xray-proxy-ros:alpha`.
- Контейнер не собирает Xray из исходников, а скачивает официальные архивы Xray-core во время Docker build.

## 💖 Поддержка проекта

Если проект сэкономил время на настройке MikroTik:

- **USDT (TRC20):** `TWDDYD1nk5JnG6FxvEu2fyFqMCY9PcdEsJ`
- [boosty.to/petersolomon/donate](https://boosty.to/petersolomon/donate)

<img width="150" height="150" alt="petersolomon-donate" src="https://github.com/user-attachments/assets/fcf40baa-a09e-4188-a036-7ad3a77f06ea" />
