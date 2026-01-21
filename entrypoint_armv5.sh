#!/usr/bin/sh

echo 180  > /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream

set -eu
TPROXY="${TPROXY:-true}"
DNS_MODE="${DNS_MODE:-fake-ip}"
FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
LOG_LEVEL="${LOG_LEVEL:-error}"
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

log() { echo "[$(date +'%H:%M:%S')] $*"; }

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
    s="$(printf '%s' "$1" | tr -d '\r\n ')"

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
    PROTOCOL="$(printf '%s' "$LINK_NOPATH" | cut -d':' -f1)"
    LINK_NOPATH="${LINK_NOPATH#${PROTOCOL}://}"
    XRAY_PROTOCOL="$PROTOCOL"
    [ "$PROTOCOL" = "ss" ] && XRAY_PROTOCOL="shadowsocks"

    if [ "$PROTOCOL" != "vmess" ]; then
        CREDS="$(printf '%s' "$LINK_NOPATH" | cut -d'@' -f1)"
        REST="$(printf '%s' "$LINK_NOPATH" | cut -d'@' -f2)"

        HOSTPORT="$(printf '%s' "$REST" | cut -d'?' -f1)"
        QUERY="$(printf '%s' "$REST" | cut -s -d'?' -f2)"

        ADDRESS="$(printf '%s' "$HOSTPORT" | cut -d':' -f1)"
        PORT="$(printf '%s' "$HOSTPORT" | cut -d':' -f2 | tr -cd '0-9')"
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

    HTTPUP_PATH=""
    HTTPUP_HOST=""
    HTTPUP_HEADERS=""
    HTTPUP_USED=false

    TLS_SERVER_NAME=""
    TLS_ALPN=""
    TLS_FINGERPRINT=""
    TLS_ALLOW_INSECURE=""
    TLS_VERIFY_NAMES=""
    TLS_PINNED_CERT=""
    TLS_DISABLE_SYSTEM_ROOT=""
    TLS_SESSION_RESUME=""
    TLS_MIN_VERSION=""
    TLS_MAX_VERSION=""
    TLS_CIPHER_SUITES=""
    TLS_CURVE_PREFS=""
    TLS_MASTER_KEY_LOG=""
    TLS_ECH_CONFIG=""
    TLS_ECH_FORCE_QUERY=""
    TLS_USED=false

    REALITY_SERVER_NAME=""
    REALITY_FINGERPRINT=""
    REALITY_SHORT_ID=""
    REALITY_PASSWORD=""
    REALITY_SPIDER_X=""
    REALITY_MLDSA65_VERIFY=""
    REALITY_USED=false


    VMESS_SECURITY="auto"
    VMESS_LEVEL="0"

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
    esac

    if [ "$PROTOCOL" = "vmess" ]; then
        PAYLOAD="$(printf '%s' "$LINK_NOPATH" | cut -d'?' -f1)"
        JSON="$(printf '%s' "$PAYLOAD" | base64 -d 2>/dev/null)"

        ADDRESS="$(printf '%s' "$JSON" | sed -n 's/.*"add":"\([^"]*\)".*/\1/p')"
        PORT="$(printf '%s' "$JSON" \
          | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\?\([0-9]\+\)"\?.*/\1/p')"
        VMESS_UUID="$(printf '%s' "$JSON" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"

        NETWORK="$(printf '%s' "$JSON" | sed -n 's/.*"net":"\([^"]*\)".*/\1/p')"
        SECURITY="$(printf '%s' "$JSON" | sed -n 's/.*"tls":"\([^"]*\)".*/\1/p')"
        [ -z "$SECURITY" ] && SECURITY="none"

        VMESS_SECURITY="$(printf '%s' "$JSON" \
          | sed -n 's/.*"scy":"\([^"]*\)".*/\1/p')"
        [ -z "$VMESS_SECURITY" ] && VMESS_SECURITY="auto"

        VMESS_HEADER_TYPE="$(printf '%s' "$JSON" \
          | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')"

        VMESS_LEVEL="$(printf '%s' "$JSON" | sed -n 's/.*"level":\([0-9]\+\).*/\1/p')"
        [ -z "$VMESS_LEVEL" ] && VMESS_LEVEL="0"

        WS_PATH="$(printf '%s' "$JSON" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')"
        WS_HOST="$(printf '%s' "$JSON" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')"

        TLS_SERVER_NAME="$(printf '%s' "$JSON" | sed -n 's/.*"sni":"\([^"]*\)".*/\1/p')"

        [ -n "$WS_PATH" ] && WS_USED=true
        [ -n "$WS_HOST" ] && WS_USED=true
        [ -n "$TLS_SERVER_NAME" ] && TLS_USED=true

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
            email)
                EMAIL="$(urldecode "$val")"
                ;;  
            host)
                DECODED_HOST="$(urldecode "$val")"
                XHTTP_HOST="$DECODED_HOST"
                WS_HOST="$DECODED_HOST"
                HTTPUP_HOST="$DECODED_HOST"
                XHTTP_USED=true
                WS_USED=true
                HTTPUP_USED=true
                ;;
            path)
                DECODED_PATH="$(urldecode "$val")"
                XHTTP_PATH="$DECODED_PATH"
                WS_PATH="$DECODED_PATH"
                HTTPUP_PATH="$DECODED_PATH"
                XHTTP_USED=true
                WS_USED=true
                HTTPUP_USED=true
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
            sni)
                DECODED_SNI="$(urldecode "$val")"
                TLS_SERVER_NAME="$DECODED_SNI"
                REALITY_SERVER_NAME="$DECODED_SNI"                
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
                case "$val" in
                    1|true)
                        TLS_ALLOW_INSECURE="true"
                        ;;
                    0|false)
                        TLS_ALLOW_INSECURE="false"
                        ;;
                    *)
                        TLS_ALLOW_INSECURE=""
                        ;;
                esac
                [ -n "$TLS_ALLOW_INSECURE" ] && TLS_USED=true
                ;;
            allowInsecure)
                case "$val" in
                    1|true)
                        TLS_ALLOW_INSECURE="true"
                        ;;
                    0|false)
                        TLS_ALLOW_INSECURE="false"
                        ;;
                    *)
                        TLS_ALLOW_INSECURE=""
                        ;;
                esac
                [ -n "$TLS_ALLOW_INSECURE" ] && TLS_USED=true
                ;;
            verifyPeerCertInNames)
                TLS_VERIFY_NAMES="$(urldecode "$val")"
                TLS_USED=true
                ;;
            pinnedPeerCert)
                TLS_PINNED_CERT="$(urldecode "$val")"
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
            echForceQuery)
                TLS_ECH_FORCE_QUERY="$val"
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
        esac
    done
    unset IFS

    case "$NETWORK" in
        tcp|"")
            NETWORK="raw"
            ;;
    esac

    cat > /etc/xray/25_outbound.json <<EOF
{
  "outbounds": [
{
  "tag": "XrayProxyRoS",
  "protocol": "$XRAY_PROTOCOL",
  "settings": {
EOF

case "$PROTOCOL" in
    vless)
cat >> /etc/xray/25_outbound.json <<EOF
    "vnext": [
      {
        "address": "$ADDRESS",
        "port": $PORT,
        "users": [
          {
            "id": "$UUID",
            "encryption": "$VLESS_ENCRYPTION",
            "flow": "$VLESS_FLOW",
            "level": $VLESS_LEVEL
          }
        ]
      }
    ]
EOF
        ;;
    vmess)
cat >> /etc/xray/25_outbound.json <<EOF
    "vnext": [
      {
        "address": "$ADDRESS",
        "port": $PORT,
        "users": [
          {
            "id": "$VMESS_UUID",
            "security": "$VMESS_SECURITY",
            "level": $VMESS_LEVEL
          }
        ]
      }
    ]
EOF
    ;;
    trojan)
cat >> /etc/xray/25_outbound.json <<EOF
    "address": "$ADDRESS",
    "port": $PORT,
    "password": "$PASSWORD",
    "level": $TROJAN_LEVEL
EOF

    if [ -n "$EMAIL" ]; then
        printf ',\n      "email": "%s"' "$EMAIL" >> /etc/xray/25_outbound.json
    fi
    ;;
    ss)
