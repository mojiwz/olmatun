#!/usr/bin/env bash
# PicoTun Pro - Smart L4 Relay Edition
# Optimized for Multi-Kharej to 1-Iran Architecture, High Throughput, Low CPU & Smart Tracking
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
net.core.somaxconn = 65535
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
        echo -e "${CYAN}Installing Tunnel Engine (Gost v3.0.0)...${NC}"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar jq iproute2 >/dev/null 2>&1
        
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_amd64.tar.gz"
        elif [[ "$ARCH" == "aarch64" ]]; then
            URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_arm64.tar.gz"
        else
            echo -e "${RED}Unsupported architecture.${NC}"
            exit 1
        fi
        
        wget -qO /tmp/gost.tar.gz "$URL"
        tar -xzf /tmp/gost.tar.gz -C /tmp/
        mv /tmp/gost "$BIN_PATH"
        chmod +x "$BIN_PATH"
        rm -f /tmp/gost.tar.gz
        echo -e "${GREEN}Core engine installed successfully.${NC}"
    fi
}

setup_node() {
    install_core
    optimize_kernel
    
    echo -e "\n${YELLOW}--- Configure New Smart Tunnel Instance ---${NC}"
    read -p "Select Server Role (1: Iran / 2: Kharej): " ROLE
    read -p "Enter Node ID (1 to 250 - MUST match on both servers): " NODE_ID
    
    if ! [[ "$NODE_ID" =~ ^[0-9]+$ ]] || [ "$NODE_ID" -lt 1 ] || [ "$NODE_ID" -gt 250 ]; then
        echo -e "${RED}Invalid Node ID.${NC}"
        return
    fi
    
    read -p "Enter Tunnel Communication Port (e.g., 8443): " TUN_PORT
    read -p "Enter Secret Password for Encryption: " TUN_PASS
    echo "Select Transport Protocol:"
    echo " 1) Multiplexed WebSocket (mws) - [Best for Iran, Bypass DPI, Low CPU]"
    echo " 2) gRPC - [High Stability & CDN Routing]"
    echo " 3) TLS - [Standard Secure, Very Fast]"
    read -p "Select Protocol (1-3): " PROTO_TYPE
    
    case $PROTO_TYPE in
        1) SCHEME="relay+mws" ;;
        2) SCHEME="relay+grpc" ;;
        3) SCHEME="relay+tls" ;;
        *) SCHEME="relay+mws" ;;
    esac

    # Variables for tracking
    CONF_FILE="${CONFIG_DIR}/node-${NODE_ID}.conf"
    
    if [[ "$ROLE" == "1" ]]; then
        # IRAN: Client (Forwarder)
        read -p "Enter Kharej Server IP Address: " KHAREJ_IP
        read -p "Enter Ports to Forward (comma-separated, e.g., 80,443,2053): " FWD_PORTS
        
        # Build L4 Listeners dynamically
        LISTENERS=""
        IFS=',' read -ra PORTS <<< "${FWD_PORTS}"
        for PORT in "${PORTS[@]}"; do
            # Forward Iran local ports directly to Kharej localhost ports
            LISTENERS="${LISTENERS} -L tcp://:${PORT}/127.0.0.1:${PORT} -L udp://:${PORT}/127.0.0.1:${PORT}"
        done
        
        EXEC_CMD="${BIN_PATH} ${LISTENERS} -F \"${SCHEME}://picotun:${TUN_PASS}@${KHAREJ_IP}:${TUN_PORT}\""
        
        # Save Smart Tracking Metadata
        echo "ROLE=IRAN" > "$CONF_FILE"
        echo "TARGET_IP=${KHAREJ_IP}" >> "$CONF_FILE"
        echo "PORTS=${FWD_PORTS}" >> "$CONF_FILE"
        echo "PROTOCOL=${SCHEME}" >> "$CONF_FILE"
        echo "TUN_PORT=${TUN_PORT}" >> "$CONF_FILE"
        
    elif [[ "$ROLE" == "2" ]]; then
        # KHAREJ: Server (Receiver)
        EXEC_CMD="${BIN_PATH} -L \"${SCHEME}://picotun:${TUN_PASS}@:${TUN_PORT}\""
        
        # Save Smart Tracking Metadata
        echo "ROLE=KHAREJ" > "$CONF_FILE"
        echo "TARGET_IP=Listening" >> "$CONF_FILE"
        echo "PORTS=All configured from Iran" >> "$CONF_FILE"
        echo "PROTOCOL=${SCHEME}" >> "$CONF_FILE"
        echo "TUN_PORT=${TUN_PORT}" >> "$CONF_FILE"
    else
        echo -e "${RED}Invalid Role.${NC}"
        return
    fi
    
    # Create the run script
    cat <<EOF > "${CONFIG_DIR}/run-${NODE_ID}.sh"
