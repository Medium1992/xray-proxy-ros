#!/bin/sh
set -eu
IPTABLES="${IPTABLES:-false}"

if [ "$IPTABLES" = "false" ] && lsmod | grep -q '^nft_tproxy'; then
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

mkdir -p /etc/xray

FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
LOG_LEVEL="${LOG_LEVEL:-error}"

CIDR_MASK="${FAKE_IP_RANGE##*/}"
FAKE_POOL_SIZE=$(( (1 << (32 - CIDR_MASK)) - 2 ))

log() { echo "[$(date +'%H:%M:%S')] $*"; }

first_iface() {
  ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d'@' -f1 | head -n1
}
iface=$(first_iface)
iface_cidr=$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}')
iface_ip=$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}' | cut -d/ -f1)
gateway=$(ip route show default dev "$iface" | awk '{print $3; exit}')

config_file_xray() {
cat > /etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL}"
  },
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
      {
        "tag": "fakeip",
        "address": "fakedns"
      },
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
  },
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
      },
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
    ]
  },
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
                "fakedns"
            ],
            "metadataOnly": true,
            "routeOnly": true
        }
    },
EOF
if [ "$USE_NFT" = "true" ]; then
cat >> /etc/xray/config.json << EOF
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
                "fakedns"
            ],
            "metadataOnly": true,
            "routeOnly": true
        }
    }
  ],
EOF
else
cat >> /etc/xray/config.json << EOF
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
                "fakedns"
            ],
            "metadataOnly": true,
            "routeOnly": true
      }
    }
  ],
EOF
fi
cat >> /etc/xray/config.json << EOF
  "outbounds": [

EOF

cat >> /etc/xray/config.json << EOF
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
  nft -f - <<EOF
table inet xray {
    chain prerouting {
        type filter hook prerouting priority filter; policy accept;
        ip daddr $FAKE_IP_RANGE meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
        ip daddr { $iface_cidr, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 } return
        meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
    }
    chain divert {
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto tcp socket transparent 1 meta mark set 0x00000001 accept
    }
}
EOF
  ip rule show | grep -q 'fwmark 0x00000001 lookup 100' || ip rule add fwmark 1 table 100
  ip route replace local 0.0.0.0/0 dev lo table 100
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
  iptables -t mangle -A PREROUTING -m addrtype --dst-type LOCAL -j ACCEPT
  iptables -t mangle -A PREROUTING -m addrtype ! --dst-type UNICAST -j ACCEPT
  iptables -t mangle -A PREROUTING -i "$iface" -p udp -j MARK --set-mark 110
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
#!/bin/sh
ip rule show | grep -q 'fwmark 0x6e ipproto udp lookup 110' || ip rule add fwmark 110 ipproto udp table 110
ip route replace default via 100.64.0.1 dev hs5t table 110
EOF
chmod +x /hs5t.sh
}

# ------------------- RUN -------------------
run() {
  if [ "$USE_NFT" = "true" ]; then
    nft_rules
  else
    config_file
    hs5t_file
    iptables_rules
  fi
  if [ "$USE_NFT" = "false" ]; then
    echo "Starting hev-socks5-tunnel $(./hs5t --version | head -n 2 | tail -n 1)"
  fi
  config_file_xray
  echo "Starting xray $(./xray --version)"
  if [ "$USE_NFT" = "true" ]; then
    exec ./xray -config /etc/xray/config.json
  else
    ./hs5t ./hs5t.yml &
    exec ./xray -config /etc/xray/config.json
  fi
}

run || exit 1