cat >> /etc/xray/25_outbound.json <<EOF
    "address": "$ADDRESS",
    "port": $PORT,
    "method": "$METHOD",
    "password": "$PASSWORD",
    "uot": true,
    "UoTVersion": 2,
    "level": $SS_LEVEL
EOF

    if [ -n "$EMAIL" ]; then
        printf ',\n      "email": "%s"' "$EMAIL" >> /etc/xray/25_outbound.json
    fi
    ;;
esac
cat >> /etc/xray/25_outbound.json <<EOF
  },
EOF

cat >> /etc/xray/25_outbound.json <<EOF
  "streamSettings": {
    "network": "$NETWORK",
    "security": "$SECURITY",
EOF
if [ "$SECURITY" = "tls" ] && [ "$TLS_USED" = "true" ]; then
    printf '\n    "tlsSettings": {\n' >> /etc/xray/25_outbound.json
    FIRST=true

    add_tls() {
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        FIRST=false
    }

    [ -n "$TLS_SERVER_NAME" ] && add_tls && printf '      "serverName": "%s"' "$TLS_SERVER_NAME" >> /etc/xray/25_outbound.json

    if [ -n "$TLS_ALPN" ]; then
        add_tls
        printf '      "alpn": [' >> /etc/xray/25_outbound.json
        IFS=','; set -- $TLS_ALPN; unset IFS
        ALPN_FIRST=true
        for a in "$@"; do
            [ "$ALPN_FIRST" = false ] && printf ', ' >> /etc/xray/25_outbound.json
            printf '"%s"' "$a" >> /etc/xray/25_outbound.json
            ALPN_FIRST=false
        done
        printf ']' >> /etc/xray/25_outbound.json
    fi

    [ -n "$TLS_FINGERPRINT" ] && add_tls && printf '      "fingerprint": "%s"' "$TLS_FINGERPRINT" >> /etc/xray/25_outbound.json
    [ -n "$TLS_ALLOW_INSECURE" ] && add_tls && printf '      "allowInsecure": %s' "$TLS_ALLOW_INSECURE" >> /etc/xray/25_outbound.json
    [ -n "$TLS_VERIFY_NAMES" ] && add_tls && printf '      "verifyPeerCertInNames": ["%s"]' "$TLS_VERIFY_NAMES" >> /etc/xray/25_outbound.json
    [ -n "$TLS_PINNED_CERT" ] && add_tls && printf '      "pinnedPeerCertificateChainSha256": ["%s"]' "$TLS_PINNED_CERT" >> /etc/xray/25_outbound.json
    [ -n "$TLS_DISABLE_SYSTEM_ROOT" ] && add_tls && printf '      "disableSystemRoot": %s' "$TLS_DISABLE_SYSTEM_ROOT" >> /etc/xray/25_outbound.json
    [ -n "$TLS_SESSION_RESUME" ] && add_tls && printf '      "enableSessionResumption": %s' "$TLS_SESSION_RESUME" >> /etc/xray/25_outbound.json
    [ -n "$TLS_MIN_VERSION" ] && add_tls && printf '      "minVersion": "%s"' "$TLS_MIN_VERSION" >> /etc/xray/25_outbound.json
    [ -n "$TLS_MAX_VERSION" ] && add_tls && printf '      "maxVersion": "%s"' "$TLS_MAX_VERSION" >> /etc/xray/25_outbound.json
    [ -n "$TLS_CIPHER_SUITES" ] && add_tls && printf '      "cipherSuites": "%s"' "$TLS_CIPHER_SUITES" >> /etc/xray/25_outbound.json
    [ -n "$TLS_CURVE_PREFS" ] && add_tls && printf '      "curvePreferences": ["%s"]' "$TLS_CURVE_PREFS" >> /etc/xray/25_outbound.json
    [ -n "$TLS_MASTER_KEY_LOG" ] && add_tls && printf '      "masterKeyLog": "%s"' "$TLS_MASTER_KEY_LOG" >> /etc/xray/25_outbound.json
    [ -n "$TLS_ECH_CONFIG" ] && add_tls && printf '      "echConfigList": "%s"' "$TLS_ECH_CONFIG" >> /etc/xray/25_outbound.json
    [ -n "$TLS_ECH_FORCE_QUERY" ] && add_tls && printf '      "echForceQuery": "%s"' "$TLS_ECH_FORCE_QUERY" >> /etc/xray/25_outbound.json

    printf '\n    },' >> /etc/xray/25_outbound.json
fi

if [ "$SECURITY" = "reality" ] && [ "$REALITY_USED" = "true" ]; then
    printf '\n    "realitySettings": {\n' >> /etc/xray/25_outbound.json

    FIRST=true

    if [ -n "$REALITY_SERVER_NAME" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "serverName": "%s"' "$REALITY_SERVER_NAME" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$REALITY_FINGERPRINT" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "fingerprint": "%s"' "$REALITY_FINGERPRINT" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$REALITY_SHORT_ID" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "shortId": "%s"' "$REALITY_SHORT_ID" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$REALITY_PASSWORD" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "password": "%s"' "$REALITY_PASSWORD" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$REALITY_MLDSA65_VERIFY" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "mldsa65Verify": "%s"' "$REALITY_MLDSA65_VERIFY" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$REALITY_SPIDER_X" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "spiderX": "%s"' "$REALITY_SPIDER_X" >> /etc/xray/25_outbound.json
    fi

    printf '\n    },' >> /etc/xray/25_outbound.json
fi

if [ "$NETWORK" = "xhttp" ] && [ "$XHTTP_USED" = "true" ]; then
    printf '\n    "xhttpSettings": {\n' >> /etc/xray/25_outbound.json

    FIRST=true

    if [ -n "$XHTTP_HOST" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "host": "%s"' "$XHTTP_HOST" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$XHTTP_PATH" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "path": "%s"' "$XHTTP_PATH" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$XHTTP_MODE" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "mode": "%s"' "$XHTTP_MODE" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$XHTTP_EXTRA" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "extra": %s' "$XHTTP_EXTRA" >> /etc/xray/25_outbound.json
    fi

    printf '\n    },' >> /etc/xray/25_outbound.json
fi

if [ "$NETWORK" = "raw" ] && [ "$RAW_USED" = "true" ]; then
    printf '\n    "rawSettings": {\n' >> /etc/xray/25_outbound.json
    printf '      "header": {\n' >> /etc/xray/25_outbound.json
    printf '        "type": "%s"\n' "$RAW_HEADERTYPE" >> /etc/xray/25_outbound.json
    printf '      }\n' >> /etc/xray/25_outbound.json
    printf '    },' >> /etc/xray/25_outbound.json
fi

if [ "$NETWORK" = "ws" ] && [ "$WS_USED" = "true" ]; then
    printf '\n    "wsSettings": {\n' >> /etc/xray/25_outbound.json

    FIRST=true

    if [ -n "$WS_PATH" ]; then
        printf '      "path": "%s"' "$WS_PATH" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$WS_HOST" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "host": "%s"' "$WS_HOST" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$WS_HEADERS" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "headers": %s' "$WS_HEADERS" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$WS_HEARTBEAT" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "heartbeatPeriod": %s' "$WS_HEARTBEAT" >> /etc/xray/25_outbound.json
    fi

    printf '\n    },' >> /etc/xray/25_outbound.json
fi

if [ "$NETWORK" = "grpc" ] && [ "$GRPC_USED" = "true" ]; then
    printf '\n    "grpcSettings": {\n' >> /etc/xray/25_outbound.json

    FIRST=true

    add_grpc() {
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        FIRST=false
    }

    [ -n "$GRPC_SERVICE_NAME" ] && add_grpc && printf '      "serviceName": "%s"' "$GRPC_SERVICE_NAME" >> /etc/xray/25_outbound.json
    [ -n "$GRPC_AUTHORITY" ] && add_grpc && printf '      "authority": "%s"' "$GRPC_AUTHORITY" >> /etc/xray/25_outbound.json
    [ -n "$GRPC_USER_AGENT" ] && add_grpc && printf '      "user_agent": "%s"' "$GRPC_USER_AGENT" >> /etc/xray/25_outbound.json
    [ -n "$GRPC_MULTI_MODE" ] && add_grpc && printf '      "multiMode": %s' "$GRPC_MULTI_MODE" >> /etc/xray/25_outbound.json
    [ -n "$GRPC_IDLE_TIMEOUT" ] && add_grpc && printf '      "idle_timeout": %s' "$GRPC_IDLE_TIMEOUT" >> /etc/xray/25_outbound.json
    [ -n "$GRPC_HEALTH_CHECK_TIMEOUT" ] && add_grpc && printf '      "health_check_timeout": %s' "$GRPC_HEALTH_CHECK_TIMEOUT" >> /etc/xray/25_outbound.json
    [ -n "$GRPC_PERMIT_WITHOUT_STREAM" ] && add_grpc && printf '      "permit_without_stream": %s' "$GRPC_PERMIT_WITHOUT_STREAM" >> /etc/xray/25_outbound.json
    [ -n "$GRPC_INITIAL_WINDOWS_SIZE" ] && add_grpc && printf '      "initial_windows_size": %s' "$GRPC_INITIAL_WINDOWS_SIZE" >> /etc/xray/25_outbound.json

    printf '\n    },' >> /etc/xray/25_outbound.json
fi

if [ "$NETWORK" = "kcp" ] && [ "$KCP_USED" = "true" ]; then
    printf '\n    "kcpSettings": {\n' >> /etc/xray/25_outbound.json

    FIRST=true
    add_kcp() {
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        FIRST=false
    }

    [ -n "$KCP_MTU" ] && add_kcp && printf '      "mtu": %s' "$KCP_MTU" >> /etc/xray/25_outbound.json
    [ -n "$KCP_TTI" ] && add_kcp && printf '      "tti": %s' "$KCP_TTI" >> /etc/xray/25_outbound.json
    [ -n "$KCP_UPLINK" ] && add_kcp && printf '      "uplinkCapacity": %s' "$KCP_UPLINK" >> /etc/xray/25_outbound.json
    [ -n "$KCP_DOWNLINK" ] && add_kcp && printf '      "downlinkCapacity": %s' "$KCP_DOWNLINK" >> /etc/xray/25_outbound.json
    [ -n "$KCP_CONGESTION" ] && add_kcp && printf '      "congestion": %s' "$KCP_CONGESTION" >> /etc/xray/25_outbound.json
    [ -n "$KCP_READ_BUF" ] && add_kcp && printf '      "readBufferSize": %s' "$KCP_READ_BUF" >> /etc/xray/25_outbound.json
    [ -n "$KCP_WRITE_BUF" ] && add_kcp && printf '      "writeBufferSize": %s' "$KCP_WRITE_BUF" >> /etc/xray/25_outbound.json
    [ -n "$KCP_SEED" ] && add_kcp && printf '      "seed": "%s"' "$KCP_SEED" >> /etc/xray/25_outbound.json

    if [ -n "$KCP_HEADER_TYPE" ] || [ -n "$KCP_HEADER_DOMAIN" ]; then
        add_kcp
        printf '      "header": {' >> /etc/xray/25_outbound.json

        H_FIRST=true
        if [ -n "$KCP_HEADER_TYPE" ]; then
            printf '"type": "%s"' "$KCP_HEADER_TYPE" >> /etc/xray/25_outbound.json
            H_FIRST=false
        fi
        if [ -n "$KCP_HEADER_DOMAIN" ]; then
            [ "$H_FIRST" = false ] && printf ', ' >> /etc/xray/25_outbound.json
            printf '"domain": "%s"' "$KCP_HEADER_DOMAIN" >> /etc/xray/25_outbound.json
        fi

        printf '}' >> /etc/xray/25_outbound.json
    fi

    printf '\n    },' >> /etc/xray/25_outbound.json
fi

if [ "$NETWORK" = "httpupgrade" ] && [ "$HTTPUP_USED" = "true" ]; then
    printf '\n    "httpupgradeSettings": {\n' >> /etc/xray/25_outbound.json

    FIRST=true

    if [ -n "$HTTPUP_PATH" ]; then
        printf '      "path": "%s"' "$HTTPUP_PATH" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$HTTPUP_HOST" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "host": "%s"' "$HTTPUP_HOST" >> /etc/xray/25_outbound.json
        FIRST=false
    fi

    if [ -n "$HTTPUP_HEADERS" ]; then
        [ "$FIRST" = false ] && printf ',\n' >> /etc/xray/25_outbound.json
        printf '      "headers": %s' "$HTTPUP_HEADERS" >> /etc/xray/25_outbound.json
    fi

    printf '\n    },' >> /etc/xray/25_outbound.json
fi
    printf '\n' >> /etc/xray/25_outbound.json
    cat >> /etc/xray/25_outbound.json <<EOF
    "sockopt": {
        "domainStrategy": "ForceIPv4"
    }
  },
  "mux": {
    "enabled": $MUX,
    "concurrency": $MUX_CONCURRENCY,
    "xudpConcurrency": $MUX_XUDPCONCURRENCY,
    "xudpProxyUDP443": "$MUX_XUDPPROXYUDP443"
  }
}
]
}
EOF
}

