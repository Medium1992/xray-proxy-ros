#!/bin/sh

log() { echo "[$(date +'%H:%M:%S')] $*"; }

SHUTTING_DOWN=0
XRAY_PID=""

graceful_shutdown() {
  trap - TERM INT
  [ "$SHUTTING_DOWN" = 1 ] && exit 0
  SHUTTING_DOWN=1
  log "Stop signal received, exiting..."
  [ -n "${XRAY_PID:-}" ] && kill -TERM "$XRAY_PID" >/dev/null 2>&1 || true
  exit 0
}
trap graceful_shutdown TERM INT

sleep 1

set_kernel_param() {
  [ -w "$1" ] && printf '%s\n' "$2" > "$1" 2>/dev/null || true
}

set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 86400
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_syn_sent 5
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_syn_recv 5
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_fin_wait 10
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close_wait 10
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_last_ack 10
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait 10
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close 10
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_unacknowledged 300
set_kernel_param /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream 180

for iface in $(ip -o link show up | awk -F': ' '/link\/ether/ {gsub(/@.*$/,"",$2); if($2!="lo") print $2}'); do
tc qdisc add dev $iface root fq_codel >/dev/null 2>&1;
ip link set dev $iface multicast off >/dev/null 2>&1;
done

set -eu
TPROXY="${TPROXY:-true}"
DNS_MODE="${DNS_MODE:-fake-ip}"
FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
LOG_ACCESS="${LOG_ACCESS:-}"
LOG_ERROR="${LOG_ERROR:-}"
LOG_LEVEL="${LOG_LEVEL:-error}"
LOG_DNS="${LOG_DNS:-false}"
LOG_MASK="${LOG_MASK:-}"
LINK="${LINK:-}"
MUX="${MUX:-false}"
MUX_CONCURRENCY="${MUX_CONCURRENCY:-8}"
MUX_XUDPCONCURRENCY="${MUX_XUDPCONCURRENCY:-$MUX_CONCURRENCY}"
MUX_XUDPPROXYUDP443="${MUX_XUDPPROXYUDP443:-reject}"
QUIC_DROP="${QUIC_DROP:-false}"

CIDR_MASK="${FAKE_IP_RANGE##*/}"
FAKE_POOL_SIZE=$(( (1 << (32 - CIDR_MASK)) - 2 ))

if lsmod | grep -q '^nft_tproxy'; then
  USE_NFT=true
else
  USE_NFT=false
fi

if [ "$USE_NFT" = "false" ]; then
  if ! apk info -e iptables iptables-legacy >/dev/null; then
    echo "Install iptables"
    apk add --no-cache iptables iptables-legacy >/dev/null 2>&1
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore
  fi
else
  if ! apk info -e nftables >/dev/null; then
    echo "Install nftables"
    apk add --no-cache nftables >/dev/null 2>&1
  fi
  if apk info -e iptables iptables-legacy >/dev/null; then
    echo "Delete iptables"
    apk del iptables iptables-legacy >/dev/null 2>&1
  fi
fi

mkdir -p /etc/xray/ /dev/shm

install_config_if_changed() {
    src="$1"
    dest="$2"

    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        rm -f "$src"
    else
        mv "$src" "$dest"
    fi
}

remove_config_if_exists() {
    [ -e "$1" ] && rm -f "$1"
}

first_iface() {
  ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d'@' -f1 | head -n1
}
iface=$(first_iface)
iface_cidr=$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}')
iface_ip=$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}' | cut -d/ -f1)
gateway=$(ip route show default dev "$iface" | awk '{print $3; exit}')

urldecode() {
    printf '%b' "$(printf '%s' "$1" | sed 's/%/\\x/g')"
}

tolower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

json_object_or_empty() {
    if printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '%s' "$1"
    else
        printf '{}'
    fi
}

json_value_or_empty_object() {
    if printf '%s' "$1" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$1"
    else
        printf '{}'
    fi
}

json_object_or_empty_string() {
    if printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '%s' "$1"
    else
        printf ''
    fi
}

bool_or_empty() {
    case "$1" in
        1|true|TRUE|True|yes|YES|Yes) printf 'true' ;;
        0|false|FALSE|False|no|NO|No) printf 'false' ;;
    esac
}

int_or_default() {
    case "$1" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *) printf '%s' "$1" ;;
    esac
}

trim() {
    s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

json_value() {
    v="$(trim "$1")"

    case "$v" in
        true|false)
            printf '%s' "$v"
            ;;
        *-*)
            printf '"%s"' "$v"
            ;;
        *.*)
            printf '%s' "${v%%.*}"
            ;;
        ''|*[!0-9]*)
            printf '"%s"' "$v"
            ;;
        *)
            printf '%s' "$v"
            ;;
    esac
}

normalize_xray_numbers() {
    sed -E 's/([: ,])([0-9]+)\.0([^0-9])/ \1\2\3/g'
}

b64_normalize() {
    s="$(printf '%s' "$1" | tr -d '\r\n ' | tr '_-' '/+')"

    mod=$(( ${#s} % 4 ))
    if [ "$mod" -eq 2 ]; then
        s="${s}=="
    elif [ "$mod" -eq 3 ]; then
        s="${s}="
    fi

    printf '%s' "$s"
}

xhttp_dsl_to_json() {
    INPUT="$1"
    BODY="$(printf '%s' "$INPUT" | sed 's/^{//; s/}$//')"
    OUT="{"
    FIRST=true
    LEVEL=0
    BUF=""
    while IFS= read -r -n1 c; do
        case "$c" in
            '{') LEVEL=$((LEVEL+1)) ;;
            '}') LEVEL=$((LEVEL-1)) ;;
        esac

        if [ "$c" = "," ] && [ "$LEVEL" -eq 0 ]; then
            key="$(trim "${BUF%%=*}")"
            val="$(trim "${BUF#*=}")"

            [ "$FIRST" = false ] && OUT="$OUT,"
            FIRST=false

            case "$val" in
                \{*\})
                    OUT="$OUT\"$key\":$(xhttp_dsl_to_json "$val")"
                    ;;
                *)
                    OUT="$OUT\"$key\":$(json_value "$val")"
                    ;;
            esac

            BUF=""
        else
            BUF="$BUF$c"
        fi
    done <<EOF
$BODY
EOF
    if [ -n "$BUF" ]; then
        key="$(trim "${BUF%%=*}")"
        val="$(trim "${BUF#*=}")"

        [ "$FIRST" = false ] && OUT="$OUT,"

        case "$val" in
            \{*\})
                OUT="$OUT\"$key\":$(xhttp_dsl_to_json "$val")"
                ;;
            *)
                OUT="$OUT\"$key\":$(json_value "$val")"
                ;;
        esac
    fi

    OUT="$OUT}"
    printf '%s' "$OUT"
}

