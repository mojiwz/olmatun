#!/usr/bin/env bash
# PicoTun isolated-instance installer (compatible config schema v2)
# Creates one independent systemd process per outside server.
set -Eeuo pipefail
umask 077

BIN="${PICOTUN_BIN:-/usr/local/bin/picotun}"
CFGROOT="/etc/picotun/instances"
UNIT="/etc/systemd/system/picotun@.service"
BACKUP_DIR="/var/backups/picotun"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
die(){ red "ERROR: $*"; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root: sudo bash $0"; }
valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_id(){ [[ "$1" =~ ^[A-D]$ ]]; }
valid_hostport(){ [[ "$1" =~ ^([A-Za-z0-9._:-]+):([0-9]{1,5})$ ]] && valid_port "${BASH_REMATCH[2]}"; }
prompt(){ local __v="$1" __label="$2" __default="${3:-}"; local val; if [[ -n "$__default" ]]; then read -r -p "$__label [$__default]: " val; val="${val:-$__default}"; else read -r -p "$__label: " val; fi; printf -v "$__v" '%s' "$val"; }
secret(){ local __v="$1" __label="$2" val; read -r -s -p "$__label (input hidden): " val; echo >&2; [[ -n "$val" ]] || die "PSK cannot be empty"; printf -v "$__v" '%s' "$val"; }
choose_transport(){
  echo "Transport must match the existing peer configuration:"
  echo "  1) httpmux (default existing setup)"
  echo "  2) httpsmux (requires compatible TLS setup)"
  echo "  3) tcpmux"
  echo "  4) trojan (requires proper certificate/SNI setup)"
  local n; prompt n "Transport choice" "1"
  case "$n" in 1) TRANSPORT=httpmux;; 2) TRANSPORT=httpsmux;; 3) TRANSPORT=tcpmux;; 4) TRANSPORT=trojan;; *) die "Invalid transport choice";; esac
}
install_unit(){
  mkdir -p "$CFGROOT" "$BACKUP_DIR"
  if [[ -f "$UNIT" ]]; then cp -a "$UNIT" "$BACKUP_DIR/picotun@.service.$(date +%Y%m%d-%H%M%S).bak"; fi
  cat > "$UNIT" <<EOF
[Unit]
Description=PicoTun isolated instance %i
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
ExecStartPre=/usr/bin/test -r ${CFGROOT}/%i.yaml
ExecStart=${BIN} -c ${CFGROOT}/%i.yaml
Restart=on-failure
RestartSec=3s
TimeoutStopSec=15s
KillSignal=SIGTERM
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
  systemctl daemon-reload
}
write_common(){
  local file="$1" mode="$2" psk="$3" transport="$4" listenport="$5"
  cat > "$file" <<EOF
config_version: 2
mode: "${mode}"
EOF
  if [[ "$mode" == "server" ]]; then
    cat >> "$file" <<EOF
listen: "0.0.0.0:${listenport}"
transport: "${transport}"
psk: "${psk}"
profile: "balanced"
verbose: false
heartbeat: 5
num_connections: 4
smux:
  keepalive: 1
  max_recv: 524288
  max_stream: 524288
  frame_size: 2048
  version: 2
advanced:
  tcp_nodelay: true
  tcp_keepalive: 3
  tcp_read_buffer: 32768
  tcp_write_buffer: 32768
  max_connections: 300
  max_streams_per_session: 256
  cleanup_interval: 3
  connection_timeout: 30
  stream_timeout: 60
  max_udp_flows: 300
  udp_flow_timeout: 90
  udp_buffer_size: 262144
obfuscation:
  enabled: false
  min_padding: 0
  max_padding: 0
  min_delay_ms: 0
  max_delay_ms: 0
EOF
  else
    cat >> "$file" <<EOF
psk: "${psk}"
transport: "${transport}"
profile: "balanced"
verbose: false
heartbeat: 5
num_connections: 4
paths:
  - transport: "${transport}"
    addr: "${listenport}"
    connection_pool: 4
    retry_interval: 3
    dial_timeout: 15
smux:
  keepalive: 1
  max_recv: 524288
  max_stream: 524288
  frame_size: 2048
  version: 2
advanced:
  tcp_nodelay: true
  tcp_keepalive: 3
  tcp_read_buffer: 32768
  tcp_write_buffer: 32768
  connection_timeout: 30
obfuscation:
  enabled: false
  min_padding: 0
  max_padding: 0
  min_delay_ms: 0
  max_delay_ms: 0
EOF
  fi
}
install_server_instance(){
  local id port psk transport maps map item proto bind target bp tp config tmp
  prompt id "Outside instance ID (A-D)" "A"; valid_id "$id" || die "ID must be A, B, C or D"
  prompt port "Iran tunnel listen port" "$((2019 + $(printf '%d' "'$id") - 64))"
  valid_port "$port" || die "Invalid tunnel port"
  secret psk "PSK for outside $id"
  choose_transport; transport="$TRANSPORT"
  echo
  echo "Enter mappings as comma-separated items: tcp:10000=10000,udp:10000=10000"
  echo "Left port = public bind port on Iran; right port = target port on the outside."
  prompt maps "Mappings" "tcp:10000=10000,udp:10000=10000"
  [[ -n "$maps" ]] || die "At least one mapping is required"
  local -A seen=()
  tmp="$(mktemp)"
  config="${CFGROOT}/iran-${id}.yaml"
  # Build into a temporary file, then atomically install after validation.
  write_common "$tmp" server "$psk" "$transport" "$port"
  printf '\nmaps:\n' >> "$tmp"
  IFS=',' read -r -a items <<< "$maps"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ "$item" =~ ^(tcp|udp):([0-9]{1,5})=([0-9]{1,5})$ ]] || { rm -f "$tmp"; die "Invalid mapping '$item'"; }
    proto="${BASH_REMATCH[1]}"; bp="${BASH_REMATCH[2]}"; tp="${BASH_REMATCH[3]}"
    valid_port "$bp" && valid_port "$tp" || { rm -f "$tmp"; die "Ports must be 1-65535"; }
    [[ -z "${seen["$proto:$bp"]+x}" ]] || { rm -f "$tmp"; die "Duplicate $proto bind port $bp in this instance"; }
    seen["$proto:$bp"]=1
    printf '  - type: %s\n    bind: "0.0.0.0:%s"\n    target: "127.0.0.1:%s"\n' "$proto" "$bp" "$tp" >> "$tmp"
  done
  chmod 600 "$tmp"
  if [[ -f "$config" ]]; then cp -a "$config" "$BACKUP_DIR/iran-${id}.yaml.$(date +%Y%m%d-%H%M%S).bak"; fi
  install -m 600 "$tmp" "$config"; rm -f "$tmp"
  install_unit
  echo
  yellow "Review the target semantics for your PicoTun version before enabling this config."
  echo "Config: $config"
  echo "Tunnel port: $port/tcp (transport-dependent; check the chosen transport and firewall)"
  read -r -p "Enable and start iran-${id} now? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    systemctl enable --now "picotun@iran-${id}"
    systemctl --no-pager --full status "picotun@iran-${id}" || true
  else
    echo "Not started. Start later with: systemctl enable --now picotun@iran-${id}"
  fi
  echo
  echo "Client settings to mirror on outside $id:"
  echo "  mode=client; transport=$transport; PSK=<same secret>; paths.addr=<IRAN_IP>:$port"
}
install_client_instance(){
  local id iran_ipport psk transport config tmp
  prompt id "Outside instance ID (A-D)" "A"; valid_id "$id" || die "ID must be A, B, C or D"
  prompt iran_ipport "Iran server address and tunnel port (host:port)"
  valid_hostport "$iran_ipport" || die "Use IPv4/hostname:port (IPv6 literals are not supported by this simple prompt)"
  secret psk "PSK for outside $id"
  choose_transport; transport="$TRANSPORT"
  config="${CFGROOT}/client-${id}.yaml"; tmp="$(mktemp)"
  write_common "$tmp" client "$psk" "$transport" "$iran_ipport"
  chmod 600 "$tmp"
  if [[ -f "$config" ]]; then cp -a "$config" "$BACKUP_DIR/client-${id}.yaml.$(date +%Y%m%d-%H%M%S).bak"; fi
  install -m 600 "$tmp" "$config"; rm -f "$tmp"
  install_unit
  echo "Config: $config"
  read -r -p "Enable and start client-${id} now? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    systemctl enable --now "picotun@client-${id}"
    systemctl --no-pager --full status "picotun@client-${id}" || true
  fi
}
status_all(){
  systemctl --no-pager --full list-units 'picotun@*' || true
  echo
  ss -lntup | grep -E 'picotun|:20[0-9][0-9]\b' || true
}
logs_instance(){
  local name; prompt name "Instance suffix (e.g. iran-A or client-A)"
  [[ "$name" =~ ^(iran|client)-[A-D]$ ]] || die "Invalid instance name"
  journalctl -u "picotun@${name}" -n 100 --no-pager
}
main(){
  need_root
  [[ -x "$BIN" ]] || die "PicoTun binary not found at $BIN. Install the official compatible binary first; no unverified binary will be installed by this script."
  echo "PicoTun isolated-instance manager"
  echo "Binary: $BIN"
  "$BIN" -version 2>&1 | head -1 || true
  echo
  echo "1) Configure Iran server instance"
  echo "2) Configure outside client instance"
  echo "3) Show service/listener status"
  echo "4) Show instance logs"
  echo "0) Exit"
  local choice; prompt choice "Select" "1"
  case "$choice" in
    1) install_server_instance;;
    2) install_client_instance;;
    3) status_all;;
    4) logs_instance;;
    0) exit 0;;
    *) die "Invalid choice";;
  esac
}
main "$@"