rm -f "/etc/xray/25_outbound.json"

LINK="$(printf '%s' "$LINK" | sed 's/&amp;/\&/g')"
SCHEME="$(printf '%s' "$LINK" | cut -d':' -f1)"

case "$SCHEME" in
    vless|vmess|trojan|ss)
        parse "$LINK"
        ;;
    *)
        echo "Invalid or unsupported link: $SCHEME" >&2
        ;;
esac

config_file_xray() {
cat > /etc/xray/20_log.json << EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL}"
  }
}
EOF
cat > /etc/xray/21_dns.json << EOF
{
  "dns": {
    "tag": "dns-inbound",
    "hosts": {
      "dns.google": [
        "8.8.8.8",
        "8.8.4.4"
      ],
      "dns.quad9.net": [
        "9.9.9.9",
        "149.112.112.112"
      ],
      "cloudflare-dns.com": [
        "104.16.248.249",
        "104.16.249.249"
      ]
    },
    "servers": [
EOF
if [ "$DNS_MODE" = "fake-ip" ]; then
cat >> /etc/xray/21_dns.json << EOF
      {
        "tag": "fakeip",
        "address": "fakedns"
      },
EOF
fi
cat >> /etc/xray/21_dns.json << EOF
      {
        "tag": "ParallelQuery",
        "address": "https://dns.google/dns-query"
      },
      {
        "tag": "ParallelQuery",
        "address": "https://cloudflare-dns.com/dns-query"
      },
      {
        "tag": "ParallelQuery",
        "address": "https://dns.quad9.net/dns-query"
      }
    ],
    "queryStrategy": "UseIPv4",
    "enableParallelQuery": true
  },
  "fakedns": {
    "ipPool": "${FAKE_IP_RANGE}",
    "poolSize": ${FAKE_POOL_SIZE}
  }
}
EOF

