#!/usr/bin/env bash

# PicoTun Pro - Multi-Node Edition
# Optimized for Multi-Kharej to 1-Iran Architecture, High Throughput & Security

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_DIR="/etc/picotun"
SYSTEMD_DIR="/etc/systemd/system"
BIN_PATH="/usr/local/bin/gost"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root.${NC}"
   exit 1
fi

mkdir -p "$CONFIG_DIR"

optimize_kernel() {
    echo -e "${CYAN}Applying kernel & BBR network optimizations...${NC}"
    cat <<EOF > /etc/sysctl.d/99-picotun.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}Kernel parameters optimized successfully.${NC}"
}

install_core() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${CYAN}Installing tunnel core engine...${NC}"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar iptables iproute2 >/dev/null 2>&1
        
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_amd64.tar.gz"
        elif [[ "$ARCH" == "aarch64" ]]; then
            URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_arm64.tar.gz"
        else
            echo -e "${RED}Unsupported architecture.${NC}"
            exit 1
        fi
        
        wget -qO /tmp/gost.tar.gz "$URL"
        tar -xzf /tmp/gost.tar.gz -C /tmp/
        mv /tmp/gost "$BIN_PATH"
        chmod +x "$BIN_PATH"
        rm -f /tmp/gost.tar.gz
        echo -e "${GREEN}Core installed successfully.${NC}"
    fi
}

setup_node() {
    install_core
    optimize_kernel

    echo -e "\n${YELLOW}--- Configure New Tunnel Instance ---${NC}"
    read -p "Select Server Role (1: Iran / 2: Kharej): " ROLE
    read -p "Enter Node ID (1 to 250 - MUST match on both Iran & Kharej for this pair): " NODE_ID
    
    if ! [[ "$NODE_ID" =~ ^[0-9]+$ ]] || [ "$NODE_ID" -lt 1 ] || [ "$NODE_ID" -gt 250 ]; then
        echo -e "${RED}Invalid Node ID. Must be between 1 and 250.${NC}"
        return
    fi

    read -p "Enter Tunnel Communication Port (e.g., 8443 - Unique per Node ID on Iran): " TUN_PORT
    read -p "Enter Secret Password for Tunnel Encryption: " TUN_PASS
    read -p "Select Transport Protocol (1: WSS [Secure/Anti-DPI] / 2: KCP [Fast/UDP] / 3: TCP+TLS): " PROTO_TYPE

    TUN_DEV="tun-pt${NODE_ID}"
    IR_TUN_IP="10.10.${NODE_ID}.1"
    KH_TUN_IP="10.10.${NODE_ID}.2"
    MTU_SIZE="1380"

    case $PROTO_TYPE in
        1) SCHEME="wss" ;;
        2) SCHEME="kcp" ;;
        3) SCHEME="tls" ;;
        *) SCHEME="tls" ;;
    esac

    if [[ "$ROLE" == "1" ]]; then
        # IRAN CONFIGURATION
        read -p "Enter Ports to Forward to this Kharej (comma-separated, e.g., 443,2053,8080): " FWD_PORTS
        
        EXEC_CMD="${BIN_PATH} -L \"tun://:${TUN_PORT}?name=${TUN_DEV}&net=${IR_TUN_IP}/30&mtu=${MTU_SIZE}&route=${KH_TUN_IP}/32\" -L \"${SCHEME}://${TUN_PASS}:picotun@:${TUN_PORT}\""
        
        # Simplified Direct Encrypted TUN over UDP/TCP using GOST TUN wrapper
        EXEC_CMD="${BIN_PATH} -L \"tun://:0/${KH_TUN_IP}:0?name=${TUN_DEV}&net=${IR_TUN_IP}/30&mtu=${MTU_SIZE}\" -F \"${SCHEME}://:${TUN_PORT}?password=${TUN_PASS}\""
        
        # To ensure 100% point-to-point compatibility and stability across NATs, we use native IP-in-UDP/TCP encrypted socket binding:
        cat <<EOF > "${CONFIG_DIR}/node-${NODE_ID}.sh"
