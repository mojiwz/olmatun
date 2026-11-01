#!/usr/bin/env bash
# PicoTun Pro - Multi-Node Edition (Optimized v2)
# Optimized for Multi-Kharej to 1-Iran Architecture, Low CPU & Traffic Overhead
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
CONFIG_DIR="/etc/picotun"
SYSTEMD_DIR="/etc/systemd/system"
BIN_PATH="/usr/local/bin/gost"
STATE_DIR="/var/lib/picotun"
mkdir -p "$CONFIG_DIR" "$STATE_DIR"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root.${NC}"
   exit 1
fi

# ---------- Kernel & Network Optimization (CPU Friendly) ----------
optimize_kernel() {
    echo -e "${CYAN}Applying kernel & network optimizations (BBR + fq)...${NC}"
    cat <<'EOF' > /etc/sysctl.d/99-picotun.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}Kernel parameters optimized (fq + BBR, reduced buffers).${NC}"
}

# ---------- Core Installation ----------
install_core() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${CYAN}Installing tunnel core engine...${NC}"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar iptables iproute2 >/dev/null 2>&1
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_amd64.tar.gz" ;;
            aarch64) URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_arm64.tar.gz" ;;
            *)       echo -e "${RED}Unsupported architecture.${NC}"; exit 1 ;;
        esac
        wget -qO /tmp/gost.tar.gz "$URL"
        tar -xzf /tmp/gost.tar.gz -C /tmp/
        mv /tmp/gost "$BIN_PATH" && chmod +x "$BIN_PATH"
        rm -f /tmp/gost.tar.gz
        echo -e "${GREEN}Core installed successfully.${NC}"
    fi
}

# ---------- Setup a New Node ----------
setup_node() {
    install_core; optimize_kernel
    echo -e "\n${YELLOW}--- Configure New Tunnel Instance ---${NC}"
    read -p "Select Server Role (1: Iran / 2: Kharej): " ROLE
    read -p "Enter Node ID (1-250, must match on both sides): " NODE_ID

    if ! [[ "$NODE_ID" =~ ^[0-9]+$ ]] || [ "$NODE_ID" -lt 1 ] || [ "$NODE_ID" -gt 250 ]; then
        echo -e "${RED}Invalid Node ID. Must be between 1 and 250.${NC}"; return
    fi

    read -p "Enter Tunnel Communication Port (e.g., 8443, unique per node on Iran): " TUN_PORT
    read -s -p "Enter Secret Password for Tunnel Encryption: " TUN_PASS; echo
    read -p "Select Transport Protocol (1: MWSS [Secure/Anti-DPI] / 2: KCP [Fast/UDP] / 3: MTLS): " PROTO_TYPE

    # Optimized defaults
    TUN_DEV="tun-pt${NODE_ID}"
    IR_TUN_IP="10.10.${NODE_ID}.1"
    KH_TUN_IP="10.10.${NODE_ID}.2"
    MTU_SIZE="1360"   # Reduced from 1380 to avoid fragmentation

    case $PROTO_TYPE in
        1) SCHEME="mwss" ;;   # Multiplexed WSS -> fewer TLS handshakes, less CPU
        2) SCHEME="kcp"  ;;
        3) SCHEME="mtls" ;;   # Multiplexed TLS
        *) SCHEME="mtls" ;;
    esac

    # KCP-specific tuning (lower bandwidth usage)
    KCP_EXTRA=""
    if [[ "$SCHEME" == "kcp" ]]; then
        # Normal mode is more bandwidth-friendly than fast
        KCP_EXTRA='&mode=normal&sndwnd=512&rcvwnd=512'
    fi

    STATE_FILE="${STATE_DIR}/node-${NODE_ID}.env"
    PORTS=""

    if [[ "$ROLE" == "1" ]]; then
        # ===== IRAN CONFIGURATION =====
        read -p "Enter Ports to Forward to this Kharej (comma-separated, e.g., 443,2053,8080): " FWD_PORTS
        PORTS="$FWD_PORTS"

        # Save state for status display
        cat <<EOF > "$STATE_FILE"
ROLE=iran
NODE_ID=${NODE_ID}
TUN_DEV=${TUN_DEV}
IR_TUN_IP=${IR_TUN_IP}
KH_TUN_IP=${KH_TUN_IP}
TUN_PORT=${TUN_PORT}
SCHEME=${SCHEME}
FWD_PORTS=${FWD_PORTS}
EOF

        cat <<EOF > "${CONFIG_DIR}/node-${NODE_ID}.sh"
#!/usr/bin/env bash
set -e
ip link del ${TUN_DEV} 2>/dev/null || true

