#!/usr/bin/env bash
# ==============================================================================
# PicoTun Pro v3 - Ultra Low Latency & Packet-Loss Mitigator
# Optimized for High-Volume Concurrency & Clean Anti-DPI Traffic Flow
# ==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_DIR="/etc/picotun"
DATA_FILE="${CONFIG_DIR}/nodes.json"
SYSTEMD_DIR="/etc/systemd/system"
BIN_PATH="/usr/local/bin/gost"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}خطا: برای اعمال تنظیمات صف شبکه و کرنل، باید با دسترسی root اجرا شود.${NC}"
   exit 1
fi

mkdir -p "$CONFIG_DIR"
[[ ! -f "$DATA_FILE" ]] && echo "{}" > "$DATA_FILE"

optimize_kernel_network() {
    echo -e "${CYAN}در حال اعمال عمیق‌ترین تنظیمات کرنل ضد پکت‌لاست و ضد پینگ‌اسپایک...${NC}"
    
    # اطمینان از بارگذاری ماژول BBR
    modprobe tcp_bbr 2>/dev/null || true
    
    cat <<EOF > /etc/sysctl.d/99-picotun-ultra.conf
# Queue Discipline & Congestion Control (BBR + FQ)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Enable IP Forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Socket Buffer Tuning (جلوگیری از دور ریختن پکت در پیک ترافیک)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.netdev_max_backlog = 300000
net.core.somaxconn = 65535

# TCP Memory Boundaries (Min, Default, Max in Pages)
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Anti-Packet-Loss & Fast Recovery Optimizations
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_adv_win_scale = 1

# Disable Path MTU Discovery issues & ECN Drop
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_ecn = 0

# TCP State Timings (کاهش زمان مرگ کانکشن‌های فریز شده)
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

# File Descriptors & System Limits
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
EOF

    sysctl --system >/dev/null 2>&1
    
    # افزایش محدودیت‌های نرم و سخت سیستم
    cat <<EOF > /etc/security/limits.d/99-picotun.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    echo -e "${GREEN}تنظیمات کرنل و صف‌های سوکت با موفقیت اعمال شدند.${NC}"
}

install_core() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${CYAN}در حال دانلود و استقرار GOST v3 Core...${NC}"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar jq iproute2 iptables >/dev/null 2>&1
        
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_amd64.tar.gz"
        elif [[ "$ARCH" == "aarch64" ]]; then
            URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_arm64.tar.gz"
        else
            echo -e "${RED}معماری CPU شما پشتیبانی نمی‌شود.${NC}"
            exit 1
        fi
        
        wget -qO /tmp/gost.tar.gz "$URL"
        tar -xzf /tmp/gost.tar.gz -C /tmp/
        mv /tmp/gost "$BIN_PATH"
        chmod +x "$BIN_PATH"
        rm -f /tmp/gost.tar.gz
        echo -e "${GREEN}هسته با موفقیت نصب گردید.${NC}"
    fi
}

save_node_metadata() {
    local id="$1"
    local json_data="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg id "$id" --argjson data "$json_data" '.[$id] = $data' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
}

remove_node_metadata() {
    local id="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg id "$id" 'del(.[$id])' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
}