cat > /etc/xray/22_routing.json << EOF
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "inboundTag": ["ParallelQuery"],
        "outboundTag": "direct"
      },
      {
        "inboundTag": ["dns-in"],
        "outboundTag": "dns"
      }
EOF

if [ "$QUIC_DROP" = "true" ]; then
cat >> /etc/xray/22_routing.json << EOF
      ,
      {
        "network": "udp",
        "port": "443",        
        "outboundTag": "block"
      }
EOF

fi
if [ "$DNS_MODE" = "fake-ip" ]; then
cat >> /etc/xray/22_routing.json << EOF
      ,
      {
        "inboundTag": ["all-in"],
        "ip": ["${FAKE_IP_RANGE}"],
        "network": "tcp",
        "outboundTag": "block-http"
      },
      {
        "inboundTag": ["all-in"],
        "ip": ["${FAKE_IP_RANGE}"],
        "network": "udp",
        "outboundTag": "block"
      },
      {
        "inboundTag": ["mixed-in"],
        "ip": ["${FAKE_IP_RANGE}"],
        "network": "tcp",
        "outboundTag": "block-http"
      },
      {
        "inboundTag": ["mixed-in"],
        "ip": ["${FAKE_IP_RANGE}"],
        "network": "udp",
        "outboundTag": "block"
      }
