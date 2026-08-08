#!/bin/sh
# Network Speed Test for Route Tool
# Tests: download, upload, ping, IPv6 readiness, NAT type, upstream latency
# BusyBox compatible, no external dependencies beyond curl/wget
# Usage: network_speed.sh [action] [options]
#   network_speed.sh quick          - Quick network check (ping + download)
#   network_speed.sh download       - Download speed test
#   network_speed.sh upload         - Upload speed test (requires writable endpoint)
#   network_speed.sh ping           - Ping latency to multiple targets
#   network_speed.sh ipv6           - IPv6 readiness check
#   network_speed.sh nat            - NAT type detection
#   network_speed.sh upstream       - Upstream/gateway latency
#   network_speed.sh lan            - LAN speed test (iperf3-like via dd+nc)
#   network_speed.sh full           - Full network diagnostic

ARG="${1:-quick}"
SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR="."
[ -f "$SCRIPT_DIR/storage_common.sh" ] && . "$SCRIPT_DIR/storage_common.sh" 2>/dev/null || true

# ── Helpers ──
now_ms() { if [ -r /proc/uptime ]; then awk '{printf "%.0f", $1*1000}' /proc/uptime; else date +%s%3N 2>/dev/null || echo "0"; fi; }
fmt_bps() {
    local bps="$1"
    [ -z "$bps" ] && echo "0 bps" && return
    local n=$(echo "$bps" | awk '{printf "%.0f", $1}')
    if [ "$n" -ge 1000000000 ] 2>/dev/null; then echo "$bps" | awk '{printf "%.2f Gbps", $1/1000000000}'
    elif [ "$n" -ge 1000000 ] 2>/dev/null; then echo "$bps" | awk '{printf "%.2f Mbps", $1/1000000}'
    elif [ "$n" -ge 1000 ] 2>/dev/null; then echo "$bps" | awk '{printf "%.2f Kbps", $1/1000}'
    else echo "${bps} bps"; fi
}
fmt_ms() { echo "$1" | awk '{v=$1+0; if(v<1) printf "%.3f ms", v; else if(v<100) printf "%.1f ms", v; else printf "%.0f ms", v}'; }
fmt_bytes() { echo "$1" | awk '{v=$1+0; if(v>=1073741824) printf "%.2f GB", v/1073741824; else if(v>=1048576) printf "%.2f MB", v/1048576; else if(v>=1024) printf "%.1f KB", v/1024; else printf "%.0f B", v}'; }

has_curl() { command -v curl >/dev/null 2>&1; }
has_wget() { command -v wget >/dev/null 2>&1; }
has_ipv6() { [ -f /proc/net/if_inet6 ] && grep -qc '.' /proc/net/if_inet6 2>/dev/null; }

# Fetch URL to /dev/null, return bytes and time_ms
# Usage: fetch_timed <url> <max_time_sec>
fetch_timed() {
    local url="$1" maxt="${2:-30}"
    local start end bytes rc
    start=$(now_ms)
    if has_curl; then
        bytes=$(curl -s -o /dev/null -w '%{size_download}' --max-time "$maxt" "$url" 2>/dev/null)
        rc=$?
    elif has_wget; then
        # wget to /dev/null directly, no tmp file needed
        wget -q -T "$maxt" -O /dev/null "$url" 2>/dev/null
        rc=$?
        # wget can't report actual bytes to /dev/null; estimate from URL param or mark as unknown
        bytes=$(echo "$url" | awk -F'bytes=' '{print $2}' | awk -F'&' '{print $1}')
        [ -z "$bytes" ] && bytes=0
    else
        echo "0 0 1"
        return
    fi
    end=$(now_ms)
    local elapsed=$(( end - start ))
    [ "$elapsed" -le 0 ] && elapsed=1
    echo "${bytes:-0} ${elapsed} ${rc}"
}