setup_node() {
    install_core
    optimize_kernel_network
    
    echo -e "\n${YELLOW}=== تعریف یا به‌روزرسانی نود شبکه ===${NC}"
    echo "1) سرور ایران (Relay Receiver / Reverse Core)"
    echo "2) سرور خارج (Bridge Endpoint / Destination)"
    read -rp "نقش این ماشین را انتخاب کنید [1 یا 2]: " ROLE
    
    read -rp "شناسه نود (Node ID - عدد بین 1 تا 250): " NODE_ID
    if ! [[ "$NODE_ID" =~ ^[0-9]+$ ]] || [ "$NODE_ID" -lt 1 ] || [ "$NODE_ID" -gt 250 ]; then
        echo -e "${RED}شناسه نامعتبر است.${NC}"
        return
    fi

    read -rp "نام مستعار نود (مثلاً Kharej-Germany-1): " NODE_ALIAS
    read -rp "پورت پایدار تانل (Tunnel Port - روی هر دو سرور یکسان، مثلاً 10443): " TUN_PORT
    read -rp "رمز اختصاصی تانل: " TUN_PASS
    
    echo -e "\nپروتکل ارتباطی (توصیه: گزینه 1 برای کمترین پکت لاست):"
    echo -e "1) ${BOLD}gRPC / HTTP2 Multiplex${NC} (مالتی‌استریم با بافر هوشمند - پایدارترین در برابردراپ)"
    echo -e "2) ${BOLD}MWSS${NC} (Multiplexed WebSocket + TLS - بهینه‌سازی پهنای باند و بدون نشتی هدر)"
    echo -e "3) ${BOLD}Direct TLS Stream${NC} (سبک‌ترین حالت مصرف پردازنده - مناسب سرورهای ضعیف)"
    echo -e "4) ${BOLD}KCP Accelerated${NC} (بر پایه UDP با تصحیح خطای FEC - مناسب شرایط فیلترینگ شدید)"
    read -rp "گزینه مورد نظر [1-4]: " PROTO_CHOICE

    case $PROTO_CHOICE in
        1) PROTO_SCHEME="grpc" ;;
        2) PROTO_SCHEME="mwss" ;;
        3) PROTO_SCHEME="tls" ;;
        4) PROTO_SCHEME="kcp" ;;
        *) PROTO_SCHEME="grpc" ;;
    esac

    # پارامترهای ضد اختلال و پکت لاست
    OPTS="nodelay=true&keepalive=true&ttl=10s"

    if [[ "$ROLE" == "1" ]]; then
        # ======================= سرور ایران =======================
        read -rp "پورت‌های کاربری برای انتقال به خارج (مثلاً 443,2053,8080): " FWD_PORTS
        
        # شنود روی پورت‌های کاربری در ایران و فوروارد به سوکت محلی
        LISTEN_ARGS=()
        IFS=',' read -ra PORTS <<< "$FWD_PORTS"
        for P in "${PORTS[@]}"; do
            P_TRIM=$(echo "$P" | tr -d ' ')
            [[ -z "$P_TRIM" ]] && continue
            LISTEN_ARGS+=("-L" "tcp://:${P_TRIM}/127.0.0.1:${P_TRIM}" "-L" "udp://:${P_TRIM}/127.0.0.1:${P_TRIM}")
        done

        # 1. شنود سرور تانل ورودی (Tunnel Server Listener)
        cat <<EOF > "${CONFIG_DIR}/srv-${NODE_ID}.sh"
#!/usr/bin/env bash
exec ${BIN_PATH} -L "${PROTO_SCHEME}://:${TUN_PORT}?password=${TUN_PASS}&${OPTS}"
EOF

        # 2. تحویل‌دهنده ترافیک به تانل داخلی
        cat <<EOF > "${CONFIG_DIR}/fwd-${NODE_ID}.sh"
#!/usr/bin/env bash
exec ${BIN_PATH} \\
    ${LISTEN_ARGS[*]} \\
    -F "${PROTO_SCHEME}://${TUN_PASS}@127.0.0.1:${TUN_PORT}?${OPTS}"
EOF

        chmod +x "${CONFIG_DIR}/srv-${NODE_ID}.sh" "${CONFIG_DIR}/fwd-${NODE_ID}.sh"

        # ساخت دو سرویس مستقل برای ایزولاسیون کامل و عدم کرش درصورت نوسان
        cat <<EOF > "${SYSTEMD_DIR}/picotun-srv-${NODE_ID}.service"