EOF
fi
cat >> /etc/xray/22_routing.json << EOF
    ]
  }
}
EOF
cat > /etc/xray/23_inbounds.json << EOF
{
  "inbounds": [
    {
        "tag": "dns-in",
        "port": 53,
        "protocol": "dokodemo-door",
        "settings": {
            "network": "tcp,udp"
        }
    },
    {
        "tag": "mixed-in",
        "port": 1080, 
        "protocol": "mixed",
        "settings": {
            "udp": true
        },
        "sniffing": {
            "enabled": true,
            "destOverride": [
                "http",
                "tls",
                "quic",
                "fakedns"
            ],
            "metadataOnly": false,
            "routeOnly": true
        }
    },
EOF
if [ "$USE_NFT" = "true" ] && [ "${TPROXY}" = "true" ]; then
cat >> /etc/xray/23_inbounds.json << EOF
    {
      "tag": "all-in",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
        "sniffing": {
            "enabled": true,
            "destOverride": [
                "http",
                "tls",
                "quic",
                "fakedns"
            ],
            "metadataOnly": false,
            "routeOnly": true
        }
    }
  ]
}
EOF
else
cat >> /etc/xray/23_inbounds.json << EOF
    {
      "tag": "all-in",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "redirect"
        }
      },
        "sniffing": {
            "enabled": true,
            "destOverride": [
                "http",
                "tls",
                "quic",
                "fakedns"
            ],
            "metadataOnly": false,
            "routeOnly": true
      }
    }
  ]
}
EOF
fi
cat >> /etc/xray/24_outbounds.json << EOF
{
  "outbounds": [
      {
        "tag": "direct",
        "protocol": "freedom",
        "settings": {
          "domainStrategy": "UseIPv4"
        }
      },
      {
        "tag": "block-http",
        "protocol": "blackhole",
        "settings": {
          "response": {
            "type": "http"
          }
        }
      },
      {
        "tag": "block",
        "protocol": "blackhole"
      },
      {
        "tag": "dns",
        "protocol": "dns",
        "settings": {
          "nonIPQuery": "reject",
          "blockTypes": [65,28]
        }
      }
  ]
}
EOF
}