# ── Ping Test ──
do_ping() {
    local targets="114.114.114.114 223.5.5.5 8.8.8.8 1.1.1.1"
    local count=5
    echo "NET_TEST=ping"
    echo "PING_COUNT=$count"
    local best_lat=99999 worst_lat=0 total_lat=0 loss_total=0 sent_total=0
    for target in $targets; do
        # Try ICMP first, fall back to TCP connect timing
        local out=$(ping -c "$count" -W 3 "$target" 2>/dev/null)
        local loss=$(echo "$out" | awk '/received/ {match($0, /([0-9]+)%/, a); print a[1]+0}')
        local lat=$(echo "$out" | awk -F/ '/^rtt/ {printf "%.1f", $5}')
        if [ -z "$lat" ] || [ "$lat" = "999" ]; then
            # ICMP failed, try TCP connect
            if has_curl; then
                local tcp_lat=$(curl -s -o /dev/null -w '%{time_connect}' --max-time 5 "https://${target}" 2>/dev/null)
                if [ -n "$tcp_lat" ] && [ "$tcp_lat" != "0.000" ] && [ "$tcp_lat" != "0.000000" ]; then
                    lat=$(echo "$tcp_lat" | awk '{printf "%.1f", $1*1000}')
                    loss=0
                else
                    lat=999
                    loss=100
                fi
            else
                lat=999
                loss=100
            fi
        fi
        [ -z "$loss" ] && loss=100
        local sent=$count
        sent_total=$((sent_total + sent))
        loss_total=$((loss_total + sent * loss / 100))
        echo "PING_${target}_LATENCY=${lat}ms"
        echo "PING_${target}_LOSS=${loss}%"
        local lat_n=$(echo "$lat" | awk '{printf "%.0f", $1}')
        [ "$lat_n" -lt "$best_lat" ] 2>/dev/null && best_lat=$lat_n
        [ "$lat_n" -gt "$worst_lat" ] 2>/dev/null && worst_lat=$lat_n
        total_lat=$(echo "$total_lat $lat" | awk '{printf "%.1f", $1+$2}')
    done
    local avg_lat=$(echo "$total_lat" | awk -v n=4 '{printf "%.1f", $1/n}')
    local total_loss=$(awk "BEGIN{printf \"%.0f\", $sent_total>0 ? $loss_total*100/$sent_total : 0}")
    echo "PING_BEST=${best_lat}ms"
    echo "PING_WORST=${worst_lat}ms"
    echo "PING_AVG=${avg_lat}ms"
    echo "PING_LOSS=${total_loss}%"
    echo "PING_DONE=1"
}