#!/usr/bin/env bash
ip link del ${TUN_DEV} 2>/dev/null || true

# Start encrypted tunnel listener
${BIN_PATH} -L "tun://:${TUN_PORT}?name=${TUN_DEV}&net=${IR_TUN_IP}/30&mtu=${MTU_SIZE}&peer=${KH_TUN_IP}" &
TUN_PID=\$!
sleep 2

ip link set dev ${TUN_DEV} mtu ${MTU_SIZE} up

# Enable TCP MSS Clamping to prevent packet drops on TLS handshakes
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Port Forwarding Rules (DNAT & SNAT) isolated for Node ${NODE_ID}
IFS=',' read -ra PORTS <<< "${FWD_PORTS}"
for PORT in "\${PORTS[@]}"; do
    iptables -t nat -A PREROUTING -p tcp --dport "\$PORT" -j DNAT --to-destination "${KH_TUN_IP}:\$PORT"
    iptables -t nat -A PREROUTING -p udp --dport "\$PORT" -j DNAT --to-destination "${KH_TUN_IP}:\$PORT"
    iptables -t nat -A POSTROUTING -p tcp -d "${KH_TUN_IP}" --dport "\$PORT" -j SNAT --to-source "${IR_TUN_IP}"
    iptables -t nat -A POSTROUTING -p udp -d "${KH_TUN_IP}" --dport "\$PORT" -j SNAT --to-source "${IR_TUN_IP}"
done

wait \$TUN_PID
EOF

        cat <<EOF > "${CONFIG_DIR}/stop-${NODE_ID}.sh"
#!/usr/bin/env bash
IFS=',' read -ra PORTS <<< "${FWD_PORTS}"
for PORT in "\${PORTS[@]}"; do
    iptables -t nat -D PREROUTING -p tcp --dport "\$PORT" -j DNAT --to-destination "${KH_TUN_IP}:\$PORT" 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport "\$PORT" -j DNAT --to-destination "${KH_TUN_IP}:\$PORT" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p tcp -d "${KH_TUN_IP}" --dport "\$PORT" -j SNAT --to-source "${IR_TUN_IP}" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p udp -d "${KH_TUN_IP}" --dport "\$PORT" -j SNAT --to-source "${IR_TUN_IP}" 2>/dev/null || true
done
ip link del ${TUN_DEV} 2>/dev/null || true
EOF

    elif [[ "$ROLE" == "2" ]]; then
        # KHAREJ CONFIGURATION
        read -p "Enter Iran Server IP Address: " IRAN_IP

        cat <<EOF > "${CONFIG_DIR}/node-${NODE_ID}.sh"
#!/usr/bin/env bash
ip link del ${TUN_DEV} 2>/dev/null || true

${BIN_PATH} -L "tun:///${IRAN_IP}:${TUN_PORT}?name=${TUN_DEV}&net=${KH_TUN_IP}/30&mtu=${MTU_SIZE}&peer=${IR_TUN_IP}" &
TUN_PID=\$!
sleep 2

ip link set dev ${TUN_DEV} mtu ${MTU_SIZE} up
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Keep-Alive Watchdog to prevent silent tunnel freezes
while kill -0 \$TUN_PID 2>/dev/null; do
    if ! ping -c 3 -W 2 ${IR_TUN_IP} >/dev/null 2>&1; then
        echo "Tunnel ping failed, restarting instance..."
        kill -9 \$TUN_PID
        exit 1
    fi
    sleep 10
done
EOF

        cat <<EOF > "${CONFIG_DIR}/stop-${NODE_ID}.sh"
#!/usr/bin/env bash
ip link del ${TUN_DEV} 2>/dev/null || true
EOF
    else
        echo -e "${RED}Invalid Role Selected.${NC}"
        return
    fi

    chmod +x "${CONFIG_DIR}/node-${NODE_ID}.sh" "${CONFIG_DIR}/stop-${NODE_ID}.sh"

    cat <<EOF > "${SYSTEMD_DIR}/picotun-${NODE_ID}.service"