# ------------------- NFT -------------------
nft_rules() {
  echo "Applying nftables..."
  nft flush ruleset || true
  if [ "${TPROXY}" = "true" ]; then
    nft create table inet xray
    nft add chain inet xray pre "{type filter hook prerouting priority filter; policy accept;}"
    nft add rule inet xray pre tcp option mptcp exists drop
    nft add rule inet xray pre ip daddr ${FAKE_IP_RANGE} meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
    nft add rule inet xray pre ip daddr { $iface_cidr, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
    nft add rule inet xray pre meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
    nft add chain inet xray divert "{type filter hook prerouting priority mangle; policy accept;}"
    nft add rule inet xray divert meta l4proto tcp socket transparent 1 meta mark set 0x00000001 accept
    ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100
    ip route replace local 0.0.0.0/0 dev lo table 100
    echo "Mode inbound TProxy(tcp,udp) interface $iface"
  else
    nft create table inet xray
    nft add chain inet xray pre "{type nat hook prerouting priority -99; policy accept;}"
    nft add rule inet xray pre meta iifname != "$iface" return 
    nft add rule inet xray pre meta l4proto { tcp, udp } th dport 53 iifname "$iface" return
    nft add rule inet xray pre ip daddr { $iface_cidr, 127.0.0.0/8, 100.64.0.1, 224.0.0.0/4, 255.255.255.255 } return
    nft add rule inet xray pre tcp option mptcp exists drop
    nft add rule inet xray pre meta nfproto ipv4 meta l4proto tcp redirect to 12345
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
  iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j RETURN
  iptables -t nat -A PREROUTING -m addrtype ! --dst-type UNICAST -j RETURN
  iptables -t nat -A PREROUTING -i $iface -p tcp -j REDIRECT --to-ports 12345
}

config_file() {
  cat > /hs5t.yml << EOF
misc:
  log-level: 'error'
tunnel:
  name: hs5t
  mtu: 1500
  ipv4: 100.64.0.1
  multi-queue: true
  post-up-script: '/hs5t.sh'
socks5:
  address: '127.0.0.1'
  port: 1080
  udp: 'udp'
EOF
}

hs5t_file() {
  cat > /hs5t.sh << EOF
#!/usr/bin/sh
ip rule show | grep -q 'iif $iface ipproto tcp lookup main' || ip rule add iif $iface ipproto tcp lookup main priority 10000
ip rule show | grep -q 'to $iface_cidr lookup main' || ip rule add to $iface_cidr lookup main priority 10001
ip rule show | grep -q 'to 127.0.0.0/8 lookup main' || ip rule add to 127.0.0.0/8 lookup main priority 10002
ip rule show | grep -q 'to 224.0.0.0/4 lookup main' || ip rule add to 224.0.0.0/4 lookup main priority 10003
ip rule show | grep -q 'to 255.255.255.255 lookup main' || ip rule add to 255.255.255.255 lookup main priority 10004
ip rule show | grep -q 'iif $iface ipproto udp lookup 110' || ip rule add iif $iface ipproto udp lookup 110 priority 10005
ip route replace default via 100.64.0.1 dev hs5t table 110
EOF
chmod +x /hs5t.sh
}

# ------------------- RUN -------------------
run() {
  if [ "$USE_NFT" = "true" ]; then
    nft_rules
    if [ "${TPROXY}" = "false" ]; then
      config_file
      hs5t_file
    fi
  else
    config_file
    hs5t_file
    iptables_rules
  fi
  config_file_xray
  echo "Starting xray $(./xray --version)"
  if [ "$USE_NFT" = "false" ] || [ "${TPROXY}" = "false" ]; then
    echo "Starting hev-socks5-tunnel $(./hs5t --version | head -n 2 | tail -n 1)"
    ./hs5t ./hs5t.yml &
  fi
    exec ./xray run -confdir /etc/xray
}

run || exit 1