# ── Download Speed Test ──
do_download() {
    echo "NET_TEST=download"
    # Test files: Cloudflare speed test endpoints (no signup, CDN-wide)
    # Note: Cloudflare limits single request to ~50MB; use multiple for larger
    local urls="https://speed.cloudflare.com/__down?bytes=10000000 https://speed.cloudflare.com/__down?bytes=25000000 https://speed.cloudflare.com/__down?bytes=50000000"
    local total_bytes=0 total_ms=0
    for url in $urls; do
        local size_label=$(echo "$url" | awk -F= '{printf "%.0f", $2/1000000}')
        echo "DL_TESTING=${size_label}MB"
        local result=$(fetch_timed "$url" 30)
        local bytes=$(echo "$result" | awk '{print $1}')
        local ms=$(echo "$result" | awk '{print $2}')
        local rc=$(echo "$result" | awk '{print $3}')
        if [ "$rc" = "0" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
            local bps=$(awk -v b="$bytes" -v m="$ms" 'BEGIN{printf "%.0f", b*8000/m}')
            echo "DL_${size_label}MB=$(fmt_bps "$bps")"
            echo "DL_${size_label}MB_RAW=${bps}"
            echo "DL_${size_label}MB_BYTES=${bytes}"
            total_bytes=$((total_bytes + bytes))
            total_ms=$((total_ms + ms))
        else
            echo "DL_${size_label}MB=FAILED"
        fi
    done
    if [ "$total_bytes" -gt 0 ] 2>/dev/null; then
        local avg_bps=$(awk -v b="$total_bytes" -v m="$total_ms" 'BEGIN{printf "%.0f", b*8000/m}')
        echo "DL_AVG=$(fmt_bps "$avg_bps")"
        echo "DL_AVG_RAW=${avg_bps}"
        echo "DL_TOTAL_BYTES=$(fmt_bytes "$total_bytes")"
    else
        echo "DL_AVG=FAILED"
    fi
    echo "DL_DONE=1"
}

# ── Upload Speed Test ──
do_upload() {
    echo "NET_TEST=upload"
    # Upload test: Cloudflare __up endpoint often blocked by proxy
    # Skip probe and go straight to fallback
    echo "UL_AVG=需直连测速"
    echo "UL_NOTE=上传测速需直连网络(关闭代理)，当前跳过"
    echo "UL_DONE=1"
}

# ── IPv6 Readiness ──
do_ipv6() {
    echo "NET_TEST=ipv6"
    # Check kernel support
    if has_ipv6; then
        echo "IPV6_KERNEL=yes"
    else
        echo "IPV6_KERNEL=no"
        echo "IPV6_STATUS=unsupported"
        echo "IPV6_DONE=1"
        return
    fi

    # Check WAN IPv6 address
    local wan6=""
    for dev in wan wan6 eth0.2 eth1; do
        wan6=$(ip -6 addr show dev "$dev" 2>/dev/null | awk '/inet6/ && !/fe80|::1/ {print $2; exit}')
        [ -n "$wan6" ] && break
    done
    if [ -n "$wan6" ]; then
        echo "IPV6_WAN_ADDR=${wan6}"
        echo "IPV6_WAN=yes"
    else
        echo "IPV6_WAN=no"
    fi

    # Check default IPv6 route
    local def6=$(ip -6 route show default 2>/dev/null | head -1)
    if [ -n "$def6" ]; then
        echo "IPV6_ROUTE=yes"
        echo "IPV6_GW=$(echo "$def6" | awk '{print $3, $4, $5}')"
    else
        echo "IPV6_ROUTE=no"
    fi

    # Test IPv6 connectivity - ping
    local ping6_ok=0
    for target in 2400:3200::1 2001:4860:4860::8888 2606:4700:4700::1111; do
        if ping6 -c 2 -W 3 "$target" >/dev/null 2>&1; then
            ping6_ok=1
            echo "IPV6_PING_${target}=ok"
            break
        fi
    done
    echo "IPV6_PING=$([ "$ping6_ok" = "1" ] && echo ok || echo fail)"

    # Test IPv6 HTTP - get public IPv6
    local v6_ip=""
    if has_curl; then
        # Try direct IPv6 with resolved address to bypass fake-ip
        for host in api6.ipify.org v6.ident.me ipv6.icanhazip.com; do
            v6_ip=$(curl -6 -s --max-time 8 --resolve "${host}:443:[]" "https://${host}/" 2>/dev/null)
            [ -z "$v6_ip" ] && v6_ip=$(curl -6 -s --max-time 8 "https://${host}/" 2>/dev/null)
            if echo "$v6_ip" | grep -qE '^2[0-4][0-9]{2}:'; then
                echo "IPV6_PUBLIC=${v6_ip}"
                break
            fi
            v6_ip=""
        done
    fi
    [ -z "$v6_ip" ] && echo "IPV6_PUBLIC=unreachable"

    # DNS AAAA resolution test
    local aaaa=""
    if has_curl; then
        aaaa=$(nslookup ipv6.google.com 223.5.5.5 2>/dev/null | awk '/Address/ && !/223.5.5.5/ {print $3; exit}')
    fi
    if echo "$aaaa" | grep -qE '^2[0-4][0-9]{2}:'; then
        echo "IPV6_DNS=yes"
    else
        echo "IPV6_DNS=no"
    fi

    # Summary
    local score=0
    [ "$(has_ipv6 && echo y)" = "y" ] && score=$((score+2))
    [ -n "$wan6" ] && score=$((score+2))
    [ -n "$def6" ] && score=$((score+2))
    [ "$ping6_ok" = "1" ] && score=$((score+2))
    [ -n "$v6_ip" ] && score=$((score+2))
    echo "IPV6_SCORE=${score}/10"
    if [ "$score" -ge 8 ]; then
        echo "IPV6_STATUS=✅ IPv6 完全可用"
    elif [ "$score" -ge 4 ]; then
        echo "IPV6_STATUS=⚠️ IPv6 部分可用"
    else
        echo "IPV6_STATUS=❌ IPv6 不可用"
    fi
    echo "IPV6_DONE=1"
}

# ── NAT Type Detection ──
do_nat() {
    echo "NET_TEST=nat"
    # Use STUN-like approach via Cloudflare
    local wan_ip="" wan_port=""
    # Get public IP (try multiple sources)
    for ip_src in "https://ifconfig.me" "https://ip.sb" "https://api.ipify.org"; do
        wan_ip=$(curl -4 -s --max-time 8 "$ip_src" 2>/dev/null)
        if echo "$wan_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then break; fi
        wan_ip=""
    done
    echo "NAT_PUBLIC_IP=${wan_ip:-unknown}"

    # Get local WAN IP
    local local_wan=$(ip -4 addr show wan 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    echo "NAT_LOCAL_WAN=${local_wan:-unknown}"

    # Determine NAT type
    if [ -z "$wan_ip" ]; then
        echo "NAT_TYPE=UNKNOWN"
        echo "NAT_DESC=无法获取公网IP"
    elif [ "$wan_ip" = "$local_wan" ]; then
        echo "NAT_TYPE=PUBLIC"
        echo "NAT_DESC=公网IP，无NAT"
    else
        # Check if behind CGNAT or regular NAT
        local is_cgnat=0
        case "$wan_ip" in
            100.64.*|100.65.*|100.66.*|100.67.*|100.68.*|100.69.*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.10[0-1].*)
                is_cgnat=1 ;;
        esac
        if [ "$is_cgnat" = "1" ]; then
            echo "NAT_TYPE=CGNAT"
            echo "NAT_DESC=运营商级NAT (CGNAT)，无法端口映射"
        else
            echo "NAT_TYPE=NAT"
            echo "NAT_DESC=普通NAT，可能支持端口映射"
        fi
    fi

    # Check UPnP status
    if command -v upnpc >/dev/null 2>&1; then
        local upnp_status=$(upnpc -s 2>/dev/null | head -5)
        echo "NAT_UPNP=$([ -n "$upnp_status" ] && echo available || echo unavailable)"
    else
        echo "NAT_UPNP=not_installed"
    fi

    echo "NAT_DONE=1"
}

# ── Upstream/Gateway Test ──
do_upstream() {
    echo "NET_TEST=upstream"
    # Gateway latency (try ICMP, then TCP)
    local gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    echo "UPSTREAM_GW=${gw:-unknown}"
    if [ -n "$gw" ]; then
        local gw_lat=$(ping -c 5 -W 2 "$gw" 2>/dev/null | awk -F/ '/^rtt/ {printf "%.1f", $5}')
        if [ -z "$gw_lat" ]; then
            # ICMP failed, try TCP to gateway (common port 80/443)
            if has_curl; then
                gw_lat=$(curl -s -o /dev/null -w '%{time_connect}' --max-time 3 "http://${gw}" 2>/dev/null)
                if [ -n "$gw_lat" ] && [ "$gw_lat" != "0.000" ] && [ "$gw_lat" != "0.000000" ]; then
                    gw_lat=$(echo "$gw_lat" | awk '{printf "%.1f", $1*1000}')
                else
                    gw_lat="timeout"
                fi
            else
                gw_lat="timeout"
            fi
        fi
        echo "UPSTREAM_GW_LATENCY=${gw_lat}ms"
    fi

    # DNS upstream latency (TCP connect to port 53 or 443)
    local dns_servers="223.5.5.5 114.114.114.114 8.8.8.8 1.1.1.1"
    for dns in $dns_servers; do
        local lat=$(ping -c 3 -W 2 "$dns" 2>/dev/null | awk -F/ '/^rtt/ {printf "%.1f", $5}')
        if [ -z "$lat" ]; then
            # ICMP failed, try TCP connect
            if has_curl; then
                lat=$(curl -s -o /dev/null -w '%{time_connect}' --max-time 5 "https://${dns}" 2>/dev/null)
                if [ -n "$lat" ] && [ "$lat" != "0.000" ] && [ "$lat" != "0.000000" ]; then
                    lat=$(echo "$lat" | awk '{printf "%.1f", $1*1000}')
                else
                    lat="timeout"
                fi
            else
                lat="timeout"
            fi
        fi
        echo "UPSTREAM_DNS_${dns}=${lat}ms"
    done

    # ISP gateway (first hop beyond local gateway) - use TCP
    local isp_lat=""
    if has_curl; then
        isp_lat=$(curl -s -o /dev/null -w '%{time_connect}' --max-time 5 "https://223.5.5.5" 2>/dev/null)
        if [ -n "$isp_lat" ] && [ "$isp_lat" != "0.000" ] && [ "$isp_lat" != "0.000000" ]; then
            isp_lat=$(echo "$isp_lat" | awk '{printf "%.1f", $1*1000}')
        else
            isp_lat="timeout"
        fi
    else
        isp_lat=$(ping -c 3 -W 3 -t 2 "223.5.5.5" 2>/dev/null | awk -F/ '/^rtt/ {printf "%.1f", $5}')
        [ -z "$isp_lat" ] && isp_lat="timeout"
    fi
    echo "UPSTREAM_ISP_LATENCY=${isp_lat}ms"

    echo "UPSTREAM_DONE=1"
}

# ── LAN Speed Test ──
do_lan() {
    echo "NET_TEST=lan"
    # Test LAN throughput by writing/reading to a local samba/webdav share if available
    # Otherwise test local loopback as baseline
    local lan_targets=""

    # Check for local HTTP servers (Lucky, nginx, etc.)
    for port in 80 443 8080 3200; do
        if curl -s --max-time 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            lan_targets="$lan_targets 127.0.0.1:${port}"
        fi
    done

    # Check for Samba shares
    if command -v smbclient >/dev/null 2>&1; then
        local shares=$(smbclient -L //127.0.0.1 -N 2>/dev/null | awk '/Disk/ {print $2}')
        echo "LAN_SAMBA_SHARES=$shares"
    fi

    # Loopback speed baseline
    local tmp="/tmp/route-tool-lan-$$.dat"
    dd if=/dev/zero of="$tmp" bs=1M count=8 2>/dev/null
    local start=$(now_ms)
    dd if="$tmp" of=/dev/null bs=1M 2>/dev/null
    local end=$(now_ms)
    rm -f "$tmp"
    local ms=$((end - start))
    [ "$ms" -le 0 ] && ms=1
    local loop_bps=$(awk -v b=8388608 -v m="$ms" 'BEGIN{printf "%.0f", b*8000/m}')
    echo "LAN_LOOPBACK=$(fmt_bps "$loop_bps")"
    echo "LAN_LOOPBACK_RAW=${loop_bps}"

    # LAN interface speeds
    for iface in br-lan eth0 eth1; do
        local speed=$(cat /sys/class/net/"$iface"/speed 2>/dev/null)
        local state=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null)
        if [ -n "$speed" ] && [ "$state" = "up" ]; then
            echo "LAN_${iface}_SPEED=${speed}Mbps"
            echo "LAN_${iface}_STATE=${state}"
        fi
    done

    echo "LAN_DONE=1"
}

# ── Quick Test ──
do_quick() {
    echo "NET_TEST=quick"
    echo "NET_QUICK_START=1"

    # Public IP (try multiple sources, some may be blocked by proxy)
    local pub_ip=""
    for ip_src in "https://ifconfig.me" "https://ip.sb" "https://api.ipify.org" "https://api64.ipify.org"; do
        if has_curl; then
            pub_ip=$(curl -4 -s --max-time 8 "$ip_src" 2>/dev/null)
        elif has_wget; then
            pub_ip=$(wget -q -T 8 -O - "$ip_src" 2>/dev/null)
        fi
        # Validate: must look like an IPv4
        if echo "$pub_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            break
        fi
        pub_ip=""
    done
    echo "NET_PUBLIC_IP=${pub_ip:-unknown}"

    # Quick ping (use TCP connect for reliability through proxy/transparent firewalls)
    local lat=""
    if has_curl; then
        # TCP connect timing via curl
        lat=$(curl -s -o /dev/null -w '%{time_connect}' --max-time 5 "https://223.5.5.5" 2>/dev/null)
        if [ -n "$lat" ] && [ "$lat" != "0.000" ] && [ "$lat" != "0.000000" ]; then
            local lat_ms=$(echo "$lat" | awk '{printf "%.1f", $1*1000}')
            echo "NET_PING_223=${lat_ms}ms"
        else
            echo "NET_PING_223=timeout"
        fi
        local lat2=$(curl -s -o /dev/null -w '%{time_connect}' --max-time 5 "https://1.1.1.1" 2>/dev/null)
        if [ -n "$lat2" ] && [ "$lat2" != "0.000" ] && [ "$lat2" != "0.000000" ]; then
            local lat2_ms=$(echo "$lat2" | awk '{printf "%.1f", $1*1000}')
            echo "NET_PING_8888=${lat2_ms}ms"
        else
            echo "NET_PING_8888=timeout"
        fi
    else
        lat=$(ping -c 3 -W 3 223.5.5.5 2>/dev/null | awk -F/ '/^rtt/ {printf "%.1f", $5}')
        echo "NET_PING_223=${lat:-timeout}ms"
        local lat2=$(ping -c 3 -W 3 1.1.1.1 2>/dev/null | awk -F/ '/^rtt/ {printf "%.1f", $5}')
        echo "NET_PING_8888=${lat2:-timeout}ms"
    fi

    # Quick download (10MB)
    local result=$(fetch_timed "https://speed.cloudflare.com/__down?bytes=10000000" 15)
    local bytes=$(echo "$result" | awk '{print $1}')
    local ms=$(echo "$result" | awk '{print $2}')
    local rc=$(echo "$result" | awk '{print $3}')
    if [ "$rc" = "0" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
        local bps=$(awk -v b="$bytes" -v m="$ms" 'BEGIN{printf "%.0f", b*8000/m}')
        echo "NET_DL_QUICK=$(fmt_bps "$bps")"
        echo "NET_DL_QUICK_RAW=${bps}"
    else
        echo "NET_DL_QUICK=FAILED"
    fi

    # IPv6 quick check
    if has_ipv6; then
        local v6=$(ping6 -c 1 -W 3 2400:3200::1 2>/dev/null | awk -F/ '/^rtt/ {printf "%.1f", $5}')
        echo "NET_IPV6=$([ -n "$v6" ] && echo "ok ${v6}ms" || echo "unreachable")"
    else
        echo "NET_IPV6=no_kernel_support"
    fi

    # NAT quick
    if [ -n "$pub_ip" ]; then
        local local_wan=$(ip -4 addr show wan 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
        if [ "$pub_ip" = "$local_wan" ]; then
            echo "NET_NAT=PUBLIC"
        else
            echo "NET_NAT=NAT"
        fi
    else
        echo "NET_NAT=UNKNOWN"
    fi

    echo "NET_QUICK_DONE=1"
}

# ── Full Test ──
do_full() {
    echo "NET_TEST=full"
    echo "NET_FULL_START=1"
    echo "=== Quick Check ==="
    do_quick
    echo ""
    echo "=== Ping Test ==="
    do_ping
    echo ""
    echo "=== Download Speed ==="
    do_download
    echo ""
    echo "=== Upload Speed ==="
    do_upload
    echo ""
    echo "=== IPv6 Readiness ==="
    do_ipv6
    echo ""
    echo "=== NAT Type ==="
    do_nat
    echo ""
    echo "=== Upstream Latency ==="
    do_upstream
    echo ""
    echo "NET_FULL_DONE=1"
}

# ── Main ──
case "$ARG" in
    quick)     do_quick ;;
    ping)      do_ping ;;
    download)  do_download ;;
    upload)    do_upload ;;
    ipv6)      do_ipv6 ;;
    nat)       do_nat ;;
    upstream)  do_upstream ;;
    lan)       do_lan ;;
    full)      do_full ;;
    *)         echo "ERROR=unknown_action"; echo "AVAILABLE=quick,ping,download,upload,ipv6,nat,upstream,lan,full"; exit 1 ;;
esac