# Start tunnel (multiplexed transport reduces CPU from repeated TLS handshakes)
${BIN_PATH} -L "tun://:${TUN_PORT}?name=${TUN_DEV}&net=${IR_TUN_IP}/30&mtu=${MTU_SIZE}&peer=${KH_TUN_IP}${KCP_EXTRA}" &
TUN_PID=\$!
sleep 2
ip link set dev ${TUN_DEV} mtu ${MTU_SIZE} up

# MSS clamping once, outside the loop
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Port-forwarding rules using a dedicated chain (cleaner, easier to remove)
CHAIN="PICOTUN_${NODE_ID}"
iptables -t nat -N "\$CHAIN" 2>/dev/null || true
iptables -t nat -F "\$CHAIN"

IFS=',' read -ra PORT_ARRAY <<< "${FWD_PORTS}"
for PORT in "\${PORT_ARRAY[@]}"; do
    iptables -t nat -A "\$CHAIN" -p tcp --dport "\$PORT" -m comment --comment "PicoTun-N${NODE_ID}" -j DNAT --to-destination "${KH_TUN_IP}:\$PORT"
    iptables -t nat -A "\$CHAIN" -p udp --dport "\$PORT" -m comment --comment "PicoTun-N${NODE_ID}" -j DNAT --to-destination "${KH_TUN_IP}:\$PORT"
    iptables -t nat -A POSTROUTING -p tcp -d "${KH_TUN_IP}" --dport "\$PORT" -m comment --comment "PicoTun-N${NODE_ID}" -j SNAT --to-source "${IR_TUN_IP}"
    iptables -t nat -A POSTROUTING -p udp -d "${KH_TUN_IP}" --dport "\$PORT" -m comment --comment "PicoTun-N${NODE_ID}" -j SNAT --to-source "${IR_TUN_IP}"
done

# Jump from PREROUTING into our dedicated chain
iptables -t nat -C PREROUTING -m comment --comment "PicoTun-N${NODE_ID}" -j "\$CHAIN" 2>/dev/null || \
iptables -t nat -A PREROUTING -m comment --comment "PicoTun-N${NODE_ID}" -j "\$CHAIN"

wait \$TUN_PID
EOF

        cat <<EOF > "${CONFIG_DIR}/stop-${NODE_ID}.sh"
#!/usr/bin/env bash
CHAIN="PICOTUN_${NODE_ID}"

# Remove jump + flush + delete chain
iptables -t nat -D PREROUTING -m comment --comment "PicoTun-N${NODE_ID}" -j "\$CHAIN" 2>/dev/null || true
iptables -t nat -F "\$CHAIN" 2>/dev/null || true
iptables -t nat -X "\$CHAIN" 2>/dev/null || true

# Remove SNAT rules (commented)
IFS=',' read -ra PORT_ARRAY <<< "${FWD_PORTS}"
for PORT in "\${PORT_ARRAY[@]}"; do
    iptables -t nat -D POSTROUTING -p tcp -d "${KH_TUN_IP}" --dport "\$PORT" -m comment --comment "PicoTun-N${NODE_ID}" -j SNAT --to-source "${IR_TUN_IP}" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p udp -d "${KH_TUN_IP}" --dport "\$PORT" -m comment --comment "PicoTun-N${NODE_ID}" -j SNAT --to-source "${IR_TUN_IP}" 2>/dev/null || true
done

ip link del ${TUN_DEV} 2>/dev/null || true
EOF

    elif [[ "$ROLE" == "2" ]]; then
        # ===== KHAREJ CONFIGURATION =====
        read -p "Enter Iran Server IP Address: " IRAN_IP
        PORTS="N/A (Kharej side)"

        cat <<EOF > "$STATE_FILE"
ROLE=kharej
NODE_ID=${NODE_ID}
TUN_DEV=${TUN_DEV}
IR_TUN_IP=${IR_TUN_IP}
KH_TUN_IP=${KH_TUN_IP}
TUN_PORT=${TUN_PORT}
SCHEME=${SCHEME}
IRAN_IP=${IRAN_IP}
EOF

        cat <<EOF > "${CONFIG_DIR}/node-${NODE_ID}.sh"
#!/usr/bin/env bash
set -e
ip link del ${TUN_DEV} 2>/dev/null || true

${BIN_PATH} -L "tun:///${IRAN_IP}:${TUN_PORT}?name=${TUN_DEV}&net=${KH_TUN_IP}/30&mtu=${MTU_SIZE}&peer=${IR_TUN_IP}${KCP_EXTRA}" &
TUN_PID=\$!
sleep 2
ip link set dev ${TUN_DEV} mtu ${MTU_SIZE} up

iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Lightweight keep-alive watchdog (less aggressive than before)
while kill -0 \$TUN_PID 2>/dev/null; do
    sleep 15
    if ! ping -c 2 -W 2 ${IR_TUN_IP} >/dev/null 2>&1; then
        echo "Tunnel ping failed, restarting instance..."
        kill -9 \$TUN_PID 2>/dev/null || true
        exit 1
    fi