#!/usr/bin/env bash
${EXEC_CMD}
EOF
    chmod +x "${CONFIG_DIR}/run-${NODE_ID}.sh"

    # Create Systemd Service
    cat <<EOF > "${SYSTEMD_DIR}/picotun-${NODE_ID}.service"
[Unit]
Description=PicoTun Pro Node ${NODE_ID}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CONFIG_DIR}/run-${NODE_ID}.sh
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "picotun-${NODE_ID}.service" >/dev/null 2>&1
    systemctl restart "picotun-${NODE_ID}.service"
    
    echo -e "\n${GREEN}✔ Node ${NODE_ID} successfully configured and started!${NC}"
    echo -e "Protocol: ${CYAN}${SCHEME}${NC} | Tunnel Port: ${CYAN}${TUN_PORT}${NC}"
}

check_status() {
    echo -e "\n${CYAN}=========================================${NC}"
    echo -e "${YELLOW}   Active Tunnel Topology & Status       ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    
    FOUND=0
    for svc in /etc/systemd/system/picotun-*.service; do
        [[ -e "$svc" ]] || continue
        FOUND=1
        SVC_NAME=$(basename "$svc")
        NODE_NUM=$(echo "$SVC_NAME" | grep -o -E '[0-9]+')
        STATUS=$(systemctl is-active "$SVC_NAME")
        CONF_FILE="${CONFIG_DIR}/node-${NODE_NUM}.conf"
        
        if [[ "$STATUS" == "active" ]]; then
            STAT_COLOR="${GREEN}ACTIVE${NC}"
        else
            STAT_COLOR="${RED}${STATUS}${NC}"
        fi
        
        echo -e "📦 ${YELLOW}Node ${NODE_NUM}${NC} [Status: ${STAT_COLOR}]"
        
        if [[ -f "$CONF_FILE" ]]; then
            source "$CONF_FILE"
            if [[ "$ROLE" == "IRAN" ]]; then
                echo -e "   ├─ Role:     ${CYAN}Iran (Forwarder)${NC}"
                echo -e "   ├─ Routing:  Local Ports [${GREEN}${PORTS}${NC}] ➔ Target IP [${CYAN}${TARGET_IP}${NC}]"
                echo -e "   └─ Tunnel:   via ${PROTOCOL} on port ${TUN_PORT}"
            elif [[ "$ROLE" == "KHAREJ" ]]; then
                echo -e "   ├─ Role:     ${CYAN}Kharej (Receiver)${NC}"
                echo -e "   └─ Tunnel:   Listening on port ${TUN_PORT} via ${PROTOCOL}"
            fi
        else
            echo -e "   └─ ${RED}Metadata not found (Old version node?)${NC}"
        fi
        echo ""
    done
    
    if [[ $FOUND -eq 0 ]]; then
        echo -e "${RED}No active nodes found.${NC}"
    fi
}

remove_node() {
    read -p "Enter Node ID to remove: " NODE_ID
    SVC_NAME="picotun-${NODE_ID}.service"
    
    if [[ -f "${SYSTEMD_DIR}/${SVC_NAME}" ]]; then
        systemctl stop "$SVC_NAME" 2>/dev/null || true
        systemctl disable "$SVC_NAME" >/dev/null 2>&1
        rm -f "${SYSTEMD_DIR}/${SVC_NAME}"
        rm -f "${CONFIG_DIR}/run-${NODE_ID}.sh"
        rm -f "${CONFIG_DIR}/node-${NODE_ID}.conf"
        systemctl daemon-reload
        echo -e "${GREEN}✔ Node ${NODE_ID} completely removed.${NC}"
    else
        echo -e "${RED}Node ${NODE_ID} does not exist.${NC}"
    fi
}

clear
while true; do
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${GREEN}  PicoTun Pro - Smart L4 Relay Manager   ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo "1) Add / Update Tunnel Node"
    echo "2) Topology, Status & Routing info"
    echo "3) Restart a Node"
    echo "4) Remove a Node"
    echo "5) Optimize Server Kernel Only"
    echo "0) Exit"
    read -p "Select an option: " OPT
    
    case $OPT in
        1) setup_node ;;
        2) check_status ;;
        3) 
           read -p "Enter Node ID to restart: " NID
           if systemctl restart "picotun-${NID}.service" 2>/dev/null; then
               echo -e "${GREEN}Node ${NID} restarted.${NC}"
           else
               echo -e "${RED}Failed to restart Node ${NID} (Does it exist?).${NC}"
           fi
           ;;
        4) remove_node ;;
        5) optimize_kernel ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
    echo ""
done