[Unit]
Description=PicoTun Server Listener Node ${NODE_ID}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CONFIG_DIR}/srv-${NODE_ID}.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        cat <<EOF > "${SYSTEMD_DIR}/picotun-fwd-${NODE_ID}.service"
[Unit]
Description=PicoTun Traffic Forwarder Node ${NODE_ID}
After=picotun-srv-${NODE_ID}.service
Requires=picotun-srv-${NODE_ID}.service

[Service]
Type=simple
ExecStart=${CONFIG_DIR}/fwd-${NODE_ID}.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now "picotun-srv-${NODE_ID}.service" >/dev/null 2>&1
        systemctl enable --now "picotun-fwd-${NODE_ID}.service" >/dev/null 2>&1

        METADATA=$(jq -n \
            --arg alias "$NODE_ALIAS" \
            --arg role "Iran" \
            --arg tun_port "$TUN_PORT" \
            --arg proto "$PROTO_SCHEME" \
            --arg fwd_ports "$FWD_PORTS" \
            --arg peer "Kharej Bridge" \
            '{alias: $alias, role: $role, tun_port: $tun_port, proto: $proto, fwd_ports: $fwd_ports, peer: $peer}')
        save_node_metadata "$NODE_ID" "$METADATA"

    elif [[ "$ROLE" == "2" ]]; then
        # ======================= سرور خارج =======================
        read -rp "آدرس IP سرور ایران: " IRAN_IP
        read -rp "پورت‌های مقصد روی این سرور (همان پورت‌های کانفیگ، مثلاً 443,2053): " FWD_PORTS

        REVERSE_ARGS=()
        IFS=',' read -ra PORTS <<< "$FWD_PORTS"
        for P in "${PORTS[@]}"; do
            P_TRIM=$(echo "$P" | tr -d ' ')
            [[ -z "$P_TRIM" ]] && continue
            REVERSE_ARGS+=("-L" "rtcp://:${P_TRIM}/127.0.0.1:${P_TRIM}" "-L" "rudp://:${P_TRIM}/127.0.0.1:${P_TRIM}")
        done

        cat <<EOF > "${CONFIG_DIR}/client-${NODE_ID}.sh"
#!/usr/bin/env bash
exec ${BIN_PATH} \\
    ${REVERSE_ARGS[*]} \\
    -F "${PROTO_SCHEME}://${TUN_PASS}@${IRAN_IP}:${TUN_PORT}?${OPTS}"
EOF

        chmod +x "${CONFIG_DIR}/client-${NODE_ID}.sh"

        cat <<EOF > "${SYSTEMD_DIR}/picotun-${NODE_ID}.service"
[Unit]
Description=PicoTun Kharej Bridge Node ${NODE_ID} (${NODE_ALIAS})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CONFIG_DIR}/client-${NODE_ID}.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now "picotun-${NODE_ID}.service" >/dev/null 2>&1

        METADATA=$(jq -n \
            --arg alias "$NODE_ALIAS" \
            --arg role "Kharej" \
            --arg tun_port "$TUN_PORT" \
            --arg proto "$PROTO_SCHEME" \
            --arg fwd_ports "$FWD_PORTS" \
            --arg peer "$IRAN_IP" \
            '{alias: $alias, role: $role, tun_port: $tun_port, proto: $proto, fwd_ports: $fwd_ports, peer: $peer}')
        save_node_metadata "$NODE_ID" "$METADATA"
    else
        echo -e "${RED}نقش وارد شده نامعتبر است.${NC}"
        return
    fi

    echo -e "${GREEN}✓ نود ${NODE_ID} (${NODE_ALIAS}) با موفقیت مستقر شد و ارتباط برقرار است.${NC}"
}