done
EOF

        cat <<EOF > "${CONFIG_DIR}/stop-${NODE_ID}.sh"
#!/usr/bin/env bash
ip link del ${TUN_DEV} 2>/dev/null || true
EOF

    else
        echo -e "${RED}Invalid Role Selected.${NC}"; return
    fi

    chmod +x "${CONFIG_DIR}/node-${NODE_ID}.sh" "${CONFIG_DIR}/stop-${NODE_ID}.sh"

    # Systemd service with higher file descriptor limit and restart on failure
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
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "picotun-${NODE_ID}.service" >/dev/null 2>&1
    systemctl restart "picotun-${NODE_ID}.service"

    echo -e "${GREEN}Node ${NODE_ID} configured and started!${NC}"
    echo -e "Role: ${CYAN}${ROLE}${NC} | Scheme: ${CYAN}${SCHEME}${NC} | MTU: ${CYAN}${MTU_SIZE}${NC}"
    echo -e "Iran IP: ${CYAN}${IR_TUN_IP}${NC} <--> Kharej IP: ${CYAN}${KH_TUN_IP}${NC}"
    echo -e "Ports: ${CYAN}${PORTS}${NC}"
}

# ---------- Intelligent Status & Mapping ----------
check_status() {
    echo -e "\n${YELLOW}========== Tunnel Status & Mapping ==========${NC}"
    FOUND=0
    for state_file in "${STATE_DIR}"/node-*.env; do
        [[ -e "$state_file" ]] || { echo "No configured nodes found."; return; }
        FOUND=1
        # Load state
        source "$state_file"

        SVC="picotun-${NODE_ID}.service"
        STATUS=$(systemctl is-active "$SVC" 2>/dev/null || echo "inactive")

        echo -e "\n${CYAN}--- Node ${NODE_ID} (${ROLE}) ---${NC}"
        if [[ "$STATUS" == "active" ]]; then
            echo -e "  Service : ${GREEN}ACTIVE${NC}"
        else
            echo -e "  Service : ${RED}${STATUS}${NC}"
        fi

        if [[ "$ROLE" == "iran" ]]; then
            echo -e "  Role    : Iran (entry point)"
            echo -e "  Kharej  : ${KH_TUN_IP} (via tunnel port ${TUN_PORT})"
            echo -e "  Protocol: ${SCHEME}"
            echo -e "  Forward : ${FWD_PORTS}"
        else
            echo -e "  Role    : Kharej (exit node)"
            echo -e "  Iran    : ${IRAN_IP} (port ${TUN_PORT})"
            echo -e "  Protocol: ${SCHEME}"
        fi

        # Ping checks only if active
        if [[ "$STATUS" == "active" ]]; then
            if ping -c 1 -W 2 "${IR_TUN_IP}" >/dev/null 2>&1; then
                echo -e "  Ping .1 : ${GREEN}OK${NC}"
            else
                echo -e "  Ping .1 : ${RED}TIMEOUT${NC}"
            fi
            if ping -c 1 -W 2 "${KH_TUN_IP}" >/dev/null 2>&1; then
                echo -e "  Ping .2 : ${GREEN}OK${NC}"
            else
                echo -e "  Ping .2 : ${RED}TIMEOUT${NC}"
            fi
        fi
    done
    [[ "$FOUND" -eq 0 ]] && echo -e "${YELLOW}No nodes have been configured yet.${NC}"
}

# ---------- Remove Node ----------
remove_node() {
    read -p "Enter Node ID to remove: " NODE_ID
    SVC="picotun-${NODE_ID}.service"
    if [[ -f "${SYSTEMD_DIR}/${SVC}" ]]; then
        systemctl stop "$SVC" 2>/dev/null || true
        systemctl disable "$SVC" >/dev/null 2>&1 || true
        rm -f "${SYSTEMD_DIR}/${SVC}"
        rm -f "${CONFIG_DIR}/node-${NODE_ID}.sh" "${CONFIG_DIR}/stop-${NODE_ID}.sh"
        rm -f "${STATE_DIR}/node-${NODE_ID}.env"
        systemctl daemon-reload
        echo -e "${GREEN}Node ${NODE_ID} completely removed (service, scripts, state).${NC}"
    else
        echo -e "${RED}Node ${NODE_ID} does not exist.${NC}"
    fi
}

# ---------- Main Menu ----------
clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}   PicoTun Pro - Multi-Node Manager v2  ${NC}"
echo -e "${CYAN}=========================================${NC}"
echo "1) Add / Update Tunnel Node"
echo "2) Check Tunnels Status & Mapping (Intelligent)"
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