parse() {

    LINK_NOPATH="$(printf '%s' "$LINK" | cut -d'#' -f1)"
    PROTOCOL="$(tolower "$(printf '%s' "$LINK_NOPATH" | cut -d':' -f1)")"
    LINK_NOPATH="${LINK_NOPATH#*://}"
    XRAY_PROTOCOL="$PROTOCOL"
    [ "$PROTOCOL" = "ss" ] && XRAY_PROTOCOL="shadowsocks"
    [ "$PROTOCOL" = "hy2" ] && XRAY_PROTOCOL="hysteria"
    [ "$PROTOCOL" = "hysteria2" ] && XRAY_PROTOCOL="hysteria"
    [ "$PROTOCOL" = "wg" ] && XRAY_PROTOCOL="wireguard"
    if [ "$PROTOCOL" != "vmess" ]; then
        CREDS="${LINK_NOPATH%@*}"
        REST="${LINK_NOPATH##*@}"

        if [ "$PROTOCOL" = "ss" ] && [ "$CREDS" = "$REST" ]; then
            ORIG_QUERY="$(printf '%s' "$LINK_NOPATH" | cut -s -d'?' -f2)"
            SS_BODY="$(printf '%s' "$LINK_NOPATH" | cut -d'?' -f1)"
            SS_FULL_DECODED="$(printf '%s' "$(b64_normalize "$SS_BODY")" | base64 -d 2>/dev/null || true)"
            if printf '%s' "$SS_FULL_DECODED" | grep -q '@'; then
                CREDS="${SS_FULL_DECODED%@*}"
                REST="${SS_FULL_DECODED##*@}"
                [ -n "$ORIG_QUERY" ] && REST="${REST}?${ORIG_QUERY}"
            fi
        fi

        HOSTPORT="$(printf '%s' "$REST" | cut -d'?' -f1 | cut -d'/' -f1)"
        QUERY="$(printf '%s' "$REST" | cut -s -d'?' -f2)"
        QUERY="$(printf '%s' "$QUERY" | cut -d'#' -f1)"

        case "$HOSTPORT" in
            \[*\]*)
                ADDRESS="${HOSTPORT%%]*}"
                ADDRESS="${ADDRESS#\[}"
                PORT="${HOSTPORT##*:}"
                ;;
            *:*)
                ADDRESS="${HOSTPORT%:*}"
                PORT="${HOSTPORT##*:}"
                ;;
            *)
                ADDRESS="$HOSTPORT"
                PORT=""
                ;;
        esac
        PORT="$(printf '%s' "$PORT" | tr -cd '0-9')"
    fi

    UUID=""
    PASSWORD=""
    METHOD=""
    EMAIL=""

    SS_LEVEL="0"
    TROJAN_LEVEL="0"

    NETWORK="raw"
    SECURITY="none"
    VLESS_ENCRYPTION="none"
    VLESS_FLOW=""
    VLESS_LEVEL="0"

    RAW_HEADERTYPE="none"
    RAW_USED=false

    XHTTP_HOST=""
    XHTTP_PATH=""
    XHTTP_MODE=""
    XHTTP_EXTRA=""
    XHTTP_USED=false

    WS_PATH=""
    WS_HOST=""
    WS_HEADERS=""
    WS_HEARTBEAT=""
    WS_USED=false

    GRPC_SERVICE_NAME=""
    GRPC_AUTHORITY=""
    GRPC_USER_AGENT=""
    GRPC_MULTI_MODE=""
    GRPC_IDLE_TIMEOUT=""
    GRPC_HEALTH_CHECK_TIMEOUT=""
    GRPC_PERMIT_WITHOUT_STREAM=""
    GRPC_INITIAL_WINDOWS_SIZE=""
    GRPC_USED=false

    KCP_MTU=""
    KCP_TTI=""
    KCP_UPLINK=""
    KCP_DOWNLINK=""
    KCP_CONGESTION=""
    KCP_READ_BUF=""
    KCP_WRITE_BUF=""
    KCP_SEED=""
    KCP_HEADER_TYPE=""
    KCP_HEADER_DOMAIN=""
    KCP_USED=false

    FINALMASK_JSON=""
    FINALMASK_USED=false

    HTTPUP_PATH=""
    HTTPUP_HOST=""
    HTTPUP_HEADERS=""
    HTTPUP_USED=false

    HY2_AUTH=""
    HY2_OBFS=""
    HY2_OBFS_PASSWORD=""
    HY2_USED=false

    TLS_SERVER_NAME=""
    TLS_ALPN=""
    TLS_FINGERPRINT=""
    TLS_VERIFY_NAMES=""
    TLS_PINNED_CERT=""
    HY2_PIN_SHA256=""
    TLS_DISABLE_SYSTEM_ROOT=""
    TLS_SESSION_RESUME=""
    TLS_MIN_VERSION=""
    TLS_MAX_VERSION=""
    TLS_CIPHER_SUITES=""
    TLS_CURVE_PREFS=""
    TLS_MASTER_KEY_LOG=""
    TLS_ECH_CONFIG=""
    TLS_USED=false

    REALITY_SERVER_NAME=""
    REALITY_FINGERPRINT=""
    REALITY_SHORT_ID=""
    REALITY_PASSWORD=""
    REALITY_SPIDER_X=""
    REALITY_MLDSA65_VERIFY=""
    REALITY_USED=false


    VMESS_SECURITY="auto"
    VMESS_UUID=""
    VMESS_LEVEL="0"

    WG_SECRET_KEY=""
    WG_PUBLIC_KEY=""
    WG_ADDRESS=""
    WG_ALLOWED_IPS=""
    WG_PRESHARED_KEY=""
    WG_KEEPALIVE=""
    WG_MTU=""
    WG_WORKERS=""
    WG_RESERVED=""

    case "$PROTOCOL" in
        vless)
            UUID="$CREDS"
            ;;
        trojan)
            PASSWORD="$CREDS"
            ;;
        ss)
            SS_CLEAN="$(b64_normalize "$CREDS")"

            SS_DECODED="$(printf '%s' "$SS_CLEAN" | base64 -d 2>/dev/null || true)"
            [ -z "$SS_DECODED" ] && SS_DECODED="$CREDS"

            METHOD="$(printf '%s' "$SS_DECODED" | cut -d':' -f1)"
            PASSWORD="$(printf '%s' "$SS_DECODED" | cut -d':' -f2-)"
            ;;
        hy2|hysteria2)
            HY2_AUTH="$CREDS"
            HY2_USED=true
            ;;
        wireguard|wg)
            WG_SECRET_KEY="$(urldecode "$CREDS")"
            ;;
    esac

    if [ "$PROTOCOL" = "vmess" ]; then
        PAYLOAD="$(printf '%s' "$LINK_NOPATH" | cut -d'?' -f1)"
        JSON="$(printf '%s' "$(b64_normalize "$PAYLOAD")" | base64 -d 2>/dev/null || true)"

        ADDRESS="$(printf '%s' "$JSON" | jq -r '.add // empty' 2>/dev/null || true)"
        PORT="$(printf '%s' "$JSON" | jq -r '.port // empty' 2>/dev/null | tr -cd '0-9' || true)"
        VMESS_UUID="$(printf '%s' "$JSON" | jq -r '.id // empty' 2>/dev/null || true)"

        NETWORK="$(printf '%s' "$JSON" | jq -r '.net // empty' 2>/dev/null || true)"
        SECURITY="$(printf '%s' "$JSON" | jq -r '.tls // empty' 2>/dev/null || true)"
        [ -z "$SECURITY" ] && SECURITY="none"

        VMESS_SECURITY="$(printf '%s' "$JSON" | jq -r '.scy // empty' 2>/dev/null || true)"
        [ -z "$VMESS_SECURITY" ] && VMESS_SECURITY="auto"

        VMESS_HEADER_TYPE="$(printf '%s' "$JSON" | jq -r '.type // empty' 2>/dev/null || true)"

        VMESS_LEVEL="$(printf '%s' "$JSON" | jq -r '.level // empty' 2>/dev/null | tr -cd '0-9' || true)"
        [ -z "$VMESS_LEVEL" ] && VMESS_LEVEL="0"

        WS_PATH="$(printf '%s' "$JSON" | jq -r '.path // empty' 2>/dev/null || true)"
        WS_HOST="$(printf '%s' "$JSON" | jq -r '.host // empty' 2>/dev/null || true)"

        TLS_SERVER_NAME="$(printf '%s' "$JSON" | jq -r '.sni // empty' 2>/dev/null || true)"
        TLS_FINGERPRINT="$(printf '%s' "$JSON" | jq -r '.fp // empty' 2>/dev/null || true)"
        TLS_ALPN="$(printf '%s' "$JSON" | jq -r '.alpn // empty' 2>/dev/null || true)"
        TLS_ECH_CONFIG="$(printf '%s' "$JSON" | jq -r '.ech // .echConfigList // empty' 2>/dev/null || true)"
        TLS_PINNED_CERT="$(printf '%s' "$JSON" | jq -r '.pcs // .pinnedPeerCert // .pinnedPeerCertSha256 // empty' 2>/dev/null || true)"

        REALITY_SERVER_NAME="$TLS_SERVER_NAME"
        REALITY_FINGERPRINT="$TLS_FINGERPRINT"
        REALITY_PASSWORD="$(printf '%s' "$JSON" | jq -r '.pbk // empty' 2>/dev/null || true)"
        REALITY_SHORT_ID="$(printf '%s' "$JSON" | jq -r '.sid // empty' 2>/dev/null || true)"
        REALITY_SPIDER_X="$(printf '%s' "$JSON" | jq -r '.spx // empty' 2>/dev/null || true)"
        REALITY_MLDSA65_VERIFY="$(printf '%s' "$JSON" | jq -r '.pqv // .mldsa65Verify // empty' 2>/dev/null || true)"

        VMESS_MODE="$(printf '%s' "$JSON" | jq -r '.mode // empty' 2>/dev/null || true)"
        VMESS_EXTRA="$(printf '%s' "$JSON" | jq -c '.extra // empty' 2>/dev/null || true)"
        VMESS_FM="$(printf '%s' "$JSON" | jq -r '.fm // empty' 2>/dev/null || true)"
        [ -n "$VMESS_FM" ] && FINALMASK_JSON="$(json_object_or_empty_string "$VMESS_FM")" && [ -n "$FINALMASK_JSON" ] && FINALMASK_USED=true

        [ -n "$WS_PATH" ] && WS_USED=true
        [ -n "$WS_HOST" ] && WS_USED=true
        [ -n "$TLS_SERVER_NAME$TLS_FINGERPRINT$TLS_ALPN$TLS_ECH_CONFIG$TLS_PINNED_CERT" ] && TLS_USED=true
        [ -n "$REALITY_SERVER_NAME$REALITY_FINGERPRINT$REALITY_PASSWORD$REALITY_SHORT_ID$REALITY_SPIDER_X$REALITY_MLDSA65_VERIFY" ] && REALITY_USED=true

        if [ "$NETWORK" = "grpc" ]; then
            GRPC_SERVICE_NAME="$WS_PATH"
            GRPC_AUTHORITY="$WS_HOST"
            case "$VMESS_MODE:$VMESS_HEADER_TYPE" in
                multi:*|*:multi) GRPC_MULTI_MODE="true" ;;
                gun:*|*:gun) GRPC_MULTI_MODE="false" ;;
            esac
            GRPC_USED=true
        elif [ "$NETWORK" = "xhttp" ] || [ "$NETWORK" = "splithttp" ]; then
            XHTTP_PATH="$WS_PATH"
            XHTTP_HOST="$WS_HOST"
            XHTTP_MODE="${VMESS_MODE:-$VMESS_HEADER_TYPE}"
            XHTTP_EXTRA="$(json_value_or_empty_object "$VMESS_EXTRA")"
            XHTTP_USED=true
        fi

        QUERY="$(printf '%s' "$LINK" | cut -s -d'?' -f2)"
    fi

    case "$NETWORK" in
        tcp)
            case "$VMESS_HEADER_TYPE" in
                none|http)
                    RAW_HEADERTYPE="$VMESS_HEADER_TYPE"
                    RAW_USED=true
                    ;;
            esac
            ;;
        kcp)
            case "$VMESS_HEADER_TYPE" in
                srtp|utp|wechat-video|dtls|wireguard)
                    KCP_HEADER_TYPE="$VMESS_HEADER_TYPE"
                    KCP_USED=true
                    ;;
            esac
            ;;
    esac

    IFS='&'
    for kv in $QUERY; do
        key="$(printf '%s' "$kv" | cut -d'=' -f1)"
        val="$(printf '%s' "$kv" | cut -d'=' -f2-)"

        case "$key" in
            type)
                NETWORK="$val"
                ;;
            security)
                SECURITY="$val"
                ;;
            encryption)
                VLESS_ENCRYPTION="$val"
                ;;
            flow)
                VLESS_FLOW="$val"
                ;;
            level)
                VLESS_LEVEL="$val"
                SS_LEVEL="$val"
                TROJAN_LEVEL="$val"
                ;;
            publickey|publicKey|public_key|peerPublicKey)
                WG_PUBLIC_KEY="$(urldecode "$val")"
                ;;
            address|ip)
                WG_ADDRESS="$(urldecode "$val")"
                ;;
            allowedips|allowed_ips)
                WG_ALLOWED_IPS="$(urldecode "$val")"
                ;;
            presharedkey|preshared_key|pre-shared-key|psk)
                WG_PRESHARED_KEY="$(urldecode "$val")"
                ;;
            keepalive|persistentkeepalive|persistent_keepalive)
                WG_KEEPALIVE="$val"
                ;;
            workers)
                WG_WORKERS="$val"
                ;;
            reserved)
                WG_RESERVED="$(urldecode "$val")"
                ;;
            email)
                EMAIL="$(urldecode "$val")"
                ;;  
            host)
                DECODED_HOST="$(urldecode "$val")"
                XHTTP_HOST="$DECODED_HOST"
                WS_HOST="$DECODED_HOST"
                HTTPUP_HOST="$DECODED_HOST"
                GRPC_AUTHORITY="$DECODED_HOST"
                XHTTP_USED=true
                WS_USED=true
                HTTPUP_USED=true
                GRPC_USED=true
                ;;
            path)
                DECODED_PATH="$(urldecode "$val")"
                XHTTP_PATH="$DECODED_PATH"
                WS_PATH="$DECODED_PATH"
                HTTPUP_PATH="$DECODED_PATH"
                GRPC_SERVICE_NAME="$DECODED_PATH"
                XHTTP_USED=true
                WS_USED=true
                HTTPUP_USED=true
                GRPC_USED=true
                ;;
            heartbeatPeriod)
                WS_HEARTBEAT="$val"
                WS_USED=true
                ;;
            headers)
                DECODED_HEADERS="$(urldecode "$val")"
                WS_HEADERS="$DECODED_HEADERS"
                HTTPUP_HEADERS="$DECODED_HEADERS"
                WS_USED=true
                HTTPUP_USED=true
                ;;
            mode)
                XHTTP_MODE="$val"
                XHTTP_USED=true
                if [ "$NETWORK" = "grpc" ]; then
                    case "$val" in
                        multi) GRPC_MULTI_MODE="true" ;;
                        gun) GRPC_MULTI_MODE="false" ;;
                    esac
                    GRPC_USED=true
                fi
                ;;
            x_padding_bytes)
                XHTTP_EXTRA="$(jq -cn --arg v "$(urldecode "$val")" '{xPaddingBytes:$v}')"
                XHTTP_USED=true
                ;;
            extra)
                DECODED="$(urldecode "$val")"
                case "$DECODED" in
                    \{*\})
                        if printf '%s' "$DECODED" | grep -q '":'; then
                            XHTTP_EXTRA="$(printf '%s' "$DECODED" | normalize_xray_numbers)"
                        else
                            XHTTP_EXTRA="$(xhttp_dsl_to_json "$DECODED" | normalize_xray_numbers)"
                        fi
                        XHTTP_USED=true
                        ;;
                esac
                ;;
            fm)
                DECODED_FM="$(urldecode "$val")"
                FINALMASK_JSON="$(json_object_or_empty_string "$DECODED_FM")"
                [ -n "$FINALMASK_JSON" ] && FINALMASK_USED=true
                ;;
            serviceName)
                GRPC_SERVICE_NAME="$(urldecode "$val")"
                GRPC_USED=true
                ;;
            authority)
                GRPC_AUTHORITY="$(urldecode "$val")"
                GRPC_USED=true
                ;;
            user_agent)
                GRPC_USER_AGENT="$(urldecode "$val")"
                GRPC_USED=true
                ;;
            multiMode)
                GRPC_MULTI_MODE="$val"
                GRPC_USED=true
                ;;
            idle_timeout)
                GRPC_IDLE_TIMEOUT="$val"
                GRPC_USED=true
                ;;
            health_check_timeout)
                GRPC_HEALTH_CHECK_TIMEOUT="$val"
                GRPC_USED=true
                ;;
            permit_without_stream)
                GRPC_PERMIT_WITHOUT_STREAM="$val"
                GRPC_USED=true
                ;;
            initial_windows_size)
                GRPC_INITIAL_WINDOWS_SIZE="$val"
                GRPC_USED=true
                ;;
            mtu)
                KCP_MTU="$val"
                WG_MTU="$val"
                KCP_USED=true
                ;;
            tti)
                KCP_TTI="$val"
                KCP_USED=true
                ;;
            uplinkCapacity)
                KCP_UPLINK="$val"
                KCP_USED=true
                ;;
            downlinkCapacity)
                KCP_DOWNLINK="$val"
                KCP_USED=true
                ;;
            congestion)
                case "$val" in
                    1|true) KCP_CONGESTION="true" ;;
                    0|false) KCP_CONGESTION="false" ;;
                    *) KCP_CONGESTION="" ;;
                esac
                [ -n "$KCP_CONGESTION" ] && KCP_USED=true
                ;;
            readBufferSize)
                KCP_READ_BUF="$val"
                KCP_USED=true
                ;;
            writeBufferSize)
                KCP_WRITE_BUF="$val"
                KCP_USED=true
                ;;
            seed)
                KCP_SEED="$(urldecode "$val")"
                KCP_USED=true
                ;;
            headerType)
                case "$val" in
                    ""|"\"\""|"none")
                        RAW_HEADERTYPE="none"
                        ;;
                    *)
                        RAW_HEADERTYPE="$val"
                        ;;
                esac
                RAW_USED=true
                if [ "$NETWORK" = "kcp" ]; then
                    KCP_HEADER_TYPE="$RAW_HEADERTYPE"
                    KCP_USED=true
                fi
                ;;
            headerDomain)
                KCP_HEADER_DOMAIN="$(urldecode "$val")"
                KCP_USED=true
                ;;
            obfs)
                HY2_OBFS="$val"
                ;;
            obfs-password)
                HY2_OBFS_PASSWORD="$(urldecode "$val")"
                ;;
            mport)
                DECODED_MPORT="$(urldecode "$val")"
                if [ -n "$DECODED_MPORT" ]; then
                    FINALMASK_JSON="$(printf '%s' "${FINALMASK_JSON:-{}}" | jq -c --arg ports "$DECODED_MPORT" '
                      if type != "object" then {} else . end
                      | .quicParams.udpHop.ports = $ports
                    ' 2>/dev/null || printf '{}')"
                    FINALMASK_USED=true
                fi
                ;;
            sni)
                DECODED_SNI="$(urldecode "$val")"
                TLS_SERVER_NAME="$DECODED_SNI"
                REALITY_SERVER_NAME="$DECODED_SNI"
                if [ "$HY2_USED" = "true" ]; then
                SECURITY="tls"
                fi         
                TLS_USED=true
                REALITY_USED=true
                ;;
            alpn)
                TLS_ALPN="$(urldecode "$val")"
                TLS_USED=true
                ;;
            fp)
                TLS_FINGERPRINT="$val"
                REALITY_FINGERPRINT="$val"
                TLS_USED=true
                REALITY_USED=true
                ;;
            insecure)
                # Removed from current Xray; ignore old panel links instead of emitting invalid JSON.
                ;;
            verifyPeerCertByName)
                TLS_VERIFY_NAMES="$(urldecode "$val")"
                TLS_USED=true
                ;;
            pinnedPeerCert|pinnedPeerCertSha256|pcs)
                TLS_PINNED_CERT="$(urldecode "$val")"
                TLS_USED=true
                ;;
            pinSHA256)
                HY2_PIN_SHA256="$(urldecode "$val")"
                TLS_PINNED_CERT="$HY2_PIN_SHA256"
                TLS_USED=true
                ;;
            disableSystemRoot)
                TLS_DISABLE_SYSTEM_ROOT="$val"
                TLS_USED=true
                ;;
            enableSessionResumption)
                TLS_SESSION_RESUME="$val"
                TLS_USED=true
                ;;
            minVersion)
                TLS_MIN_VERSION="$val"
                TLS_USED=true
                ;;
            maxVersion)
                TLS_MAX_VERSION="$val"
                TLS_USED=true
                ;;
            cipherSuites)
                TLS_CIPHER_SUITES="$(urldecode "$val")"
                TLS_USED=true
                ;;
            curvePreferences)
                TLS_CURVE_PREFS="$(urldecode "$val")"
                TLS_USED=true
                ;;
            masterKeyLog)
                TLS_MASTER_KEY_LOG="$(urldecode "$val")"
                TLS_USED=true
                ;;
            echConfigList)
                TLS_ECH_CONFIG="$(urldecode "$val")"
                TLS_USED=true
                ;;
            ech)
                TLS_ECH_CONFIG="$(urldecode "$val")"
                TLS_USED=true
                ;;
            sid)
                REALITY_SHORT_ID="$val"
                REALITY_USED=true
                ;;
            pbk)
                REALITY_PASSWORD="$val"
                REALITY_USED=true
                ;;
            spx)
                REALITY_SPIDER_X="$(urldecode "$val")"
                REALITY_USED=true
                ;;
            mldsa65Verify)
                REALITY_MLDSA65_VERIFY="$val"
                REALITY_USED=true
                ;;
            pqv)
                REALITY_MLDSA65_VERIFY="$(urldecode "$val")"
                REALITY_USED=true
                ;;
            fragment)
                DECODED_FRAGMENT="$(urldecode "$val")"
                if [ -n "$DECODED_FRAGMENT" ]; then
                    FINALMASK_JSON="$(printf '%s' "${FINALMASK_JSON:-{}}" | jq -c --arg packets "$DECODED_FRAGMENT" '
                      if type != "object" then {} else . end
                      | .tcp = ((.tcp // []) + [{"type":"fragment","settings":{"packets":$packets,"length":"100-200","delay":"1-1"}}])
                    ' 2>/dev/null || printf '{}')"
                    FINALMASK_USED=true
                fi
                ;;
        esac
    done
    unset IFS

    case "$NETWORK" in
        tcp|"")
            NETWORK="raw"
            ;;
        http|h2)
            NETWORK="xhttp"
            [ -z "$XHTTP_MODE" ] && XHTTP_MODE="stream-one"
            XHTTP_USED=true
            ;;
        websocket)
            NETWORK="ws"
            ;;
        splithttp)
            NETWORK="xhttp"
            XHTTP_USED=true
            ;;
        mkcp)
            NETWORK="kcp"
            ;;
        hy2|hysteria2)
            NETWORK="hysteria"
            ;;
    esac

    case "$(tolower "$KCP_HEADER_TYPE")" in
        none)
            KCP_HEADER_TYPE=""
            ;;
        wechat-video)
            KCP_HEADER_TYPE="wechat"
            ;;
        *)
            KCP_HEADER_TYPE="$(tolower "$KCP_HEADER_TYPE")"
            ;;
    esac

    if [ -z "$FINALMASK_JSON" ] && { [ -n "$KCP_HEADER_TYPE" ] || [ -n "$KCP_SEED" ]; }; then
        KCP_LEGACY_VALUE="$KCP_SEED"
        [ "$KCP_HEADER_TYPE" = "dns" ] && [ -n "$KCP_HEADER_DOMAIN" ] && KCP_LEGACY_VALUE="$KCP_HEADER_DOMAIN"
        FINALMASK_JSON="$(jq -cn \
          --arg header "$KCP_HEADER_TYPE" \
          --arg value "$KCP_LEGACY_VALUE" \
          '{udp:[{type:"mkcp-legacy",settings:({} | if $header != "" then . + {header:$header} else . end | if $value != "" then . + {value:$value} else . end)}]}' \
        )"
        FINALMASK_USED=true
    fi

    if [ "$NETWORK" = "grpc" ]; then
        case "$XHTTP_MODE" in
            multi) GRPC_MULTI_MODE="true" ;;
            gun) GRPC_MULTI_MODE="false" ;;
        esac
    fi

    PORT="$(int_or_default "$PORT" 0)"
    VLESS_LEVEL="$(int_or_default "$VLESS_LEVEL" 0)"
    VMESS_LEVEL="$(int_or_default "$VMESS_LEVEL" 0)"
    TROJAN_LEVEL="$(int_or_default "$TROJAN_LEVEL" 0)"
    SS_LEVEL="$(int_or_default "$SS_LEVEL" 0)"
    MUX_ENABLED="$(bool_or_empty "$MUX")"
    [ -z "$MUX_ENABLED" ] && MUX_ENABLED=false
    MUX_CONCURRENCY="$(int_or_default "$MUX_CONCURRENCY" 8)"
    MUX_XUDPCONCURRENCY="$(int_or_default "$MUX_XUDPCONCURRENCY" "$MUX_CONCURRENCY")"

    WS_HEADERS_JSON="$(json_object_or_empty "$WS_HEADERS")"
    HTTPUP_HEADERS_JSON="$(json_object_or_empty "$HTTPUP_HEADERS")"
    XHTTP_EXTRA_JSON="$(json_value_or_empty_object "$XHTTP_EXTRA")"
    FINALMASK_JSON="$(json_object_or_empty "$FINALMASK_JSON")"
    TLS_DISABLE_SYSTEM_ROOT="$(bool_or_empty "$TLS_DISABLE_SYSTEM_ROOT")"
    TLS_SESSION_RESUME="$(bool_or_empty "$TLS_SESSION_RESUME")"
    GRPC_MULTI_MODE="$(bool_or_empty "$GRPC_MULTI_MODE")"
    GRPC_PERMIT_WITHOUT_STREAM="$(bool_or_empty "$GRPC_PERMIT_WITHOUT_STREAM")"
    GRPC_IDLE_TIMEOUT="$(int_or_default "$GRPC_IDLE_TIMEOUT" 0)"
    GRPC_HEALTH_CHECK_TIMEOUT="$(int_or_default "$GRPC_HEALTH_CHECK_TIMEOUT" 0)"
    GRPC_INITIAL_WINDOWS_SIZE="$(int_or_default "$GRPC_INITIAL_WINDOWS_SIZE" 0)"
    WS_HEARTBEAT="$(int_or_default "$WS_HEARTBEAT" 0)"
    KCP_MTU="$(int_or_default "$KCP_MTU" 0)"
    KCP_TTI="$(int_or_default "$KCP_TTI" 0)"
    KCP_UPLINK="$(int_or_default "$KCP_UPLINK" 0)"
    KCP_DOWNLINK="$(int_or_default "$KCP_DOWNLINK" 0)"
    KCP_READ_BUF="$(int_or_default "$KCP_READ_BUF" 0)"
    KCP_WRITE_BUF="$(int_or_default "$KCP_WRITE_BUF" 0)"
    WG_MTU="$(int_or_default "$WG_MTU" 0)"
    WG_KEEPALIVE="$(int_or_default "$WG_KEEPALIVE" 0)"
    WG_WORKERS="$(int_or_default "$WG_WORKERS" 0)"

    tmp="$(mktemp /dev/shm/xray-25_outbound.XXXXXX)"
    jq -n \
      --arg protocol "$PROTOCOL" \
      --arg xray_protocol "$XRAY_PROTOCOL" \
      --arg address "$ADDRESS" \
      --arg uuid "$UUID" \
      --arg vmess_uuid "$VMESS_UUID" \
      --arg password "$PASSWORD" \
      --arg method "$METHOD" \
      --arg email "$EMAIL" \
      --arg vless_encryption "$VLESS_ENCRYPTION" \
      --arg vless_flow "$VLESS_FLOW" \
      --arg vmess_security "$VMESS_SECURITY" \
      --arg network "$NETWORK" \
      --arg security "$SECURITY" \
      --arg raw_header_type "$RAW_HEADERTYPE" \
      --arg xhttp_host "$XHTTP_HOST" \
      --arg xhttp_path "$XHTTP_PATH" \
      --arg xhttp_mode "$XHTTP_MODE" \
      --arg ws_path "$WS_PATH" \
      --arg ws_host "$WS_HOST" \
      --arg grpc_service_name "$GRPC_SERVICE_NAME" \
      --arg grpc_authority "$GRPC_AUTHORITY" \
      --arg grpc_user_agent "$GRPC_USER_AGENT" \
      --arg httpup_path "$HTTPUP_PATH" \
      --arg httpup_host "$HTTPUP_HOST" \
      --arg hy2_auth "$HY2_AUTH" \
      --arg hy2_obfs "$HY2_OBFS" \
      --arg hy2_obfs_password "$HY2_OBFS_PASSWORD" \
      --arg tls_server_name "$TLS_SERVER_NAME" \
      --arg tls_fingerprint "$TLS_FINGERPRINT" \
      --arg tls_min_version "$TLS_MIN_VERSION" \
      --arg tls_max_version "$TLS_MAX_VERSION" \
      --arg tls_cipher_suites "$TLS_CIPHER_SUITES" \
      --arg tls_master_key_log "$TLS_MASTER_KEY_LOG" \
      --arg tls_ech_config "$TLS_ECH_CONFIG" \
      --arg reality_server_name "$REALITY_SERVER_NAME" \
      --arg reality_fingerprint "$REALITY_FINGERPRINT" \
      --arg reality_short_id "$REALITY_SHORT_ID" \
      --arg reality_password "$REALITY_PASSWORD" \
      --arg reality_spider_x "$REALITY_SPIDER_X" \
      --arg reality_mldsa65_verify "$REALITY_MLDSA65_VERIFY" \
      --arg mux_xudp_proxy_udp443 "$MUX_XUDPPROXYUDP443" \
      --arg tls_alpn "$TLS_ALPN" \
      --arg tls_verify_names "$TLS_VERIFY_NAMES" \
      --arg tls_pinned_cert "$TLS_PINNED_CERT" \
      --arg tls_curve_prefs "$TLS_CURVE_PREFS" \
      --arg tls_disable_system_root "$TLS_DISABLE_SYSTEM_ROOT" \
      --arg tls_session_resume "$TLS_SESSION_RESUME" \
      --arg grpc_multi_mode "$GRPC_MULTI_MODE" \
      --arg grpc_permit_without_stream "$GRPC_PERMIT_WITHOUT_STREAM" \
      --arg kcp_congestion "$KCP_CONGESTION" \
      --arg wg_secret_key "$WG_SECRET_KEY" \
      --arg wg_public_key "$WG_PUBLIC_KEY" \
      --arg wg_address "$WG_ADDRESS" \
      --arg wg_allowed_ips "$WG_ALLOWED_IPS" \
      --arg wg_preshared_key "$WG_PRESHARED_KEY" \
      --arg wg_reserved "$WG_RESERVED" \
      --argjson port "$PORT" \
      --argjson vless_level "$VLESS_LEVEL" \
      --argjson vmess_level "$VMESS_LEVEL" \
      --argjson trojan_level "$TROJAN_LEVEL" \
      --argjson ss_level "$SS_LEVEL" \
      --argjson mux_enabled "$MUX_ENABLED" \
      --argjson mux_concurrency "$MUX_CONCURRENCY" \
      --argjson mux_xudp_concurrency "$MUX_XUDPCONCURRENCY" \
      --argjson ws_headers "$WS_HEADERS_JSON" \
      --argjson httpup_headers "$HTTPUP_HEADERS_JSON" \
      --argjson xhttp_extra "$XHTTP_EXTRA_JSON" \
      --argjson finalmask "$FINALMASK_JSON" \
      --argjson ws_heartbeat "$WS_HEARTBEAT" \
      --argjson grpc_idle_timeout "$GRPC_IDLE_TIMEOUT" \
      --argjson grpc_health_check_timeout "$GRPC_HEALTH_CHECK_TIMEOUT" \
      --argjson grpc_initial_windows_size "$GRPC_INITIAL_WINDOWS_SIZE" \
      --argjson kcp_mtu "$KCP_MTU" \
      --argjson kcp_tti "$KCP_TTI" \
      --argjson kcp_uplink "$KCP_UPLINK" \
      --argjson kcp_downlink "$KCP_DOWNLINK" \
      --argjson kcp_read_buf "$KCP_READ_BUF" \
      --argjson kcp_write_buf "$KCP_WRITE_BUF" \
      --argjson wg_mtu "$WG_MTU" \
      --argjson wg_keepalive "$WG_KEEPALIVE" \
      --argjson wg_workers "$WG_WORKERS" '
      def nonempty($v): ($v != null and $v != "");
      def csv($v): $v | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));
      def putstr($k; $v): if nonempty($v) then . + {($k): $v} else . end;
      def putnum($k; $v): if $v > 0 then . + {($k): $v} else . end;
      def putbool($k; $v): if nonempty($v) then . + {($k): ($v == "true")} else . end;
      def base_settings:
        if $protocol == "vless" then
          {vnext:[{address:$address, port:$port, users:[({id:$uuid, encryption:$vless_encryption, level:$vless_level} | putstr("flow"; $vless_flow))]}]}
        elif $protocol == "vmess" then
          {vnext:[{address:$address, port:$port, users:[{id:$vmess_uuid, security:$vmess_security, level:$vmess_level}]}]}
        elif $protocol == "trojan" then
          ({address:$address, port:$port, password:$password, level:$trojan_level} | putstr("email"; $email) | putstr("flow"; $vless_flow))
        elif $protocol == "ss" then
          ({address:$address, port:$port, method:$method, password:$password, uot:true, UoTVersion:2, level:$ss_level} | putstr("email"; $email))
        elif ($protocol == "hy2" or $protocol == "hysteria2") then
          {version:2, address:$address, port:$port}
        elif ($protocol == "wireguard" or $protocol == "wg") then
          ({secretKey:$wg_secret_key,
            address:(if nonempty($wg_address) then csv($wg_address) else [] end),
            peers:[({publicKey:$wg_public_key, endpoint:($address + ":" + ($port|tostring))}
              | putstr("preSharedKey"; $wg_preshared_key)
              | putnum("keepAlive"; $wg_keepalive)
              | if nonempty($wg_allowed_ips) then . + {allowedIPs:csv($wg_allowed_ips)} else . end)]}
            | putnum("mtu"; $wg_mtu)
            | putnum("workers"; $wg_workers)
            | if nonempty($wg_reserved) then . + {reserved:(try ($wg_reserved | split(",") | map(tonumber)) catch [])} else . end)
        else
          {}
        end;
      def tls_settings:
        ({} | putstr("serverName"; $tls_server_name)
            | (if (csv($tls_alpn)|length) > 0 then . + {alpn: csv($tls_alpn)} else . end)
            | putstr("fingerprint"; $tls_fingerprint)
            | (if (csv($tls_verify_names)|length) > 0 then . + {verifyPeerCertByName: csv($tls_verify_names)} else . end)
            | (if (csv($tls_pinned_cert)|length) > 0 then . + {pinnedPeerCertSha256: csv($tls_pinned_cert)} else . end)
            | putbool("disableSystemRoot"; $tls_disable_system_root)
            | putbool("enableSessionResumption"; $tls_session_resume)
            | putstr("minVersion"; $tls_min_version)
            | putstr("maxVersion"; $tls_max_version)
            | putstr("cipherSuites"; $tls_cipher_suites)
            | (if (csv($tls_curve_prefs)|length) > 0 then . + {curvePreferences: csv($tls_curve_prefs)} else . end)
            | putstr("masterKeyLog"; $tls_master_key_log)
            | putstr("echConfigList"; $tls_ech_config));
      def reality_settings:
        ({} | putstr("serverName"; $reality_server_name)
            | putstr("fingerprint"; $reality_fingerprint)
            | putstr("shortId"; $reality_short_id)
            | putstr("password"; $reality_password)
            | putstr("mldsa65Verify"; $reality_mldsa65_verify)
            | putstr("spiderX"; $reality_spider_x));
      def finalmask_settings:
        (($finalmask // {})
          | if nonempty($hy2_obfs) then
              .udp = ((.udp // []) + [{type:$hy2_obfs, settings:({} | putstr("password"; $hy2_obfs_password))}])
            else . end);
      def stream_settings:
        ({network:$network, security:$security}
          | if $security == "tls" and (tls_settings | length) > 0 then . + {tlsSettings: tls_settings} else . end
          | if $security == "reality" and (reality_settings | length) > 0 then . + {realitySettings: reality_settings} else . end
          | if (finalmask_settings | length) > 0 then . + {finalmask: finalmask_settings} else . end
          | if $network == "xhttp" then . + {xhttpSettings: ({} | putstr("host"; $xhttp_host) | putstr("path"; $xhttp_path) | putstr("mode"; $xhttp_mode) | if ($xhttp_extra|length) > 0 then . + {extra:$xhttp_extra} else . end)} else . end
          | if $network == "raw" and nonempty($raw_header_type) then . + {rawSettings:{header:{type:$raw_header_type}}} else . end
          | if $network == "ws" then . + {wsSettings: ({} | putstr("path"; $ws_path) | putstr("host"; $ws_host) | if ($ws_headers|length) > 0 then . + {headers:$ws_headers} else . end | putnum("heartbeatPeriod"; $ws_heartbeat))} else . end
          | if $network == "grpc" then . + {grpcSettings: ({} | putstr("serviceName"; $grpc_service_name) | putstr("authority"; $grpc_authority) | putstr("user_agent"; $grpc_user_agent) | putbool("multiMode"; $grpc_multi_mode) | putnum("idle_timeout"; $grpc_idle_timeout) | putnum("health_check_timeout"; $grpc_health_check_timeout) | putbool("permit_without_stream"; $grpc_permit_without_stream) | putnum("initial_windows_size"; $grpc_initial_windows_size))} else . end
          | if $network == "kcp" then . + {kcpSettings: ({} | putnum("mtu"; $kcp_mtu) | putnum("tti"; $kcp_tti) | putnum("uplinkCapacity"; $kcp_uplink) | putnum("downlinkCapacity"; $kcp_downlink) | putbool("congestion"; $kcp_congestion) | putnum("readBufferSize"; $kcp_read_buf) | putnum("writeBufferSize"; $kcp_write_buf))} else . end
          | if $network == "httpupgrade" then . + {httpupgradeSettings: ({} | putstr("path"; $httpup_path) | putstr("host"; $httpup_host) | if ($httpup_headers|length) > 0 then . + {headers:$httpup_headers} else . end)} else . end
          | if ($protocol == "hy2" or $protocol == "hysteria2") then . + {hysteriaSettings:{version:2, auth:$hy2_auth}} else . end
          | . + {sockopt:{domainStrategy:"ForceIPv4"}});
      {outbounds:[{tag:"XrayProxyRoS", protocol:$xray_protocol, settings:base_settings, streamSettings:stream_settings, mux:{enabled:$mux_enabled, concurrency:$mux_concurrency, xudpConcurrency:$mux_xudp_concurrency, xudpProxyUDP443:$mux_xudp_proxy_udp443}}]}
      ' > "$tmp"
    install_config_if_changed "$tmp" /etc/xray/25_outbound.json
}

LINK="$(printf '%s' "$LINK" | sed 's/&amp;/\&/g')"
SCHEME="$(tolower "$(printf '%s' "$LINK" | cut -d':' -f1)")"

case "$SCHEME" in
    vless|vmess|trojan|ss|hy2|hysteria2|wireguard|wg)
        parse "$LINK"
        ;;
    "")
        remove_config_if_exists /etc/xray/25_outbound.json
        ;;
    *)
        remove_config_if_exists /etc/xray/25_outbound.json
        echo "Invalid or unsupported link: $SCHEME" >&2
        ;;
