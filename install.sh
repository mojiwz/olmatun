#!/usr/bin/env bash
# ==============================================================================
# PicoTun Pro v3.5 - Ultimate Low-Latency & Zero-Drop Relay
# Architecture: Multiplexed L4 Forwarding (Direct TCP/UDP over Relay)
# Language: English (Terminal Safe)
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
   echo -e "${RED}Error: This script requires root privileges. Please run with sudo or as root.${NC}"
   exit 1
fi

mkdir -p "$CONFIG_DIR"
[[ ! -f "$DATA_FILE" ]] && echo "{}" > "$DATA_FILE"

optimize_kernel_network() {
    echo -e "${CYAN}Applying Enterprise-grade Kernel Optimizations (BBR, FQ, Buffer Limits)...${NC}"
    
    # Load BBR module safely
    modprobe tcp_bbr 2>/dev/null || true
    
    cat <<EOF > /etc/sysctl.d/99-picotun-ultimate.conf
# Advanced Queue Discipline & Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Essential IP Forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Massive Socket Buffers (Prevents drops during 1000+ user traffic peaks)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.netdev_max_backlog = 300000
net.core.somaxconn = 65535

# TCP Memory Auto-Tuning Limits (Pages)
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Zero-Drop & Fast Recovery TCP Options
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1

# MTU and TCP Keep-alive Tuning (Prevents frozen connections)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_slow_start_after_idle = 0

# Maximum System File Descriptors
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
EOF

    sysctl --system >/dev/null 2>&1
    
    # Increase system limits for concurrent connections
    cat <<EOF > /etc/security/limits.d/99-picotun.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    echo -e "${GREEN}Kernel optimizations applied successfully!${NC}"
}

install_core() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${CYAN}Downloading GOST v3 Core...${NC}"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar jq iproute2 iptables >/dev/null 2>&1
        
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_amd64.tar.gz"
        elif [[ "$ARCH" == "aarch64" ]]; then
            URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_arm64.tar.gz"
        else
            echo -e "${RED}Error: Unsupported CPU architecture.${NC}"
            exit 1
        fi
        
        wget -qO /tmp/gost.tar.gz "$URL"
        tar -xzf /tmp/gost.tar.gz -C /tmp/
        mv /tmp/gost "$BIN_PATH"
        chmod +x "$BIN_PATH"
        rm -f /tmp/gost.tar.gz
        echo -e "${GREEN}Core engine installed successfully!${NC}"
    fi
}

save_metadata() {
    local id="$1"
    local json_data="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg id "$id" --argjson data "$json_data" '.[$id] = $data' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
}

remove_metadata() {
    local id="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg id "$id" 'del(.[$id])' "$DATA_FILE" > "$tmp" && mv "$tmp" "$DATA_FILE"
}

setup_node() {
    install_core
    optimize_kernel_network
    
    echo -e "\n${YELLOW}=== Node Configuration Wizard ===${NC}"
    echo "1) Kharej Server (Endpoint - Receives tunnel & provides internet)"
    echo "2) Iran Server (Relay - Listens to users & forwards to Kharej)"
    read -rp "Select Server Role [1 or 2]: " ROLE
    
    read -rp "Enter Node ID (Number 1-250): " NODE_ID
    if ! [[ "$NODE_ID" =~ ^[0-9]+$ ]] || [ "$NODE_ID" -lt 1 ] || [ "$NODE_ID" -gt 250 ]; then
        echo -e "${RED}Invalid Node ID. Must be a number between 1 and 250.${NC}"
        return
    fi

    read -rp "Enter Node Alias (e.g., Kharej-Hetzner): " NODE_ALIAS
    read -rp "Enter secure Tunnel Port (Must be identical on both servers, e.g., 8443): " TUN_PORT
    read -rp "Enter strong Tunnel Password: " TUN_PASS
    
    echo -e "\nSelect Encrypted Multiplexing Protocol:"
    echo -e "1) ${BOLD}Relay + gRPC${NC} (Best for stability, handles packet drops brilliantly)"
    echo -e "2) ${BOLD}Relay + WSS${NC}  (WebSocket + TLS, great for extreme DPI filtering)"
    echo -e "3) ${BOLD}Relay + TLS${NC}  (Direct TLS stream, lowest CPU overhead)"
    read -rp "Select Protocol [1-3]: " PROTO_CHOICE

    case $PROTO_CHOICE in
        1) SCHEME="relay+grpc" ;;
        2) SCHEME="relay+wss" ;;
        3) SCHEME="relay+tls" ;;
        *) SCHEME="relay+grpc" ;;
    esac

    # Tuning options applied directly to the tunnel
    GOST_OPTS="nodelay=true&keepalive=true"

    if [[ "$ROLE" == "1" ]]; then
        # ================= KHAREJ (ENDPOINT) =================
        echo -e "${CYAN}Configuring Kharej Server...${NC}"
        
        cat <<EOF > "${CONFIG_DIR}/run-${NODE_ID}.sh"