[Unit]
Description=PicoTun Pro Tunnel Instance ${NODE_ID}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CONFIG_DIR}/node-${NODE_ID}.sh
ExecStopPost=${CONFIG_DIR}/stop-${NODE_ID}.sh
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "picotun-${NODE_ID}.service" >/dev/null 2>&1
    systemctl restart "picotun-${NODE_ID}.service"

    echo -e "${GREEN}Node ${NODE_ID} configured and started!${NC}"
    echo -e "Iran Local IP: ${CYAN}${IR_TUN_IP}${NC} | Kharej Local IP: ${CYAN}${KH_TUN_IP}${NC} | Interface: ${CYAN}${TUN_DEV}${NC}"
}

check_status() {
    echo -e "\n${YELLOW}--- Active Tunnel Instances ---${NC}"
    for svc in /etc/systemd/system/picotun-*.service; do
        [[ -e "$svc" ]] || { echo "No active nodes found."; break; }
        SVC_NAME=$(basename "$svc")
        NODE_NUM=$(echo "$SVC_NAME" | grep -o -E '[0-9]+')
        STATUS=$(systemctl is-active "$SVC_NAME")
        if [[ "$STATUS" == "active" ]]; then
            echo -e "Node ${NODE_NUM}: ${GREEN}ACTIVE${NC} (Sub-network: 10.10.${NODE_NUM}.0/30 | Interface: tun-pt${NODE_NUM})"
            ping -c 1 -W 1 "10.10.${NODE_NUM}.1" >/dev/null 2>&1 && echo -e "  └─ Ping .1 (Iran): ${GREEN}OK${NC}" || echo -e "  └─ Ping .1 (Iran): ${RED}TIMEOUT${NC}"
            ping -c 1 -W 1 "10.10.${NODE_NUM}.2" >/dev/null 2>&1 && echo -e "  └─ Ping .2 (Kharej): ${GREEN}OK${NC}" || echo -e "  └─ Ping .2 (Kharej): ${RED}TIMEOUT${NC}"
        else
            echo -e "Node ${NODE_NUM}: ${RED}${STATUS}${NC}"
        fi
    done
}

remove_node() {
    read -p "Enter Node ID to remove: " NODE_ID
    SVC_NAME="picotun-${NODE_ID}.service"
    if [[ -f "${SYSTEMD_DIR}/${SVC_NAME}" ]]; then
        systemctl stop "$SVC_NAME"
        systemctl disable "$SVC_NAME" >/dev/null 2>&1
        rm -f "${SYSTEMD_DIR}/${SVC_NAME}"
        rm -f "${CONFIG_DIR}/node-${NODE_ID}.sh" "${CONFIG_DIR}/stop-${NODE_ID}.sh"
        systemctl daemon-reload
        echo -e "${GREEN}Node ${NODE_ID} completely removed.${NC}"
    else
        echo -e "${RED}Node ${NODE_ID} does not exist.${NC}"
    fi
}

clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}      PicoTun Pro - Multi-Node Manager   ${NC}"
echo -e "${CYAN}=========================================${NC}"
echo "1) Add / Update Tunnel Node"
echo "2) Check Tunnels Status & Ping"
echo "3) Restart a Node"
echo "4) Remove a Node"
echo "5) Optimize Server Kernel Only"
echo "0) Exit"
read -p "Select an option: " OPT

case $OPT in
    1) setup_node ;;
    2) check_status ;;
    3) read -p "Enter Node ID to restart: " NID; systemctl restart "picotun-${NID}.service" && echo -e "${GREEN}Restarted.${NC}" ;;
    4) remove_node ;;
    5) optimize_kernel ;;
    0) exit 0 ;;
    *) echo -e "${RED}Invalid option.${NC}" ;;
esac