esac

config_file_xray() {
  LOG_DNS_JSON="$(bool_or_empty "$LOG_DNS")"
  [ -z "$LOG_DNS_JSON" ] && LOG_DNS_JSON=false
  FAKE_IP_ENABLED=false
  [ "$DNS_MODE" = "fake-ip" ] && FAKE_IP_ENABLED=true
  QUIC_DROP_JSON="$(bool_or_empty "$QUIC_DROP")"
  [ -z "$QUIC_DROP_JSON" ] && QUIC_DROP_JSON=false
  UDP_TPROXY_ENABLED=false
  [ "$USE_NFT" = "true" ] && [ "${TPROXY}" = "true" ] && UDP_TPROXY_ENABLED=true

  tmp="$(mktemp /dev/shm/xray-20_log.XXXXXX)"
  jq -n \
    --arg access "$LOG_ACCESS" \
    --arg error "$LOG_ERROR" \
    --arg level "$LOG_LEVEL" \
    --arg mask "$LOG_MASK" \
    --argjson dns_log "$LOG_DNS_JSON" \
    '{log:{access:$access,error:$error,loglevel:$level,dnsLog:$dns_log,maskAddress:$mask}}' \
    > "$tmp"
  install_config_if_changed "$tmp" /etc/xray/20_log.json

  tmp="$(mktemp /dev/shm/xray-21_dns.XXXXXX)"
  jq -n \
    --arg fake_ip_range "$FAKE_IP_RANGE" \
    --argjson fake_pool_size "$FAKE_POOL_SIZE" \
    --argjson fake_ip_enabled "$FAKE_IP_ENABLED" '
    {
      dns:{
        tag:"dns-inbound",
        hosts:{
          "dns.google":["8.8.8.8","8.8.4.4"],
          "dns.quad9.net":["9.9.9.9","149.112.112.112"],
          "cloudflare-dns.com":["104.16.248.249","104.16.249.249"]
        },
        servers:(
          (if $fake_ip_enabled then [{tag:"fakeip",address:"fakedns"}] else [] end)
          + [
              {tag:"ParallelQuery",address:"https://dns.google/dns-query"},
              {tag:"ParallelQuery",address:"https://cloudflare-dns.com/dns-query"},
              {tag:"ParallelQuery",address:"https://dns.quad9.net/dns-query"}
            ]
        ),
        queryStrategy:"UseIPv4",
        enableParallelQuery:true
      },
      fakedns:{ipPool:$fake_ip_range,poolSize:$fake_pool_size}
    }' \
    > "$tmp"
  install_config_if_changed "$tmp" /etc/xray/21_dns.json

  tmp="$(mktemp /dev/shm/xray-22_routing.XXXXXX)"
  jq -n \
    --arg fake_ip_range "$FAKE_IP_RANGE" \
    --argjson fake_ip_enabled "$FAKE_IP_ENABLED" \
    --argjson udp_tproxy_enabled "$UDP_TPROXY_ENABLED" \
    --argjson quic_drop "$QUIC_DROP_JSON" '
    {
      routing:{
        domainStrategy:"IPIfNonMatch",
        rules:(
          [
            {inboundTag:["ParallelQuery"],outboundTag:"direct"},
            {inboundTag:["dns-in"],outboundTag:"dns"}
          ]
          + (if $quic_drop then [{network:"udp",port:"443",outboundTag:"block"}] else [] end)
          + (if $fake_ip_enabled then [
              {inboundTag:["all-in-tcp"],ip:[$fake_ip_range],network:"tcp",outboundTag:"block-http"},
              (if $udp_tproxy_enabled then
                {inboundTag:["all-in-udp"],ip:[$fake_ip_range],network:"udp",outboundTag:"block"}
              else
                {inboundTag:["XrayTUN"],ip:[$fake_ip_range],network:"udp",outboundTag:"block"}
              end),
              {inboundTag:["mixed-in"],ip:[$fake_ip_range],network:"tcp",outboundTag:"block-http"},
              {inboundTag:["mixed-in"],ip:[$fake_ip_range],network:"udp",outboundTag:"block"}
            ] else [] end)
        )
      }
    }' \
    > "$tmp"
  install_config_if_changed "$tmp" /etc/xray/22_routing.json

  tmp="$(mktemp /dev/shm/xray-23_inbounds.XXXXXX)"
  jq -n \
    --argjson udp_tproxy_enabled "$UDP_TPROXY_ENABLED" '
    def sniffing: {
      enabled:true,
      destOverride:["http","tls","quic","fakedns"],
      metadataOnly:false,
      routeOnly:true
    };
    {
      inbounds:[
        {
          tag:"dns-in",
          port:53,
          protocol:"dokodemo-door",
          settings:{network:"tcp,udp"}
        },
        {
          tag:"mixed-in",
          port:1080,
          protocol:"mixed",
          settings:{udp:true},
          sniffing:sniffing
        },
        (if $udp_tproxy_enabled then
          {
            tag:"all-in-udp",
            port:12346,
            protocol:"dokodemo-door",
            settings:{network:"udp",followRedirect:true},
            streamSettings:{sockopt:{tproxy:"tproxy"}},
            sniffing:sniffing
          }
        else
          {
            tag:"XrayTUN",
            port:0,
            protocol:"tun",
            settings:{name:"Xray",MTU:1500},
            sniffing:sniffing
          }
        end),
        {
          tag:"all-in-tcp",
          port:12345,
          protocol:"dokodemo-door",
          settings:{network:"tcp",followRedirect:true},
          streamSettings:{sockopt:{tproxy:"redirect"}},
          sniffing:sniffing
        }
      ]
    }' \
    > "$tmp"
  install_config_if_changed "$tmp" /etc/xray/23_inbounds.json

  tmp="$(mktemp /dev/shm/xray-24_outbounds.XXXXXX)"
  jq -n '
    {
      outbounds:[
        {tag:"direct",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},
        {tag:"block-http",protocol:"blackhole",settings:{response:{type:"http"}}},
        {tag:"block",protocol:"blackhole"},
        {tag:"dns",protocol:"dns",settings:{rules:[{qType:[65,28],rCode:5,action:"return"}]}}
      ]
    }' \
    > "$tmp"
  install_config_if_changed "$tmp" /etc/xray/24_outbounds.json
}