#!/usr/bin/env bash
# Kharej simply listens for the multiplexed tunnel connection
exec ${BIN_PATH} -L "${SCHEME}://picotun:${TUN_PASS}@:${TUN_PORT}?${GOST_OPTS}"
EOF
        chmod +x "${CONFIG_DIR}/run-${NODE_ID}.sh"

        cat <<EOF > "${SYSTEMD_DIR}/picotun-${NODE_ID}.service"
[Unit]
Description=PicoTun Endpoint Node ${NODE_ID} (${NODE_ALIAS})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CONFIG_DIR}/run-${NODE_ID}.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable --now "picotun-${NODE_ID}.service" >/dev/null 2>&1

        META=$(jq -n \
            --arg alias "$NODE_ALIAS" \
            --arg role "Kharej" \
            --arg proto "$SCHEME" \
            --arg tport "$TUN_PORT" \
            --arg fports "N/A" \
            --arg peer "Waiting for Iran" \
            '{alias: $alias, role: $role, proto: $proto, tun_port: $tport, fwd_ports: $fports, peer: $peer}')
        save_metadata "$NODE_ID" "$META"

    elif [[ "$ROLE" == "2" ]]; then
        # ================= IRAN (RELAY) =================
        echo -e "${CYAN}Configuring Iran Server...${NC}"
        read -rp "Enter Kharej Server IP Address: " KHAREJ_IP
        read -rp "Enter User Ports to forward to Kharej (comma-separated, e.g., 443,2053,8080): " FWD_PORTS
        
        # Build listener string for TCP and UDP
        LISTENERS=""
        IFS=',' read -ra PORTS <<< "$FWD_PORTS"
        for P in "${PORTS[@]}"; do
            P_TRIM=$(echo "$P" | tr -d ' ')
            [[ -z "$P_TRIM" ]] && continue
            LISTENERS="${LISTENERS} -L tcp://:${P_TRIM}/127.0.0.1:${P_TRIM} -L udp://:${P_TRIM}/127.0.0.1:${P_TRIM}"
        done

        cat <<EOF > "${CONFIG_DIR}/run-${NODE_ID}.sh"
#!/usr/bin/env bash
# Iran listens on user ports and forwards ALL traffic through the multiplexed tunnel
exec ${BIN_PATH} \\
    ${LISTENERS} \\
    -F "${SCHEME}://picotun:${TUN_PASS}@${KHAREJ_IP}:${TUN_PORT}?${GOST_OPTS}"
EOF
        chmod +x "${CONFIG_DIR}/run-${NODE_ID}.sh"

        cat <<EOF > "${SYSTEMD_DIR}/picotun-${NODE_ID}.service"