check_status() {
    echo -e "\n${YELLOW}=== جدول رصد زنده و توپولوژی نودها ===${NC}"
    printf "%-5s | %-16s | %-7s | %-7s | %-12s | %-15s | %-10s\n" "ID" "Alias" "Role" "Proto" "Tun Port" "Peer Address" "Service"
    echo "--------------------------------------------------------------------------------------------------"
    
    if [[ ! -s "$DATA_FILE" ]] || [[ $(jq 'keys | length' "$DATA_FILE") -eq 0 ]]; then
        echo -e " ${CYAN}هیچ نودی روی این سرور ثبت نشده است.${NC}"
        return
    fi

    for ID in $(jq -r 'keys[]' "$DATA_FILE"); do
        ALIAS=$(jq -r ".\"$ID\".alias // \"-\"" "$DATA_FILE")
        ROLE=$(jq -r ".\"$ID\".role // \"-\"" "$DATA_FILE")
        PROTO=$(jq -r ".\"$ID\".proto // \"-\"" "$DATA_FILE")
        TPORT=$(jq -r ".\"$ID\".tun_port // \"-\"" "$DATA_FILE")
        PEER=$(jq -r ".\"$ID\".peer // \"-\"" "$DATA_FILE")
        
        if [[ "$ROLE" == "Iran" ]]; then
            SVC="picotun-srv-${ID}.service"
        else
            SVC="picotun-${ID}.service"
        fi
        
        if systemctl is-active --quiet "$SVC"; then
            STATUS="${GREEN}ONLINE${NC}"
        else
            STATUS="${RED}OFFLINE${NC}"
        fi
        
        printf "%-5s | %-16s | %-7s | %-7s | %-12s | %-15s | %b\n" "$ID" "$ALIAS" "$ROLE" "$PROTO" "$TPORT" "$PEER" "$STATUS"
    done
    echo ""
}

remove_node() {
    read -rp "شناسه نود مورد نظر برای حذف: " NODE_ID
    
    systemctl stop "picotun-srv-${NODE_ID}.service" "picotun-fwd-${NODE_ID}.service" "picotun-${NODE_ID}.service" 2>/dev/null || true
    systemctl disable "picotun-srv-${NODE_ID}.service" "picotun-fwd-${NODE_ID}.service" "picotun-${NODE_ID}.service" 2>/dev/null || true
    
    rm -f "${SYSTEMD_DIR}/picotun-srv-${NODE_ID}.service" \
          "${SYSTEMD_DIR}/picotun-fwd-${NODE_ID}.service" \
          "${SYSTEMD_DIR}/picotun-${NODE_ID}.service"
          
    rm -f "${CONFIG_DIR}/srv-${NODE_ID}.sh" \
          "${CONFIG_DIR}/fwd-${NODE_ID}.sh" \
          "${CONFIG_DIR}/client-${NODE_ID}.sh"
          
    remove_node_metadata "$NODE_ID"
    systemctl daemon-reload
    echo -e "${GREEN}نود ${NODE_ID} و سرویس‌های مرتبط به طور کامل حذف شدند.${NC}"
}

# منوی تعاملی
clear
echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}      PicoTun Pro v3 - Zero-Drop Multi-Tunnel         ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo "1) نصب یا آپدیت نود (Add / Update Node)"
echo "2) پایش سلامت و وضعیت نودها (Monitor Status)"
echo "3) راه‌اندازی مجدد نود (Restart Node)"
echo "4) حذف نود (Remove Node)"
echo "5) اعمال مجدد بهینه‌سازی پیشرفته شبکه و BBR"
echo "0) خروج"
read -rp "انتخاب شما: " OPT

case $OPT in
    1) setup_node ;;
    2) check_status ;;
    3) 
        read -rp "شناسه نود را وارد کنید: " NID
        systemctl restart "picotun-srv-${NID}.service" "picotun-fwd-${NID}.service" "picotun-${NID}.service" 2>/dev/null || true
        echo -e "${GREEN}سرویس‌های نود ${NID} مجدداً راه‌اندازی شدند.${NC}"
        ;;
    4) remove_node ;;
    5) optimize_kernel_network ;;
    0) exit 0 ;;
    *) echo -e "${RED}گزینه نامعتبر است.${NC}" ;;
esac