# ------------------- NFT -------------------
nft_rules() {
  echo "Applying nftables..."
  nft flush ruleset || true

  nft create table inet rawdrop
  nft add chain inet rawdrop prerouting "{ type filter hook prerouting priority raw; policy accept; }"
  nft add rule inet rawdrop prerouting ip daddr { $FAKE_IP_RANGE } meta l4proto != { tcp, udp } drop

  nft create table inet filter
  nft add chain inet filter input "{ type filter hook input priority filter; policy accept; }"
  nft add rule inet filter input ct state { established, related, untracked } accept
  nft add rule inet filter input ct state invalid drop
  nft add chain inet filter forward "{ type filter hook forward priority filter; policy accept; }"
  nft add rule inet filter forward ct state { established, related, untracked } accept
  nft add rule inet filter forward ct state invalid drop

  nft create table ip nat
  nft add chain ip nat postrouting "{ type nat hook postrouting priority srcnat; policy accept; }"
  nft add rule ip nat postrouting oifname "$iface" masquerade

if [ "${TPROXY}" = "true" ]; then
  nft create table inet xray
  nft add chain inet xray pre_nat "{type nat hook prerouting priority dstnat + 1; policy accept;}"
  nft add rule inet xray pre_nat meta iifname != "$iface" return
  nft add rule inet xray pre_nat tcp option mptcp exists drop
  nft add rule inet xray pre_nat ip daddr ${FAKE_IP_RANGE} meta l4proto tcp redirect to 12345
  nft add rule inet xray pre_nat ip daddr { $iface_cidr, 127.0.0.0/8, 100.64.0.1/32, 224.0.0.0/4, 255.255.255.255 } return
  nft add rule inet xray pre_nat meta l4proto tcp redirect to 12345
  nft add chain inet xray pre_filter "{type filter hook prerouting priority filter + 1; policy accept;}"
  nft add rule inet xray pre_filter meta iifname != "$iface" return 
  nft add rule inet xray pre_filter tcp option mptcp exists drop
  nft add rule inet xray pre_filter ip daddr ${FAKE_IP_RANGE} meta l4proto udp meta mark set 0x00000001 tproxy ip to 127.0.0.1:12346 accept
  nft add rule inet xray pre_filter ip daddr { $iface_cidr, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
  nft add rule inet xray pre_filter meta l4proto udp meta mark set 0x00000001 tproxy ip to 127.0.0.1:12346 accept
  ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100
  ip route replace local 0.0.0.0/0 dev lo table 100
  echo "Mode inbound Redirect(tcp)+TProxy(udp) interface $iface"
else
  nft create table inet xray
  nft add chain inet xray pre "{type nat hook prerouting priority dstnat + 1; policy accept;}"
  nft add rule inet xray pre meta iifname != "$iface" return
  nft add rule inet xray pre tcp option mptcp exists drop
  nft add rule inet xray pre ip daddr ${FAKE_IP_RANGE} meta l4proto tcp redirect to 12345
  nft add rule inet xray pre ip daddr { $iface_cidr, 127.0.0.0/8, 100.64.0.1/32, 224.0.0.0/4, 255.255.255.255 } return
  nft add rule inet xray pre meta l4proto tcp redirect to 12345
  nft add chain ip nat output "{ type nat hook output priority dstnat + 1; policy accept; }"
  nft add rule ip nat output meta l4proto tcp oifname "Xray" redirect to 12345
  ip rule show | grep -q 'iif $iface ipproto tcp lookup main' || ip rule add iif $iface ipproto tcp lookup main priority 10000
  ip rule show | grep -q 'to $iface_cidr lookup main' || ip rule add to $iface_cidr lookup main priority 10001
  ip rule show | grep -q 'to 127.0.0.0/8 lookup main' || ip rule add to 127.0.0.0/8 lookup main priority 10002
  ip rule show | grep -q 'to 224.0.0.0/4 lookup main' || ip rule add to 224.0.0.0/4 lookup main priority 10003
  ip rule show | grep -q 'to 255.255.255.255 lookup main' || ip rule add to 255.255.255.255 lookup main priority 10004
  ip rule show | grep -q 'iif $iface ipproto udp lookup 110' || ip rule add iif $iface ipproto udp lookup 110 priority 10005
  ip route replace default via 100.64.0.1 dev Xray table 110
  echo "Mode inbound Redirect(tcp)+TUN(udp) interface $iface"
fi
}

iptables_rules() {
  echo "Applying iptables..."
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  iptables -t raw -F
  iptables -t raw -X
  iptables -t filter -F
  iptables -t filter -X
  iptables -t raw -A PREROUTING -d $FAKE_IP_RANGE -p tcp -j RETURN
  iptables -t raw -A PREROUTING -d $FAKE_IP_RANGE -p udp -j RETURN
  iptables -t raw -A PREROUTING -d $FAKE_IP_RANGE -j DROP
  iptables -t filter -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED,UNTRACKED -j ACCEPT
  iptables -t filter -A INPUT -m conntrack --ctstate INVALID -j DROP
  iptables -t filter -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED,UNTRACKED -j ACCEPT
  iptables -t filter -A FORWARD -m conntrack --ctstate INVALID -j DROP
  iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
  iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j RETURN
  iptables -t nat -A PREROUTING -m addrtype ! --dst-type UNICAST -j RETURN
  iptables -t nat -A PREROUTING -i $iface -p tcp -j REDIRECT --to-ports 12345
  ip rule show | grep -q 'iif $iface ipproto tcp lookup main' || ip rule add iif $iface ipproto tcp lookup main priority 10000
  ip rule show | grep -q 'to $iface_cidr lookup main' || ip rule add to $iface_cidr lookup main priority 10001
  ip rule show | grep -q 'to 127.0.0.0/8 lookup main' || ip rule add to 127.0.0.0/8 lookup main priority 10002
  ip rule show | grep -q 'to 224.0.0.0/4 lookup main' || ip rule add to 224.0.0.0/4 lookup main priority 10003
  ip rule show | grep -q 'to 255.255.255.255 lookup main' || ip rule add to 255.255.255.255 lookup main priority 10004
  ip rule show | grep -q 'iif $iface ipproto udp lookup 110' || ip rule add iif $iface ipproto udp lookup 110 priority 10005
  ip route replace default via 100.64.0.1 dev Xray table 110
  echo "Mode inbound Redirect(tcp)+TUN(udp) interface $iface"  
}

# ------------------- RUN -------------------
wait_for_tun() {
  for i in $(seq 1 50); do
    if ip link show Xray >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "tun interface not created"
  return 1
}

run() {

  UNSPEC_PREF=$(ip rule show | awk '/lookup unspec/ {print $1}' | tr -d :)
  MASQUERADE_PREF=$(ip rule show | awk '/lookup masquerade/ {print $1}' | tr -d :)
  LOCAL_PREF=$(ip rule show | awk '/lookup local/ {print $1}' | tr -d :)
  MAIN_PREF=$(ip rule show | awk '/lookup main/ {print $1}' | tr -d :)
  DEFAULT_PREF=$(ip rule show | awk '/lookup default/ {print $1}' | tr -d :)

  [ -n "$UNSPEC_PREF" ] && ip rule del pref $UNSPEC_PREF
  [ -n "$MASQUERADE_PREF" ] && ip rule del pref $MASQUERADE_PREF
  ip rule del pref $LOCAL_PREF 2>/dev/null || true
  ip rule del pref $MAIN_PREF 2>/dev/null || true
  ip rule del pref $DEFAULT_PREF 2>/dev/null || true

  ip rule add pref 0 lookup local
  ip rule add pref 32766 lookup main
  ip rule add pref 32767 lookup default

  config_file_xray

  echo "Starting xray $(xray --version)"

  xray run -confdir /etc/xray &
  XRAY_PID=$!

  if [ "$USE_NFT" = "false" ] || [ "${TPROXY}" = "false" ]; then
  wait_for_tun
  ip addr add 100.64.0.1/32 dev Xray
  ip link set Xray up
  fi

  if [ "$USE_NFT" = "true" ]; then
      nft_rules
  else
      iptables_rules
  fi

  wait $XRAY_PID
}

run || exit 1
