#!/usr/bin/sh
set -eu

FAKE_IP_RANGE="${FAKE_IP_RANGE:-198.18.0.0/15}"
LOG_LEVEL="${LOG_LEVEL:-error}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }

first_iface() {
  ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d'@' -f1 | head -n1
}
iface=$(first_iface)
iface_ip=$(ip -4 -o addr show dev "$iface" scope global | awk '{print $4}' | cut -d/ -f1)
gateway=$(ip route show default dev "$iface" | awk '{print $3; exit}')

config_file_xray() {
cat > /etc/xray/config.json << EOF
{
  "log": {
    "access": "none",
    "error": "none",
    "loglevel": "${LOG_LEVEL}",
    "dnsLog": false
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
      },
      {
        "address": "https://dns.quad9.net/dns-query",
        "domains": [
          "geosite:tmdb"
        ],
        "skipFallback": true
      },
      {
        "tag": "fakeip",
        "address": "fakedns",
        "skipFallback": true
      }
    ],
    "queryStrategy": "UseIPv4",
    "enableParallelQuery": true
  },
  "fakedns": {
    "ipPool": "${FAKE_IP_RANGE}",
    "poolSize": 130000
  }
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "inboundTag": ["ParallelQuery"],
        "outboundTag": "direct"
      },
      {
        "inboundTag": ["dns-in"],
        "outboundTag": "fakeip"
      }
    ],  
  },
  "inbounds": [
    {
        "port": 53,
        "protocol": "dokodemo-door",
        "settings": {
            "address": "127.0.0.1",
            "port": 53,
            "network": "tcp,udp"
        },
        "tag": "dns-in"
    },
    {
        "listen": "0.0.0.0", 
        "port": 1080, 
        "protocol": "socks",
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
            "routeOnly": true
        }
    },
EOF
if lsmod | grep -q '^nft_tproxy'; then
cat >> /etc/xray/config.json << EOF
    {
      "tag": "all-in",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
                "http",
                "tls",
                "quic",
                "fakedns"
        ]
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
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
      "sniffing": {
        "enabled": true,
        "destOverride": [
                "http",
                "tls",
                "quic",
                "fakedns"
        ]
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "redirect"
        }
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
        ip daddr ${FAKE_IP_RANGE} meta l4proto { tcp, udp } iifname "$iface" meta mark set 0x00000001 tproxy ip to 127.0.0.1:12345 accept
        ip daddr { $iface_ip, 0.0.0.0/8, 127.0.0.0/8, 224.0.0.0/4, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 192.88.99.0/24, 198.18.0.0/15, 224.0.0.0/3 } return
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
#  iptables -t nat -i $iface -p tcp -m tcp --dport 53 -j RETURN
#  iptables -t nat -i $iface -p tcp -m tcp --dport 1080 -j RETURN
  iptables -t nat -m addrtype --dst-type LOCAL -j RETURN
  iptables -t nat -i $iface -p tcp -j REDIRECT --to-ports 12345
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
ip rule show | grep -q 'uidrange 1000-1000 lookup main' || ip rule add from all uidrange 1000-1000 lookup main
ip rule show | grep -q 'ipproto udp lookup 110' || ip rule add ipproto udp table 110 pref 50000
ip route replace default via 100.64.0.1 dev hs5t table 110 metric 1
ip route replace ${FAKE_IP_RANGE} via 100.64.0.1 dev hs5t metric 10 table 110
ip route replace 0.0.0.0/8 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 127.0.0.0/8 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 224.0.0.0/4 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 10.0.0.0/8 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 172.16.0.0/12 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 192.168.0.0/16 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 100.64.0.0/10 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 169.254.0.0/16 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 192.0.0.0/24 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 192.0.2.0/24 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 198.51.100.0/24 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 203.0.113.0/24 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 192.88.99.0/24 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 198.18.0.0/15 via "$gateway" dev "$iface" metric 20 table 110
ip route replace 224.0.0.0/3 via "$gateway" dev "$iface" metric 20 table 110

EOF
chmod +x /hs5t.sh
}

# ------------------- RUN -------------------
run() {
  if lsmod | grep -q '^nft_tproxy'; then
    nft_rules
  else
    if ! id -u xray >/dev/null 2>&1; then
      adduser -u 1000 -D -H xray
    fi
    iptables_rules
    config_file
    hs5t_file
  fi
  if ! lsmod | grep -q '^nft_tproxy'; then
    echo "Starting hev-socks5-tunnel $(./hs5t --version | head -n 2 | tail -n 1)"
  fi
  config_file_xray
  echo "Starting xray $(./xray -v)"
  if lsmod | grep -q '^nft_tproxy'; then
    exec ./xray
  else
    ./hs5t ./hs5t.yml &   
    exec su xray -s /bin/sh -c './xray'
  fi
}

run || exit 1