[Unit]
Description=PicoTun Relay Node ${NODE_ID} (${NODE_ALIAS})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CONFIG_DIR}/run-${NODE_ID}.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable --now "picotun-${NODE_ID}.service" >/dev/null 2>&1

        META=$(jq -n \
            --arg alias "$NODE_ALIAS" \
            --arg role "Iran" \
            --arg proto "$SCHEME" \
            --arg tport "$TUN_PORT" \
            --arg fports "$FWD_PORTS" \
            --arg peer "$KHAREJ_IP" \
            '{alias: $alias, role: $role, proto: $proto, tun_port: $tport, fwd_ports: $fports, peer: $peer}')
        save_metadata "$NODE_ID" "$META"

    else
        echo -e "${RED}Invalid role selected.${NC}"
        return
    fi

    echo -e "${GREEN}✓ Node ${NODE_ID} (${NODE_ALIAS}) successfully configured and started!${NC}"
}

check_status() {
    echo -e "\n${YELLOW}=== Active Nodes Topology ===${NC}"
    printf "%-4s | %-15s | %-7s | %-12s | %-9s | %-15s | %-7s\n" "ID" "Alias" "Role" "Protocol" "Tun Port" "Peer IP" "Status"
    echo "----------------------------------------------------------------------------------------"
    
    if [[ ! -s "$DATA_FILE" ]] || [[ $(jq 'keys | length' "$DATA_FILE") -eq 0 ]]; then
        echo -e " ${CYAN}No nodes are currently registered.${NC}"
        return
    fi

    for ID in $(jq -r 'keys[]' "$DATA_FILE"); do
        ALIAS=$(jq -r ".\"$ID\".alias // \"-\"" "$DATA_FILE")
        ROLE=$(jq -r ".\"$ID\".role // \"-\"" "$DATA_FILE")
        PROTO=$(jq -r ".\"$ID\".proto // \"-\"" "$DATA_FILE")
        TPORT=$(jq -r ".\"$ID\".tun_port // \"-\"" "$DATA_FILE")
        PEER=$(jq -r ".\"$ID\".peer // \"-\"" "$DATA_FILE")
        
        SVC="picotun-${ID}.service"
        
        if systemctl is-active --quiet "$SVC"; then
            STATUS="${GREEN}ONLINE${NC}"
        else
            STATUS="${RED}OFFLINE${NC}"
        fi
        
        printf "%-4s | %-15s | %-7s | %-12s | %-9s | %-15s | %b\n" "$ID" "$ALIAS" "$ROLE" "$PROTO" "$TPORT" "$PEER" "$STATUS"
    done
    echo ""
}

remove_node() {
    read -rp "Enter Node ID to remove: " NODE_ID
    SVC="picotun-${NODE_ID}.service"
    
    if systemctl list-unit-files | grep -q "$SVC"; then
        systemctl stop "$SVC" 2>/dev/null || true
        systemctl disable "$SVC" >/dev/null 2>&1 || true
        rm -f "${SYSTEMD_DIR}/${SVC}"
        rm -f "${CONFIG_DIR}/run-${NODE_ID}.sh"
        remove_metadata "$NODE_ID"
        systemctl daemon-reload
        echo -e "${GREEN}Node ${NODE_ID} successfully removed and cleaned up.${NC}"
    else
        echo -e "${RED}Node ID ${NODE_ID} not found.${NC}"
    fi
}

# ----------------- MAIN MENU -----------------
while true; do
    echo -e "\n${CYAN}======================================================${NC}"
    echo -e "${GREEN}      PicoTun Pro v3.5 - Zero-Drop Network Tool       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo "1) Setup or Update a Node"
    echo "2) Check Nodes Status & Topology"
    echo "3) Restart a Node"
    echo "4) Remove a Node"
    echo "5) Re-apply Kernel & Network Optimizations"
    echo "0) Exit"
    read -rp "Select an option [0-5]: " OPT

    case $OPT in
        1) setup_node ;;
        2) check_status ;;
        3) 
            read -rp "Enter Node ID to restart: " NID
            systemctl restart "picotun-${NID}.service" 2>/dev/null && \
            echo -e "${GREEN}Node ${NID} restarted successfully.${NC}" || \
            echo -e "${RED}Failed to restart Node ${NID}.${NC}"
            ;;
        4) remove_node ;;
        5) optimize_kernel_network ;;
        0) echo -e "${CYAN}Exiting...${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid selection. Please try again.${NC}" ;;
    esac
done
