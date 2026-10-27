#!/usr/bin/env bash
# =====================================================================
#  Over-Tun : Iran <-> Kharej reverse tunnel + web monitor
#  Engine : FRP (large pre-opened connection pool = no waiting on new connections)
#  Iran   = frps (users connect here)
#  Kharej = frpc (dials Iran, auto-reconnects, watchdog)
#  Methods: WSS (WebSocket+TLS) | TLS (TCP+TLS) | QUIC (UDP) | KCP (UDP)
# =====================================================================

FRP_VER="0.63.0"
REPO_RAW="https://raw.githubusercontent.com/ibooplay/Overal-Tun/main/tunnel.sh"
CMD=/usr/local/bin/over-tun
CONF_DIR=/etc/overtun
CONF=$CONF_DIR/tunnel.env          # meta info (role, method, ports) - exists = installed
FRP_CONF=$CONF_DIR/frp.toml
SVC_NAME=overtun
SVC=/etc/systemd/system/$SVC_NAME.service
MODE_FILE=$CONF_DIR/mode
DROPIN_DIR=/etc/systemd/system/$SVC_NAME.service.d
API_IRAN=7500                       # frps local API (127.0.0.1 only)
API_KHAREJ=7400                     # frpc local API (127.0.0.1 only)

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'

get_arch() {
  case "$(uname -m)" in
    x86_64)        echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv6l) echo "arm" ;;
    *)             echo "" ;;
  esac
}

install_deps() {
  echo -e "${YEL}Installing requirements (may take 1-2 minutes)...${NC}"
  if command -v apt >/dev/null; then
    apt update -y >/dev/null 2>&1; apt install -y tar curl iproute2 openssl python3 >/dev/null 2>&1
  elif command -v yum >/dev/null; then
    yum install -y tar curl iproute openssl python3 >/dev/null 2>&1
  fi
}

install_binary() {
  if [[ -x /usr/local/bin/frps && -x /usr/local/bin/frpc ]] && /usr/local/bin/frpc --version 2>/dev/null | grep -q "$FRP_VER"; then
    echo -e "${GRN}FRP $FRP_VER already installed${NC}"; return
  fi
  local arch; arch=$(get_arch)
  [[ -z $arch ]] && { echo -e "${RED}Unsupported CPU arch${NC}"; exit 1; }
  local name="frp_${FRP_VER}_linux_${arch}"
  local url="https://github.com/fatedier/frp/releases/download/v${FRP_VER}/${name}.tar.gz"
  echo -e "${YEL}Downloading FRP $FRP_VER...${NC}"
  if [[ -f /root/frp.tar.gz ]]; then
    echo "Using local /root/frp.tar.gz"
  elif ! curl -fL --connect-timeout 15 -o /root/frp.tar.gz "$url"; then
    rm -f /root/frp.tar.gz
    echo -e "${RED}Download failed (GitHub may be blocked).${NC}"
    echo "Download manually: $url"
    echo "Upload it to /root/frp.tar.gz and run this again."
    exit 1
  fi
  rm -rf /tmp/frpx; mkdir -p /tmp/frpx
  tar xzf /root/frp.tar.gz -C /tmp/frpx && \
    install -m 755 /tmp/frpx/*/frps /usr/local/bin/frps && \
    install -m 755 /tmp/frpx/*/frpc /usr/local/bin/frpc
  rm -rf /tmp/frpx /root/frp.tar.gz
  [[ -x /usr/local/bin/frpc ]] || { echo -e "${RED}Install failed${NC}"; exit 1; }
  echo -e "${GRN}FRP installed${NC}"
}

# remove the old rathole-based version if present
cleanup_legacy() {
  if [[ -f /etc/systemd/system/rathole.service || -d /etc/rathole ]]; then
    echo -e "${YEL}Removing old (rathole) tunnel version...${NC}"
    systemctl disable --now rathole rathole-watchdog.timer rathole-web 2>/dev/null
    rm -rf /etc/systemd/system/rathole.service /etc/systemd/system/rathole.service.d \
      /etc/systemd/system/rathole-watchdog.* /etc/systemd/system/rathole-web.service \
      /usr/local/bin/rathole /usr/local/bin/rathole-watchdog.sh /usr/local/bin/rathole-web.py /etc/rathole
    [[ -x /usr/local/bin/rathole-nic.sh ]] && mv -f /usr/local/bin/rathole-nic.sh /usr/local/bin/overtun-nic.sh
    systemctl daemon-reload
  fi
}

# ---------------- speed modes ----------------
choose_mode() {
  local cur; cur=$(cat $MODE_FILE 2>/dev/null)
  echo -e "\n${CYN}Speed mode:${NC}"
  echo "  1) Medium   - good speed, very light on CPU/RAM (small/weak servers)"
  echo "  2) Turbo    - high speed, moderate CPU/RAM                     [recommended]"
  echo "  3) Advanced - maximum speed; uses more CPU/RAM only under heavy load"
  [[ -n $cur ]] && echo -e "  current: ${YEL}$cur${NC}"
  read -rp "Choose [2]: " m
  case ${m:-2} in 1) MODE=medium ;; 3) MODE=advanced ;; *) MODE=turbo ;; esac
}

# ready-made connections kept open between the servers (client pool / server max)
pool_for_mode() {
  case $1 in
    medium)   POOL=20;  MAXPOOL=80 ;;
    advanced) POOL=150; MAXPOOL=600 ;;
    *)        POOL=60;  MAXPOOL=250 ;;
  esac
}

# apply_profile <medium|turbo|advanced> : kernel network tuning + process priority
apply_profile() {
  local mode=${1:-turbo} buf lowat backlog somax slow cpuq nice weight
  case $mode in
    medium)   buf=8388608;   lowat=131072; backlog=16384;  somax=8192;  slow=1; cpuq="CPUQuota=80%"; nice=0;   weight=100 ;;
    advanced) buf=134217728; lowat=131072; backlog=250000; somax=65535; slow=0; cpuq="";             nice=-10; weight=1000 ;;
    *)        mode=turbo; buf=33554432; lowat=16384; backlog=65536; somax=32768; slow=0; cpuq=""; nice=-5; weight=400 ;;
  esac
  echo -e "${YEL}Applying speed mode: $mode ...${NC}"
  modprobe tcp_bbr 2>/dev/null
  cat > /etc/sysctl.d/99-tunnel.conf <<EOF
# over-tun - speed mode: $mode
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=$buf
net.core.wmem_max=$buf
net.ipv4.tcp_rmem=4096 131072 $buf
net.ipv4.tcp_wmem=4096 65536 $buf
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.tcp_notsent_lowat=$lowat
net.ipv4.tcp_slow_start_after_idle=$slow
net.core.netdev_max_backlog=$backlog
net.core.somaxconn=$somax
net.ipv4.tcp_max_syn_backlog=$somax
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
fs.file-max=2097152
EOF
  sysctl --system >/dev/null 2>&1

  # NIC tuning (Advanced: bigger TX queue, faster TCP ramp-up, packet work spread on all cores)
  cat > /usr/local/bin/overtun-nic.sh <<'EOF'
#!/bin/bash
IF=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ -z "$IF" ] && exit 0
N=$(nproc); [ "$N" -gt 31 ] && N=31
if [ "$1" = advanced ]; then
  ip link set dev "$IF" txqueuelen 10000 2>/dev/null
  R=$(ip route show default | head -1 | sed -E 's/ (initcwnd|initrwnd) [0-9]+//g')
  [ -n "$R" ] && ip route change $R initcwnd 100 initrwnd 100 2>/dev/null
  MASK=$(printf '%x' $(( (1 << N) - 1 )))
  sysctl -qw net.core.rps_sock_flow_entries=32768 2>/dev/null
  for q in /sys/class/net/$IF/queues/rx-*; do
    [ -w "$q/rps_cpus" ] && echo "$MASK" > "$q/rps_cpus"
    [ -w "$q/rps_flow_cnt" ] && echo 4096 > "$q/rps_flow_cnt"
  done
else
  ip link set dev "$IF" txqueuelen 1000 2>/dev/null
  R=$(ip route show default | head -1)
  case "$R" in *initcwnd*) ip route change $(echo "$R" | sed -E 's/ (initcwnd|initrwnd) [0-9]+//g') 2>/dev/null ;; esac
  for q in /sys/class/net/$IF/queues/rx-*; do [ -w "$q/rps_cpus" ] && echo 0 > "$q/rps_cpus"; done
fi
exit 0
EOF
  chmod +x /usr/local/bin/overtun-nic.sh

  mkdir -p $DROPIN_DIR $CONF_DIR
  cat > $DROPIN_DIR/mode.conf <<EOF
[Service]
Nice=$nice
CPUWeight=$weight
$cpuq
ExecStartPre=-/usr/local/bin/overtun-nic.sh $mode
EOF
  echo "$mode" > $MODE_FILE
  systemctl daemon-reload
  echo "Mode: $mode | congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

change_mode() {
  [[ -f $CONF ]] || { echo -e "${RED}Install the tunnel first (option 1 or 2)${NC}"; return; }
  choose_mode; apply_profile "$MODE"; pool_for_mode "$MODE"
  sed -i -E "s/^transport\.poolCount = .*/transport.poolCount = $POOL/; s/^transport\.maxPoolCount = .*/transport.maxPoolCount = $MAXPOOL/" $FRP_CONF
  systemctl restart $SVC_NAME
  echo -e "${GRN}Speed mode changed to $MODE (tunnel reconnected).${NC}"
  echo "Tip: set the same mode on the other server too."
}

# ---------------- service / watchdog ----------------
write_service() {   # $1 = frps | frpc
  cat > $SVC <<EOF
[Unit]
Description=Over-Tun tunnel ($1)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/$1 -c $FRP_CONF
Restart=always
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable $SVC_NAME >/dev/null 2>&1
  systemctl restart $SVC_NAME
}

# Kharej: restart the tunnel if no forwarded port is "running" for ~10s
write_watchdog() {
  cat > /usr/local/bin/overtun-watchdog.sh <<EOF
#!/bin/bash
ok() { curl -s --max-time 3 http://127.0.0.1:$API_KHAREJ/api/status | grep -q '"status":"running"'; }
ok && exit 0
sleep 10
ok && exit 0
logger "overtun-watchdog: tunnel down, restarting"
systemctl restart $SVC_NAME
EOF
  chmod +x /usr/local/bin/overtun-watchdog.sh
  cat > /etc/systemd/system/overtun-watchdog.service <<'EOF'
[Unit]
Description=Over-Tun watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/overtun-watchdog.sh
EOF
  cat > /etc/systemd/system/overtun-watchdog.timer <<'EOF'
[Unit]
Description=Run Over-Tun watchdog every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now overtun-watchdog.timer >/dev/null 2>&1
}

# ---------------- config ----------------
choose_transport() {
  echo -e "\n${CYN}Tunnel method:${NC}"
  echo "  1) TLS  - TCP + TLS, encrypted, ~2.5x faster than WSS        [recommended]"
  echo "  2) WSS  - WebSocket + TLS, looks like normal HTTPS (use if TLS gets disrupted)"
  echo "  3) QUIC - UDP, very fast, great on lossy/mobile lines (UDP must be open between servers)"
  echo "  4) KCP  - UDP, for very bad lines with heavy packet loss (uses ~15% more traffic)"
  echo "  (WSS and TLS can be switched later from the web panel without reinstalling)"
  read -rp "Choose [1]: " t
  case ${t:-1} in
    2) TRANSPORT=wss ;;
    3) TRANSPORT=quic ;;
    4) TRANSPORT=kcp ;;
    *) TRANSPORT=tls ;;
  esac
}

is_udp() { [[ $1 == quic || $1 == kcp ]]; }

port_in_use() {   # port_in_use <port> [udp]
  if [[ $2 == udp ]]; then [[ -n $(ss -Hlun "( sport = :$1 )" 2>/dev/null) ]]
  else [[ -n $(ss -Hltn "( sport = :$1 )" 2>/dev/null) ]]; fi
}

ask_ports() {
  local tport=$1
  read -rp "Service ports to forward (comma separated, e.g. 2022,8443): " PORTS_IN
  PORTS_IN=$(echo "$PORTS_IN" | tr -d ' ')
  [[ $PORTS_IN =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo -e "${RED}Invalid port list${NC}"; return 1; }
  for p in ${PORTS_IN//,/ }; do
    [[ $p == "$tport" ]] && ! is_udp "$TRANSPORT" && { echo -e "${RED}Port $p is the tunnel port. Pick a different service port.${NC}"; return 1; }
    [[ $p == 7400 || $p == 7500 ]] && { echo -e "${RED}Port $p is reserved for the tunnel itself.${NC}"; return 1; }
    port_in_use "$p" && { echo -e "${RED}Port $p is already in use on this server.${NC}"; return 1; }
  done
  read -rp "Also forward UDP on these ports? [y/N]: " u
  [[ $u =~ ^[Yy]$ ]] && UDP=y || UDP=n
}

gen_tls() {   # gen_tls <sni> -> $CONF_DIR/tls/{ca.pem,srv.pem,srv.key}
  local sni=$1 d=$CONF_DIR/tls
  rm -rf "$d"; mkdir -p "$d"; chmod 700 "$d"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$d/ca.key" -out "$d/ca.pem" -days 3650 -subj "/CN=Root CA" >/dev/null 2>&1 &&
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$d/srv.key" -out "$d/srv.csr" -subj "/CN=$sni" >/dev/null 2>&1 &&
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$sni" > "$d/ext.cnf" &&
  openssl x509 -req -in "$d/srv.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial \
    -out "$d/srv.pem" -days 3650 -extfile "$d/ext.cnf" >/dev/null 2>&1 ||
    { echo -e "${RED}TLS certificate generation failed${NC}"; return 1; }
  rm -f "$d/srv.csr" "$d/ext.cnf"
}

# gen_iran_config <transport> <tunnel_port> <token> <ports_csv> <udp y/n> <sni> <mode>
gen_iran_config() {
  local tr=$1 tport=$2 token=$3 ports=$4 udp=$5 sni=$6 mode=$7
  mkdir -p $CONF_DIR; chmod 700 $CONF_DIR
  gen_tls "$sni" || return 1
  pool_for_mode "$mode"
  {
    printf 'bindAddr = "0.0.0.0"\nbindPort = %s\n' "$tport"
    [[ $tr == kcp ]]  && printf 'kcpBindPort = %s\n' "$tport"
    [[ $tr == quic ]] && printf 'quicBindPort = %s\n' "$tport"
    printf 'auth.method = "token"\nauth.token = "%s"\n' "$token"
    printf 'transport.maxPoolCount = %s\ntransport.tcpMux = false\ntransport.tcpKeepalive = 20\ntransport.heartbeatTimeout = 40\n' "$MAXPOOL"
    printf 'transport.tls.force = true\ntransport.tls.certFile = "%s"\ntransport.tls.keyFile = "%s"\n' "$CONF_DIR/tls/srv.pem" "$CONF_DIR/tls/srv.key"
    printf 'allowPorts = ['
    local first=1
    for p in ${ports//,/ }; do [[ $first == 1 ]] || printf ', '; printf '{ single = %s }' "$p"; first=0; done
    printf ']\n'
    printf 'webServer.addr = "127.0.0.1"\nwebServer.port = %s\n' "$API_IRAN"
    printf 'log.to = "console"\nlog.level = "info"\nlog.disablePrintColor = true\n'
  } > $FRP_CONF
  chmod 600 $FRP_CONF
  printf 'ROLE=iran\nTRANSPORT=%s\nTPORT=%s\nPORTS=%s\nUDP=%s\nSNI=%s\nPEER=\n' "$tr" "$tport" "$ports" "$udp" "$sni" > $CONF
  printf 'V=2\nTRANSPORT=%s\nTPORT=%s\nTOKEN=%s\nPORTS=%s\nUDP=%s\nSNI=%s\nCA=%s\n' \
    "$tr" "$tport" "$token" "$ports" "$udp" "$sni" "$(base64 -w0 $CONF_DIR/tls/ca.pem)" | base64 -w0 > $CONF_DIR/code.txt
}

# gen_kharej_config <iran_ip> <connection_code> <mode>
gen_kharej_config() {
  local ip=$1 dec mode=$3
  dec=$(echo "$2" | tr -d ' \r\n' | base64 -d 2>/dev/null)
  getv() { echo "$dec" | grep -m1 "^$1=" | cut -d= -f2-; }
  local v tr tport token ports udp sni ca
  v=$(getv V); tr=$(getv TRANSPORT); tport=$(getv TPORT); token=$(getv TOKEN); ports=$(getv PORTS)
  udp=$(getv UDP); sni=$(getv SNI); ca=$(getv CA)
  [[ -z $v ]] && { echo -e "${RED}Invalid connection code - copy the WHOLE code from the Iran server.${NC}"; return 1; }
  [[ $v != 2 ]] && { echo -e "${RED}This code is from the OLD version. Install the new version on the Iran server first and use its new code.${NC}"; return 1; }
  [[ -z $tr || -z $tport || -z $token || -z $ports || -z $ca ]] && { echo -e "${RED}Invalid connection code${NC}"; return 1; }
  mkdir -p $CONF_DIR/tls; chmod 700 $CONF_DIR
  echo "$ca" | base64 -d > $CONF_DIR/tls/ca.pem
  pool_for_mode "$mode"
  local proto=$tr; [[ $tr == wss ]] && proto=websocket; [[ $tr == tls ]] && proto=tcp
  {
    printf 'serverAddr = "%s"\nserverPort = %s\nloginFailExit = false\n' "$ip" "$tport"
    printf 'auth.method = "token"\nauth.token = "%s"\n' "$token"
    printf 'transport.protocol = "%s"\ntransport.poolCount = %s\ntransport.tcpMux = false\n' "$proto" "$POOL"
    printf 'transport.dialServerTimeout = 10\ntransport.dialServerKeepalive = 20\n'
    printf 'transport.heartbeatInterval = 10\ntransport.heartbeatTimeout = 30\n'
    printf 'transport.tls.enable = true\ntransport.tls.serverName = "%s"\ntransport.tls.trustedCaFile = "%s"\n' "$sni" "$CONF_DIR/tls/ca.pem"
    printf 'transport.quic.keepalivePeriod = 10\ntransport.quic.maxIdleTimeout = 30\n'
    printf 'webServer.addr = "127.0.0.1"\nwebServer.port = %s\n' "$API_KHAREJ"
    printf 'log.to = "console"\nlog.level = "info"\nlog.disablePrintColor = true\n'
    for p in ${ports//,/ }; do
      printf '\n[[proxies]]\nname = "t%s"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' "$p" "$p" "$p"
      [[ $udp == y ]] && printf '\n[[proxies]]\nname = "u%s"\ntype = "udp"\nlocalIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' "$p" "$p" "$p"
    done
  } > $FRP_CONF
  chmod 600 $FRP_CONF
  printf 'ROLE=kharej\nTRANSPORT=%s\nTPORT=%s\nPORTS=%s\nUDP=%s\nSNI=%s\nPEER=%s\n' "$tr" "$tport" "$ports" "$udp" "$sni" "$ip" > $CONF
  KH_TPORT=$tport; KH_PORTS=$ports; KH_TR=$tr
}

show_code() {
  [[ -f $CONF_DIR/code.txt ]] || { echo -e "${RED}No connection code (run on the Iran server after install)${NC}"; return; }
  echo -e "\n${CYN}Connection code - copy ALL of it to the Kharej server:${NC}\n"
  cat $CONF_DIR/code.txt; echo -e "\n"
}

kharej_linked() { curl -s --max-time 3 http://127.0.0.1:$API_KHAREJ/api/status | grep -q '"status":"running"'; }

setup_iran() {
  install_deps; install_binary; cleanup_legacy
  choose_mode; apply_profile "$MODE"
  systemctl stop $SVC_NAME 2>/dev/null
  choose_transport
  read -rp "Tunnel port [443]: " TPORT; TPORT=${TPORT:-443}
  if port_in_use "$TPORT"; then echo -e "${RED}TCP port $TPORT is already in use. Pick another (e.g. 8443 or 2053).${NC}"; return; fi
  if is_udp "$TRANSPORT" && port_in_use "$TPORT" udp; then echo -e "${RED}UDP port $TPORT is already in use.${NC}"; return; fi
  read -rp "TLS domain / SNI [www.speedtest.net]: " SNI; SNI=${SNI:-www.speedtest.net}
  ask_ports "$TPORT" || return
  TOKEN=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
  gen_iran_config "$TRANSPORT" "$TPORT" "$TOKEN" "$PORTS_IN" "$UDP" "$SNI" "$MODE" || return
  write_service frps
  sleep 2
  if systemctl is-active --quiet $SVC_NAME; then
    echo -e "\n${GRN}Iran server ready  (method: $TRANSPORT, tunnel port: $TPORT, ports: $PORTS_IN, mode: $MODE)${NC}"
    is_udp "$TRANSPORT" && echo -e "${YEL}Make sure UDP port $TPORT is open in your server provider's firewall.${NC}"
  else
    echo -e "${RED}Tunnel failed to start:${NC}"; journalctl -u $SVC_NAME -n 15 --no-pager; return
  fi
  show_code
}

setup_kharej() {
  install_deps; install_binary; cleanup_legacy
  choose_mode; apply_profile "$MODE"
  systemctl stop $SVC_NAME 2>/dev/null
  read -rp "Iran server IP: " IRIP
  read -rp "Connection code (from Iran server): " CODE
  gen_kharej_config "$IRIP" "$CODE" "$MODE" || return
  write_service frpc
  write_watchdog
  for p in ${KH_PORTS//,/ }; do
    port_in_use "$p" || echo -e "${YEL}Warning: nothing is listening on port $p on this server yet (start your service, e.g. Xray, on it).${NC}"
  done
  echo -ne "${YEL}Connecting${NC}"
  for i in $(seq 15); do kharej_linked && break; echo -n "."; sleep 1; done; echo
  if kharej_linked; then
    echo -e "${GRN}Tunnel connected to $IRIP:$KH_TPORT  (method: $KH_TR, mode: $MODE)${NC}"
  else
    echo -e "${YEL}Not connected yet. Check logs with option 3.${NC}"
    journalctl -u $SVC_NAME -n 8 --no-pager | cut -c1-220
  fi
}

status() {
  [[ -f $CONF ]] || { echo -e "${RED}Tunnel is not installed${NC}"; return; }
  . $CONF
  echo -e "Role: ${CYN}$ROLE${NC} | method: $TRANSPORT | tunnel port: $TPORT | ports: $PORTS | mode: $(cat $MODE_FILE 2>/dev/null)"
  echo -n "Service: "; systemctl is-active $SVC_NAME
  if [[ $ROLE == kharej ]]; then
    kharej_linked && echo -e "Link: ${GRN}CONNECTED${NC}" || echo -e "Link: ${RED}NOT connected${NC}"
  else
    local n; n=$(curl -s --max-time 3 http://127.0.0.1:$API_IRAN/api/serverinfo | grep -oP '"clientCounts":\s*\K\d+')
    [[ ${n:-0} -gt 0 ]] && echo -e "Link: ${GRN}CONNECTED${NC} (kharej clients: $n)" || echo -e "Link: ${RED}no kharej server connected${NC}"
  fi
  echo "--- last logs ---"
  journalctl -u $SVC_NAME -n 20 --no-pager | cut -c1-220
}

install_web() {
  [[ -f $CONF ]] || { echo -e "${RED}Install the tunnel first (option 1 or 2)${NC}"; return; }
  command -v python3 >/dev/null || { apt install -y python3 >/dev/null 2>&1 || yum install -y python3 >/dev/null 2>&1; }
  command -v python3 >/dev/null || { echo -e "${RED}python3 not available${NC}"; return; }
  local RP=$((RANDOM % 30000 + 20000))
  read -rp "Panel port [$RP]: " WP; WP=${WP:-$RP}
  read -rp "Username [admin]: " WU; WU=${WU:-admin}
  read -rp "Password [random]: " WPASS
  [[ -z $WPASS ]] && WPASS=$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
  read -rp "Server port speed in Mbps for the gauges, e.g. 1000 [auto]: " LINK
  [[ $LINK =~ ^[0-9]+$ ]] || LINK=0
  mkdir -p $CONF_DIR
  local WHASH
  WHASH=$(python3 -c 'import hashlib,os,sys;s=os.urandom(16);print(s.hex()+"$"+hashlib.pbkdf2_hmac("sha256",sys.argv[1].encode(),s,200000).hex())' "$WPASS")
  printf 'WEB_PORT=%s\nWEB_USER=%s\nWEB_HASH=%s\nLINK_MBPS=%s\n' "$WP" "$WU" "$WHASH" "$LINK" > $CONF_DIR/web.conf
  chmod 600 $CONF_DIR/web.conf

  cat > /usr/local/bin/overtun-web.py <<'PYEOF'
#!/usr/bin/env python3
# Web monitor for Over-Tun tunnel - no external dependencies
import json, os, re, socket, subprocess, threading, time, base64, urllib.request, hashlib, hmac, secrets
from http.cookies import SimpleCookie
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from collections import deque

CONF_DIR = '/etc/overtun'

def load_kv(path):
    d = {}
    try:
        for line in open(path):
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                d[k.strip()] = v.strip().strip('"')
    except FileNotFoundError:
        pass
    return d

ENV = load_kv(CONF_DIR + '/tunnel.env')
ROLE = ENV.get('ROLE', 'iran')
TRANSPORT = ENV.get('TRANSPORT', 'wss')
TPORT = int(ENV.get('TPORT', '443') or 443)
PEER = ENV.get('PEER', '')
PORTS = sorted({int(p) for p in ENV.get('PORTS', '').split(',') if p.strip().isdigit()})
API_PORT = 7500 if ROLE == 'iran' else 7400

def cur_mode():
    try:
        return open(CONF_DIR + '/mode').read().strip() or 'turbo'
    except OSError:
        return 'turbo'

def api(path):
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{API_PORT}{path}', timeout=2) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None

def link_up():
    # ask FRP itself: Iran = a kharej client is logged in, Kharej = forwarded ports are running
    if ROLE == 'iran':
        d = api('/api/serverinfo')
        return bool(d) and (d.get('clientCounts') or 0) > 0
    d = api('/api/status')
    return bool(d) and any(isinstance(v, list) and any(p.get('status') == 'running' for p in v) for v in d.values())

WEB = load_kv(CONF_DIR + '/web.conf')
LISTEN = int(WEB.get('WEB_PORT', '9090'))
try:
    LINK_MBPS = int(WEB.get('LINK_MBPS', '0') or 0)
except ValueError:
    LINK_MBPS = 0
CMD = '/usr/local/bin/over-tun'
USER = WEB.get('WEB_USER', 'admin')

def make_hash(pw):
    salt = os.urandom(16)
    return salt.hex() + '$' + hashlib.pbkdf2_hmac('sha256', pw.encode(), salt, 200000).hex()

def save_web(key, val):
    lines = [l for l in open(CONF_DIR + '/web.conf').read().splitlines() if l and not l.startswith(key + '=') and not l.startswith('WEB_PASS=')]
    lines.append(f'{key}={val}')
    open(CONF_DIR + '/web.conf', 'w').write('\n'.join(lines) + '\n')
    os.chmod(CONF_DIR + '/web.conf', 0o600)

PWHASH = WEB.get('WEB_HASH', '')
if not PWHASH:                      # migrate an old plain-text password to a hash
    PWHASH = make_hash(WEB.get('WEB_PASS', 'admin'))
    try: save_web('WEB_HASH', PWHASH)
    except OSError: pass

def check_pw(pw):
    try:
        salt, h = PWHASH.split('$', 1)
        return hmac.compare_digest(hashlib.pbkdf2_hmac('sha256', pw.encode(), bytes.fromhex(salt), 200000).hex(), h)
    except Exception:
        return False

SESSION_TTL = 12 * 3600
SESS, FAILS, SL = {}, {}, threading.Lock()

def refresh_env():
    global PORTS, TRANSPORT, ENV
    ENV = load_kv(CONF_DIR + '/tunnel.env')
    TRANSPORT = ENV.get('TRANSPORT', TRANSPORT)
    PORTS = sorted({int(p) for p in ENV.get('PORTS', '').split(',') if p.strip().isdigit()})

def config_info():
    refresh_env()
    d = {'role': ROLE, 'transport': TRANSPORT, 'tport': TPORT, 'ports': PORTS, 'udp': ENV.get('UDP') == 'y',
         'mode': cur_mode(), 'peer': ENV.get('PEER', ''), 'user': USER, 'code': ''}
    if ROLE == 'iran':
        try: d['code'] = open(CONF_DIR + '/code.txt').read().strip()
        except OSError: pass
    else:   # per-port status from frpc (e.g. "port not allowed" = missing on the Iran server)
        st, a = {}, api('/api/status') or {}
        for v in a.values():
            for x in (v if isinstance(v, list) else []):
                m = re.match(r'^[tu](\d+)$', x.get('name', ''))
                if m and x.get('status') != 'running': st[m.group(1)] = x.get('err') or x.get('status')
        d['pstatus'] = st
    return d

ANSI = re.compile(r'\x1b\[[0-9;]*m')
ARG_RX = {'mode': [r'^(medium|turbo|advanced)$'], 'port-add': [r'^\d{1,5}$'], 'port-del': [r'^\d{1,5}$'],
          'method': [r'^(wss|tls)$'], 'reconnect': [r'^[A-Za-z0-9.:-]{3,100}$', r'^[A-Za-z0-9+/=]{20,10000}$'],
          'restart': [], 'stop': [], 'start': []}

def manage(action, args):
    if action not in ARG_RX: return False, 'unknown action'
    rx = ARG_RX[action]
    args = [str(a).strip() for a in (args or [])]
    if action == 'reconnect' and len(args) == 2: args[1] = re.sub(r'\s+', '', args[1])
    if len(args) != len(rx) or not all(re.match(r, a) for r, a in zip(rx, args)):
        return False, 'ERROR: invalid input'
    try:
        r = subprocess.run([CMD, action] + args, capture_output=True, text=True, timeout=120)
        out = ANSI.sub('', (r.stdout + r.stderr).strip())
        return r.returncode == 0 and 'ERROR' not in out, out or 'done'
    except Exception as e:
        return False, f'ERROR: {e}'

def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ''

m = re.search(r'dev (\S+)', sh(['ip', 'route', 'get', '1.1.1.1']))
IFACE = WEB.get('IFACE') or (m.group(1) if m else 'eth0')

def rd(path):
    try:
        return int(open(path).read())
    except Exception:
        return 0

def net():
    b = f'/sys/class/net/{IFACE}/statistics/'
    return rd(b + 'rx_bytes'), rd(b + 'tx_bytes')

def cpu_times():
    v = list(map(int, open('/proc/stat').readline().split()[1:]))
    return v[3] + v[4], sum(v)

def hexip(h):
    if len(h) == 8:
        return socket.inet_ntop(socket.AF_INET, bytes.fromhex(h)[::-1])
    b = bytes.fromhex(h)
    b = b''.join(b[i:i + 4][::-1] for i in range(0, 16, 4))
    ip = socket.inet_ntop(socket.AF_INET6, b)
    return ip[7:] if ip.startswith('::ffff:') else ip

def established():
    # read /proc/net/tcp{,6} directly (fast, no external tools)
    out = []
    for fn in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            lines = open(fn).read().splitlines()[1:]
        except OSError:
            continue
        for l in lines:
            f = l.split()
            if len(f) < 4 or f[3] != '01':
                continue
            la, lp = f[1].split(':'); ra, rp = f[2].split(':')
            out.append((hexip(la), int(lp, 16), hexip(ra), int(rp, 16)))
    return out

def conns():
    tun, per = [], {p: 0 for p in PORTS}
    for lh, lp, ph, pp in established():
        if ROLE == 'iran':
            if lp == TPORT: tun.append(ph)
            elif lp in per and not ph.startswith('127.'): per[lp] += 1
        else:
            if pp == TPORT: tun.append(ph)
            elif pp in per and ph in ('127.0.0.1', '::1'): per[pp] += 1
    return tun, per

def svc_active():
    return sh(['systemctl', 'is-active', 'overtun']).strip() == 'active'

lock = threading.Lock()
S = {'hist': deque(maxlen=150), 'lat': None, 'lat_hist': deque(maxlen=100),
     'events': deque(maxlen=60), 'cpu': 0.0, 'up': None, 'up_since': time.time(),
     'down_since': None, 'total_down': 0.0, 'active': False}

def sampler():
    rx0, tx0 = net(); i0, t0 = cpu_times(); last = time.time(); pend = 0; n = 0
    while True:
        time.sleep(1)
        now = time.time(); dt = max(now - last, 0.001); last = now
        rx1, tx1 = net(); i1, t1 = cpu_times()
        rxr, txr = (rx1 - rx0) * 8 / dt, (tx1 - tx0) * 8 / dt
        cpu = 100 * (1 - (i1 - i0) / max(t1 - t0, 1))
        rx0, tx0, i0, t0 = rx1, tx1, i1, t1
        if n % 3 == 0:
            S['active'] = svc_active()
        n += 1
        tun, _ = conns()
        up = S['active'] and link_up()
        if n % 5 == 0: refresh_env()
        with lock:
            S['hist'].append([int(now), rxr, txr]); S['cpu'] = cpu
            if S['up'] is None:
                S['up'] = up; S['events'].appendleft([int(now), 'start' if up else 'down'])
                if not up: S['down_since'] = now
            elif up != S['up']:
                pend += 1
                if pend >= 3:  # debounce: 3s stable before changing state
                    pend = 0; S['up'] = up
                    S['events'].appendleft([int(now), 'up' if up else 'down'])
                    if up:
                        if S['down_since']: S['total_down'] += now - S['down_since']
                        S['down_since'] = None; S['up_since'] = now
                    else:
                        S['down_since'] = now
            else:
                pend = 0

def tcp_rtt(host, port):
    try:
        t = time.time()
        s = socket.create_connection((host, port), timeout=3)
        s.close()
        return (time.time() - t) * 1000
    except OSError:
        return None

def pinger():
    while True:
        tun, _ = conns()
        peer = PEER or (tun[0] if tun else '')
        lat = None
        if peer:
            m = re.search(r'time=([\d.]+)', sh(['ping', '-c1', '-W2', peer]))
            lat = float(m.group(1)) if m else None
            if lat is None and ROLE == 'kharej':   # ICMP blocked -> TCP handshake time
                lat = tcp_rtt(peer, TPORT)
        with lock:
            S['lat'] = lat; S['lat_hist'].append(lat)
        time.sleep(3)

def stats():
    tun, per = conns()
    mi = {}
    for l in open('/proc/meminfo'):
        k, v = l.split(':', 1); mi[k] = int(v.split()[0]) * 1024
    try:
        restarts = int(sh(['systemctl', 'show', 'overtun', '-p', 'NRestarts', '--value']).strip() or 0)
    except ValueError:
        restarts = 0
    rx, tx = net()
    now = time.time()
    with lock:
        down = S['total_down'] + ((now - S['down_since']) if S['down_since'] else 0)
        return {
            'role': ROLE, 'mode': cur_mode(), 'iface': IFACE, 'cores': os.cpu_count() or 1, 'link_mbps': LINK_MBPS, 'tport': TPORT, 'transport': TRANSPORT, 'up': bool(S['up']),
            'active': S['active'], 'tunnel_conns': len(tun), 'peer': PEER or (tun[0] if tun else ''),
            'ports': per, 'restarts': restarts,
            'up_for': (now - S['up_since']) if S['up'] else 0, 'total_down': down,
            'lat': S['lat'], 'lat_hist': list(S['lat_hist']), 'hist': list(S['hist']),
            'cpu': S['cpu'], 'load': open('/proc/loadavg').read().split()[:3],
            'mem_total': mi.get('MemTotal', 0), 'mem_used': mi.get('MemTotal', 0) - mi.get('MemAvailable', 0),
            'rx_total': rx, 'tx_total': tx, 'events': list(S['events']),
        }

HTML = r'''<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tunnel Monitor</title>
<style>
:root{--bg:#f3f5f9;--card:#ffffff;--bd:#e5e8ef;--tx:#1d2330;--mu:#7a8396;--track:#edf0f5;
--ok:#16a34a;--bad:#ef4444;--warn:#f59e0b;--dl:#3b82f6;--ul:#8b5cf6;--accent:#0f8a6b;
--shadow:0 1px 2px rgba(16,24,40,.04),0 6px 20px rgba(16,24,40,.06)}
:root[data-theme=dark]{--bg:#0a0e16;--card:#111725;--bd:#1e2738;--tx:#e6eaf2;--mu:#8691a8;--track:#1b2433;
--shadow:0 1px 2px rgba(0,0,0,.35),0 10px 28px rgba(0,0,0,.28)}
*{box-sizing:border-box}html,body{margin:0}
body{background:var(--bg);color:var(--tx);font:14px/1.6 Vazirmatn,"IRANSansX",Tahoma,system-ui,-apple-system,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased;transition:background .3s,color .3s}
.num{font-variant-numeric:tabular-nums;direction:ltr;unicode-bidi:isolate}
.top{position:sticky;top:0;z-index:5;display:flex;justify-content:space-between;align-items:center;gap:12px;padding:12px 22px;background:var(--bg);background:color-mix(in srgb,var(--bg) 82%,transparent);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);border-bottom:1px solid var(--bd)}
.brand{display:flex;align-items:center;gap:12px;min-width:0}
.logo{flex:none;width:42px;height:42px;border-radius:13px;background:linear-gradient(135deg,#0f8a6b,#22c55e);display:grid;place-items:center;color:#fff;box-shadow:0 6px 16px rgba(15,138,107,.35)}
h1{font-size:16px;margin:0;font-weight:800}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:3px}
.chip{font-size:11px;padding:1px 9px;border-radius:99px;background:var(--track);color:var(--mu)}
.actions{display:flex;gap:8px;flex:none}
button{font:inherit;cursor:pointer;border:1px solid var(--bd);background:var(--card);color:var(--tx);border-radius:11px;padding:7px 13px;white-space:nowrap;transition:transform .1s,border-color .15s,opacity .15s}
button:hover{border-color:var(--mu)}button:active{transform:scale(.97)}button:disabled{opacity:.6;cursor:wait}
.danger{background:var(--bad);border-color:var(--bad);color:#fff}
main{max-width:1180px;margin:0 auto;padding:20px 16px 30px;display:flex;flex-direction:column;gap:16px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:20px;box-shadow:var(--shadow);padding:18px 20px;transition:background .3s,border-color .3s}
h2{font-size:14px;margin:0;font-weight:800}
.card-h{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px;flex-wrap:wrap}
.status{display:flex;align-items:center;justify-content:space-between;gap:18px 30px;flex-wrap:wrap}
.st-main{display:flex;align-items:center;gap:16px}
.pulse{flex:none;width:14px;height:14px;border-radius:50%;background:var(--mu);position:relative}
.pulse::after{content:"";position:absolute;inset:-7px;border-radius:50%;border:2px solid currentColor;animation:p 1.8s ease-out infinite;opacity:0}
.pulse.ok{background:var(--ok);color:var(--ok)}.pulse.bad{background:var(--bad);color:var(--bad)}
@keyframes p{0%{transform:scale(.5);opacity:.9}100%{transform:scale(1.5);opacity:0}}
.st-title{font-size:18px;font-weight:800}.st-sub{color:var(--mu);font-size:12px}
.kpis{display:grid;grid-template-columns:repeat(5,auto);gap:10px 34px}
.kpi .l{font-size:11px;color:var(--mu)}.kpi .v{font-size:17px;font-weight:800}
.gauges{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}
.gauge{display:flex;flex-direction:column;align-items:center;padding:20px 12px 16px}
.gw{position:relative;width:156px;height:156px}
.g{width:100%;height:100%;display:block}
.g circle{fill:none;stroke-width:9;stroke-linecap:round}
.g .trk{stroke:var(--track)}
.g .val{transition:stroke-dashoffset .9s cubic-bezier(.2,.8,.2,1),stroke .4s}
.gc{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;padding-bottom:6px}
.gv{font-size:28px;font-weight:800;line-height:1.1}.gu{font-size:12px;color:var(--mu);font-weight:700}
.gl{margin-top:-10px;font-weight:800;font-size:14px}.gs{font-size:11.5px;color:var(--mu);margin-top:2px;text-align:center}
.legend{display:flex;gap:16px;font-size:12px;color:var(--mu);align-items:center;flex-wrap:wrap}
.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-left:6px;vertical-align:-1px}
.chartbox{position:relative;direction:ltr}
canvas{display:block;width:100%;touch-action:pan-y}#bw{height:250px}#lc{height:180px}
.tip{position:absolute;top:4px;pointer-events:none;background:var(--tx);color:var(--card);font-size:12px;line-height:1.7;padding:7px 11px;border-radius:10px;opacity:0;transition:opacity .15s;white-space:nowrap;direction:rtl;box-shadow:var(--shadow)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.prow{display:grid;grid-template-columns:62px 1fr 38px;align-items:center;gap:12px;padding:8px 0}
.bar{height:9px;background:var(--track);border-radius:99px;overflow:hidden}
.bar b{display:block;height:100%;width:0;background:linear-gradient(270deg,#0f8a6b,#22c55e);border-radius:99px;transition:width .7s cubic-bezier(.2,.8,.2,1)}
.tot{margin-top:14px;padding-top:12px;border-top:1px dashed var(--bd);font-size:12px;color:var(--mu);display:flex;gap:18px;flex-wrap:wrap}
.timeline{list-style:none;margin:0;padding:0;max-height:250px;overflow:auto}
.timeline li{display:flex;justify-content:space-between;gap:10px;padding:9px 0;border-bottom:1px dashed var(--bd);font-size:13px}
.timeline li:last-child{border:0}
.e{display:flex;align-items:center;gap:9px;font-weight:700}.e i{width:9px;height:9px;border-radius:50%}
.t{color:var(--mu);font-size:12px}
pre{margin:0;background:#0a0e16;color:#c9d1d9;border-radius:14px;padding:12px 14px;height:250px;overflow:auto;direction:ltr;text-align:left;font:11px/1.6 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-all}
.le{color:#f87171}.lw{color:#fbbf24}.lo{color:#4ade80}
.small{padding:4px 10px;font-size:12px}
.empty{color:var(--mu);font-size:13px;padding:10px 0}
footer{text-align:center;color:var(--mu);font-size:12px}
.live{display:inline-flex;align-items:center;gap:6px;font-size:11px;color:var(--ok);font-weight:700}
.live::before{content:"";width:7px;height:7px;border-radius:50%;background:var(--ok);animation:b 1.4s infinite}
@keyframes b{50%{opacity:.25}}
.mgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}
.mbox{border:1px solid var(--bd);border-radius:14px;padding:14px;display:flex;flex-direction:column;gap:10px;min-width:0}
.mbox.wide{grid-column:span 2}
.mt{font-weight:800;font-size:13px}.mh{font-size:11.5px;color:var(--mu)}
.mrow{display:flex;gap:8px;flex-wrap:wrap}.mrow .inp{flex:1;min-width:110px}
.okb{background:var(--accent);border-color:var(--accent);color:#fff}
.seg{display:flex;border:1px solid var(--bd);border-radius:11px;overflow:hidden}
.seg button{flex:1;border:0;border-radius:0;background:transparent;padding:8px 6px}
.seg button+button{border-inline-start:1px solid var(--bd)}
.seg button.on{background:var(--accent);color:#fff}
.inp{font:inherit;width:100%;background:var(--bg);color:var(--tx);border:1px solid var(--bd);border-radius:11px;padding:8px 11px;outline:none}
.inp:focus{border-color:var(--accent)}textarea.inp{resize:vertical;font-size:11px;direction:ltr;word-break:break-all}
.plist{display:flex;flex-wrap:wrap;gap:6px}
.pchip{display:inline-flex;align-items:center;gap:4px;background:var(--track);border-radius:99px;padding:3px 12px 3px 4px;font-size:13px;font-weight:700}
.pchip.perr{background:color-mix(in srgb,var(--bad) 18%,transparent);color:var(--bad)}.pchip button{border:0;background:transparent;padding:0 6px;color:var(--bad);font-size:14px;line-height:1.4}
pre.mout{margin-top:12px;height:auto;max-height:180px}pre.mout.ok{color:#4ade80}pre.mout.err{color:#f87171}
body.busy .mbox button{pointer-events:none;opacity:.55}
.ir-only,.kh-only{display:none!important}
body.r-iran .ir-only,body.r-kharej .kh-only{display:flex!important}
@media(max-width:920px){.mgrid{grid-template-columns:1fr 1fr}}
@media(max-width:540px){.mgrid{grid-template-columns:1fr}.mbox.wide{grid-column:auto}}
.toast{position:fixed;bottom:20px;left:50%;transform:translate(-50%,20px);background:var(--tx);color:var(--card);padding:9px 16px;border-radius:12px;font-size:13px;opacity:0;transition:.25s;pointer-events:none;z-index:9}
.toast.show{opacity:1;transform:translate(-50%,0)}
@media(max-width:920px){.gauges{grid-template-columns:repeat(2,1fr)}.grid2{grid-template-columns:1fr}.kpis{grid-template-columns:repeat(3,auto)}}
@media(max-width:540px){.top{padding:10px 14px}.chips .chip:nth-child(n+3){display:none}.gw{width:132px;height:132px}.gv{font-size:23px}
 .kpis{grid-template-columns:repeat(2,1fr);width:100%}.gauges{gap:12px}.card{padding:16px}#bw{height:210px}.hide-sm{display:none}main{padding:14px 12px 24px;gap:12px}}
</style></head><body>
<header class="top">
 <div class="brand">
  <div class="logo"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="5" cy="12" r="2.5"/><circle cx="19" cy="12" r="2.5"/><path d="M7.5 12h9M14 8.5l2.5 3.5-2.5 3.5"/></svg></div>
  <div style="min-width:0"><h1>مانیتورینگ تانل</h1><div class="chips" id="chips"></div></div>
 </div>
 <div class="actions">
  <button id="themeBtn" title="تغییر تم" aria-label="تغییر تم" style="display:grid;place-items:center;padding:7px 10px"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg></button>
  <button onclick="$('mgmt').scrollIntoView({behavior:'smooth'})" title="مدیریت">⚙ <span class="hide-sm">مدیریت</span></button>
  <button class="danger" id="rsBtn" onclick="restart()">⟳ <span class="hide-sm">ری‌استارت تانل</span></button>
  <button id="outBtn" onclick="logout()" title="خروج" aria-label="خروج" style="display:grid;place-items:center;padding:7px 10px"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg></button>
 </div>
</header>
<main>
 <section class="card status">
  <div class="st-main"><span class="pulse" id="pulse"></span><div><div class="st-title" id="stTitle">در حال بارگذاری…</div><div class="st-sub" id="stSub"></div></div></div>
  <div class="kpis">
   <div class="kpi"><div class="l">پینگ</div><div class="v num" id="kPing">—</div></div>
   <div class="kpi"><div class="l">مدت اتصال</div><div class="v num" id="kUp">—</div></div>
   <div class="kpi"><div class="l">کاربران فعال</div><div class="v num" id="kConn">—</div></div>
   <div class="kpi"><div class="l">ری‌استارت</div><div class="v num" id="kRs">—</div></div>
   <div class="kpi"><div class="l">کل قطعی</div><div class="v num" id="kDown">—</div></div>
  </div>
 </section>
 <section class="gauges" id="gauges"></section>
 <section class="card">
  <div class="card-h"><h2>ترافیک زنده</h2>
   <div class="legend"><span><i style="background:var(--dl)"></i>دانلود</span><span><i style="background:var(--ul)"></i>آپلود</span><span class="live">LIVE</span></div></div>
  <div class="chartbox"><canvas id="bw"></canvas><div class="tip" id="tip"></div></div>
 </section>
 <section class="grid2">
  <div class="card"><div class="card-h"><h2>پینگ تا سرور مقابل</h2><span class="t num" id="pingAvg"></span></div><div class="chartbox"><canvas id="lc"></canvas></div></div>
  <div class="card"><div class="card-h"><h2>اتصال‌های فعال هر پورت</h2></div><div id="ports"></div><div class="tot" id="tot"></div></div>
 </section>
 <section class="grid2">
  <div class="card"><div class="card-h"><h2>رویدادها</h2></div><ul class="timeline" id="ev"></ul></div>
  <div class="card"><div class="card-h"><h2>لاگ‌ها</h2><button class="small" onclick="logs()">بروزرسانی</button></div><pre id="lg"></pre></div>
 </section>
 <section class="card" id="mgmt">
  <div class="card-h"><h2>مدیریت تانل</h2><span class="chip" id="mRole"></span></div>
  <div class="mgrid">
   <div class="mbox"><div class="mt">کنترل تانل</div>
    <div class="mrow"><button onclick="act('restart',[],'تانل ری‌استارت شود؟')">⟳ ری‌استارت</button>
     <button onclick="act('stop',[],'تانل متوقف شود؟ همه کاربران قطع می‌شوند.')">■ توقف</button>
     <button class="okb" onclick="act('start',[])">▶ شروع</button></div>
    <div class="mh">توقف موقت است و با «شروع» دوباره وصل می‌شود.</div></div>
   <div class="mbox"><div class="mt">حالت سرعت</div>
    <div class="seg" id="segMode"><button data-v="medium">Medium</button><button data-v="turbo">Turbo ⚡</button><button data-v="advanced">Advanced 🚀</button></div>
    <div class="mh">روی سرور دیگر هم همین حالت را انتخاب کنید.</div></div>
   <div class="mbox"><div class="mt">پورت‌های تانل</div>
    <div class="plist" id="pList"></div>
    <div class="mrow"><input id="pIn" class="inp num" inputmode="numeric" placeholder="مثلاً 2053"><button class="okb" onclick="addPort()">+ افزودن</button></div>
    <div class="mh">پورت را روی <b>هر دو سرور</b> اضافه یا حذف کنید.</div></div>
   <div class="mbox kh-only"><div class="mt">روش تانل</div>
    <div class="seg" id="segMethod"><button data-v="wss">WSS</button><button data-v="tls">TLS · سریع‌تر</button></div>
    <div class="mh">فقط روی سرور خارج تغییر دهید؛ سرور ایران هر دو را می‌پذیرد.</div></div>
   <div class="mbox kh-only wide"><div class="mt">اتصال مجدد با کد جدید</div>
    <input id="rcIp" class="inp num" placeholder="IP سرور ایران">
    <textarea id="rcCode" class="inp num" rows="3" placeholder="کد اتصال از سرور ایران"></textarea>
    <div class="mrow"><button class="okb" onclick="reconnect()">اتصال</button></div></div>
   <div class="mbox ir-only wide"><div class="mt">کد اتصال (برای سرور خارج)</div>
    <textarea id="codeBox" class="inp num" rows="3" readonly></textarea>
    <div class="mrow"><button onclick="copyCode()">کپی کد</button></div>
    <div class="mh">این کد مثل رمز تانل است؛ جای عمومی نفرستید.</div></div>
   <div class="mbox"><div class="mt">تغییر رمز پنل</div>
    <input id="pwOld" type="password" class="inp" placeholder="رمز فعلی" autocomplete="current-password">
    <input id="pwNew" type="password" class="inp" placeholder="رمز جدید (حداقل ۸ کاراکتر)" autocomplete="new-password">
    <div class="mrow"><button class="okb" onclick="changePw()">ذخیره رمز</button></div></div>
  </div>
  <pre id="mOut" class="mout" hidden></pre>
 </section>
 <footer>بروزرسانی زنده هر ۱ ثانیه</footer>
</main>
<div class="toast" id="toast"></div>
<script>
const $=id=>document.getElementById(id),root=document.documentElement;
const C=2*Math.PI*50,A=C*.75;
const css=v=>getComputedStyle(root).getPropertyValue(v).trim();
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
let th=null;try{th=localStorage.getItem('theme')}catch(e){}
root.dataset.theme=th||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');
$('themeBtn').onclick=()=>{root.dataset.theme=root.dataset.theme=='dark'?'light':'dark';try{localStorage.setItem('theme',root.dataset.theme)}catch(e){}redraw()};

function bits(v){const u=['bps','Kbps','Mbps','Gbps'];let i=0;v=Math.max(0,v||0);while(v>=1000&&i<3){v/=1000;i++}return[v,u[i]]}
const nfix=v=>v.toFixed(v<10?2:v<100?1:0);
const bitsStr=v=>{const[n,u]=bits(v);return(u=='bps'?n.toFixed(0):nfix(n))+' '+u};
const fB=v=>{const u=['B','KB','MB','GB','TB'];let i=0;while(v>=1024&&i<4){v/=1024;i++}return v.toFixed(1)+' '+u[i]};
const fd=s=>{s=Math.floor(s);const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60),x=s%60;return d?d+'d '+h+'h':h?h+'h '+m+'m':m?m+'m '+x+'s':x+'s'};
const ago=t=>{const s=Math.max(0,Date.now()/1000-t);return s<60?'همین الان':s<3600?Math.floor(s/60)+' دقیقه پیش':s<86400?Math.floor(s/3600)+' ساعت پیش':Math.floor(s/86400)+' روز پیش'};

/* ---------- gauges ---------- */
const G=[['cpu','پردازنده (CPU)'],['ram','حافظه (RAM)'],['dl','دانلود'],['ul','آپلود']];
$('gauges').innerHTML=G.map(([k,t])=>`<div class="card gauge"><div class="gw"><svg class="g" viewBox="0 0 120 120">
<circle class="trk" cx="60" cy="60" r="50" stroke-dasharray="${A} ${C}" transform="rotate(135 60 60)"/>
<circle class="val" id="${k}A" cx="60" cy="60" r="50" stroke-dasharray="${A} ${C}" stroke-dashoffset="${A}" transform="rotate(135 60 60)"/></svg>
<div class="gc"><div class="gv num" id="${k}V">0</div><div class="gu num" id="${k}U">&nbsp;</div></div></div>
<div class="gl">${t}</div><div class="gs" id="${k}S">&nbsp;</div></div>`).join('');
const clamp=p=>Math.max(0,Math.min(1,p||0));
function arc(k,p,col){const e=$(k+'A');e.style.strokeDashoffset=A*(1-clamp(p));e.style.stroke=col}
const level=p=>p<.6?css('--accent'):p<.85?css('--warn'):css('--bad');
const cur={},raf={};
function tween(k,to,fn){const from=cur[k]??to,t0=performance.now();cancelAnimationFrame(raf[k]);
 const st=n=>{const p=Math.min((n-t0)/800,1),v=from+(to-from)*(1-Math.pow(1-p,3));cur[k]=v;fn(v);if(p<1)raf[k]=requestAnimationFrame(st)};raf[k]=requestAnimationFrame(st)}

/* ---------- charts ---------- */
function niceMax(v){if(!(v>0))return 1;const e=Math.pow(10,Math.floor(Math.log10(v))),m=v/e;return(m<=1?1:m<=2?2:m<=2.5?2.5:m<=5?5:10)*e}
function area(cv,series,colors,fmtY,hi){
 const dpr=window.devicePixelRatio||1,w=cv.clientWidth,h=cv.clientHeight;
 if(cv.width!=Math.round(w*dpr)||cv.height!=Math.round(h*dpr)){cv.width=Math.round(w*dpr);cv.height=Math.round(h*dpr)}
 const c=cv.getContext('2d');c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,w,h);
 const L=66,R=6,T=10,B=8,pw=w-L-R,ph=h-T-B;
 let mx=0;series.forEach(s=>s.forEach(v=>{if(v!=null&&v>mx)mx=v}));mx=niceMax(mx*1.1);
 const grid=css('--bd'),mu=css('--mu');c.font='11px system-ui,sans-serif';c.textBaseline='middle';c.textAlign='right';
 for(let i=0;i<=4;i++){const y=T+ph-ph*i/4;c.strokeStyle=grid;c.lineWidth=1;c.setLineDash(i?[3,5]:[]);c.beginPath();c.moveTo(L,y);c.lineTo(w-R,y);c.stroke();c.setLineDash([]);c.fillStyle=mu;c.fillText(fmtY(mx*i/4),L-10,y)}
 const n=Math.max(1,...series.map(s=>s.length)),X=i=>L+pw*(n<=1?1:i/(n-1)),Y=v=>T+ph-ph*v/mx;
 series.forEach((s,k)=>{const col=colors[k],segs=[];let sg=[];
  s.forEach((v,i)=>{if(v==null){if(sg.length)segs.push(sg);sg=[]}else sg.push([X(i),Y(v)])});if(sg.length)segs.push(sg);
  segs.forEach(sg=>{const p=new Path2D();p.moveTo(sg[0][0],sg[0][1]);
   for(let i=1;i<sg.length;i++){const[x0,y0]=sg[i-1],[x1,y1]=sg[i],m=(x0+x1)/2;p.bezierCurveTo(m,y0,m,y1,x1,y1)}
   const f=new Path2D(p);f.lineTo(sg[sg.length-1][0],T+ph);f.lineTo(sg[0][0],T+ph);f.closePath();
   const g=c.createLinearGradient(0,T,0,T+ph);g.addColorStop(0,col+'4d');g.addColorStop(1,col+'00');c.fillStyle=g;c.fill(f);
   c.strokeStyle=col;c.lineWidth=2.2;c.lineJoin='round';c.stroke(p)});
  const lv=s[s.length-1];if(lv!=null&&hi==null){c.fillStyle=col;c.beginPath();c.arc(X(s.length-1),Y(lv),3.5,0,7);c.fill()}});
 if(!series.some(s=>s.some(v=>v!=null))){c.textAlign='center';c.fillStyle=mu;c.font='13px Tahoma,system-ui,sans-serif';c.fillText('داده‌ای برای نمایش نیست',L+pw/2,T+ph/2)}
 if(hi!=null){const x=X(hi);c.strokeStyle=mu;c.setLineDash([4,4]);c.beginPath();c.moveTo(x,T);c.lineTo(x,T+ph);c.stroke();c.setLineDash([]);
  series.forEach((s,k)=>{const v=s[hi];if(v==null)return;c.fillStyle=css('--card');c.strokeStyle=colors[k];c.lineWidth=2.5;c.beginPath();c.arc(x,Y(v),4.5,0,7);c.fill();c.stroke()})}
 return{X,n,L,pw}}
let D=null,hover=null,geo=null;const bw=$('bw');
function drawBW(){if(D)geo=area(bw,[D.hist.map(x=>x[1]),D.hist.map(x=>x[2])],[css('--dl'),css('--ul')],bitsStr,hover)}
function drawLat(){if(D)area($('lc'),[D.lat_hist],[css('--accent')],v=>v.toFixed(v<10?1:0)+' ms',null)}
function redraw(){drawBW();drawLat()}
function showTip(){if(!D||!geo||hover==null)return;const p=D.hist[hover];if(!p)return;const tip=$('tip');
 tip.innerHTML=`<b>${new Date(p[0]*1000).toLocaleTimeString('fa-IR')}</b><br><span style="color:var(--dl)">●</span> دانلود: <span class="num">${bitsStr(p[1])}</span><br><span style="color:var(--ul)">●</span> آپلود: <span class="num">${bitsStr(p[2])}</span>`;
 tip.style.opacity=1;const x=geo.X(hover),W=bw.clientWidth;tip.style.left=Math.min(Math.max(x-tip.offsetWidth/2,0),W-tip.offsetWidth)+'px'}
function onMove(e){if(!geo)return;const r=bw.getBoundingClientRect(),cx=(e.touches?e.touches[0].clientX:e.clientX)-r.left;
 hover=Math.max(0,Math.min(geo.n-1,Math.round((cx-geo.L)/geo.pw*(geo.n-1))));drawBW();showTip()}
function onLeave(){hover=null;$('tip').style.opacity=0;drawBW()}
bw.addEventListener('mousemove',onMove);bw.addEventListener('mouseleave',onLeave);
bw.addEventListener('touchstart',onMove,{passive:true});bw.addEventListener('touchmove',onMove,{passive:true});bw.addEventListener('touchend',()=>setTimeout(onLeave,1500));
if(window.ResizeObserver)new ResizeObserver(redraw).observe($('bw').parentNode);else addEventListener('resize',redraw);

/* ---------- update ---------- */
function setStatus(ok,title,sub){$('pulse').className='pulse '+(ok?'ok':'bad');$('stTitle').textContent=title;$('stTitle').style.color=ok?'':'var(--bad)';$('stSub').textContent=sub||''}
function render(d){
 D=d;
 $('chips').innerHTML=[d.role=='iran'?'سرور ایران':'سرور خارج',({medium:'Medium',turbo:'Turbo ⚡',advanced:'Advanced 🚀'})[d.mode]||d.mode,d.transport.toUpperCase(),'Tunnel :'+d.tport,d.peer?'⇄ '+d.peer:'',d.iface].filter(Boolean).map(x=>`<span class="chip"><bdi>${esc(x)}</bdi></span>`).join('');
 if(d.up)setStatus(true,'تانل متصل و پایدار است','وصل از '+new Date(Date.now()-d.up_for*1000).toLocaleString('fa-IR'));
 else setStatus(false,d.active?'تانل قطع است — در حال اتصال مجدد…':'سرویس تانل خاموش است','');
 const pe=$('kPing');pe.textContent=d.lat==null?'—':d.lat.toFixed(d.lat<10?1:0)+' ms';pe.style.color=d.lat==null?'':d.lat>150?'var(--warn)':'var(--ok)';
 const users=Object.values(d.ports).reduce((a,b)=>a+b,0);
 $('kUp').textContent=d.up?fd(d.up_for):'—';$('kConn').textContent=users;$('kRs').textContent=d.restarts;$('kDown').textContent=fd(d.total_down);

 tween('cpu',d.cpu,v=>{$('cpuV').textContent=v.toFixed(0)});$('cpuU').textContent='%';arc('cpu',d.cpu/100,level(d.cpu/100));
 $('cpuS').innerHTML=`${d.cores} هسته · Load <span class="num">${d.load[0]}</span>`;
 const rp=d.mem_total?d.mem_used/d.mem_total*100:0;
 tween('ram',rp,v=>{$('ramV').textContent=v.toFixed(0)});$('ramU').textContent='%';arc('ram',rp/100,level(rp/100));
 $('ramS').innerHTML=`<span class="num">${fB(d.mem_used)} / ${fB(d.mem_total)}</span>`;
 const last=d.hist[d.hist.length-1]||[0,0,0];
 let peak=0;d.hist.forEach(x=>{peak=Math.max(peak,x[1],x[2])});
 const scale=d.link_mbps>0?d.link_mbps*1e6:Math.max(niceMax(peak*1.1),10e6);
 [['dl',1,'--dl'],['ul',2,'--ul']].forEach(([k,i,c])=>{
  tween(k,last[i],v=>{const[n,u]=bits(v);$(k+'V').textContent=u=='bps'?n.toFixed(0):nfix(n);$(k+'U').textContent=u});
  arc(k,last[i]/scale,css(c));
  let pk=0;d.hist.forEach(x=>{pk=Math.max(pk,x[i])});
  $(k+'S').innerHTML=(d.link_mbps>0?'ظرفیت ':'پیک ۲.۵ دقیقه: ')+`<span class="num">${bitsStr(d.link_mbps>0?scale:pk)}</span>`});

 const ps=Object.entries(d.ports),pm=Math.max(1,...ps.map(p=>p[1])),box=$('ports'),key=ps.map(p=>p[0]).join();
 if(box.dataset.k!==key){box.dataset.k=key;box.innerHTML=ps.length?ps.map(([p])=>`<div class="prow"><span class="num">:${p}</span><div class="bar"><b id="pb${p}"></b></div><span class="num" id="pn${p}">0</span></div>`).join(''):'<div class="empty">پورتی تعریف نشده</div>'}
 ps.forEach(([p,n])=>{$('pb'+p).style.width=(n/pm*100)+'%';$('pn'+p).textContent=n});
 $('tot').innerHTML=`<span>کل ترافیک از زمان بوت</span><span>↓ <b class="num">${fB(d.rx_total)}</b></span><span>↑ <b class="num">${fB(d.tx_total)}</b></span>`;
 const lv=d.lat_hist.filter(v=>v!=null);$('pingAvg').textContent=lv.length?'avg '+(lv.reduce((a,b)=>a+b,0)/lv.length).toFixed(1)+' ms':'';

 const EV={start:['پایش شروع شد','var(--dl)'],up:['تانل وصل شد','var(--ok)'],down:['تانل قطع شد','var(--bad)']};
 $('ev').innerHTML=d.events.length?d.events.map(([t,k])=>`<li><span class="e"><i style="background:${EV[k][1]}"></i>${EV[k][0]}</span><span class="t">${ago(t)} · ${new Date(t*1000).toLocaleTimeString('fa-IR')}</span></li>`).join(''):'<li class="empty">رویدادی ثبت نشده</li>';
 if(hover==null)drawBW();else{drawBW();showTip()}drawLat();
}
async function tick(){
 try{const r=await fetch('api/stats',{cache:'no-store'});if(r.status==401){location.href='login';return}if(!r.ok)throw 0;render(await r.json())}
 catch(e){setStatus(false,'ارتباط با پنل برقرار نیست','بررسی اتصال اینترنت یا سرویس پنل')}
 setTimeout(tick,1000)}
async function logs(){try{const d=await(await fetch('api/logs',{cache:'no-store'})).json();
 const el=$('lg');el.innerHTML=esc(d.logs||'-').split('\n').map(l=>/ERROR/.test(l)?`<span class="le">${l}</span>`:/WARN/.test(l)?`<span class="lw">${l}</span>`:/established/.test(l)?`<span class="lo">${l}</span>`:l).join('\n');el.scrollTop=1e9}catch(e){}}
function toast(m){const t=$('toast');t.textContent=m;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),2500)}
let CFG=null;
async function api(path,body){const r=await fetch(path,{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify(body||{})});
 if(r.status==401){location.href='login';throw 0}return r.json()}
function showOut(t,ok){const o=$('mOut');o.hidden=false;o.className='mout '+(ok?'ok':'err');o.textContent=t}
async function act(action,args,ask){if(ask&&!confirm(ask))return false;document.body.classList.add('busy');showOut('در حال اجرا…',true);let ok=false;
 try{const d=await api('api/manage',{action,args});ok=d.ok;showOut(d.output,d.ok);toast(d.ok?'انجام شد ✅':'انجام نشد ❌')}catch(e){if(e!==0)toast('خطا در ارتباط با پنل')}
 document.body.classList.remove('busy');loadCfg();logs();return ok}
function restart(){act('restart',[],'تانل ری‌استارت شود؟')}
async function loadCfg(){try{const r=await fetch('api/config',{cache:'no-store'});if(r.status==401){location.href='login';return}const c=await r.json();CFG=c;
 document.body.classList.toggle('r-iran',c.role=='iran');document.body.classList.toggle('r-kharej',c.role=='kharej');
 $('mRole').textContent=c.role=='iran'?'سرور ایران':'سرور خارج';
 document.querySelectorAll('#segMode button').forEach(b=>b.classList.toggle('on',b.dataset.v==c.mode));
 document.querySelectorAll('#segMethod button').forEach(b=>b.classList.toggle('on',b.dataset.v==c.transport));
 const ps=c.pstatus||{};$('pList').innerHTML=c.ports.length?c.ports.map(p=>`<span class="pchip num${ps[p]?' perr':''}" title="${ps[p]?esc(ps[p]=='port not allowed'?'این پورت روی سرور ایران اضافه نشده':ps[p]):'فعال'}">${p}<button title="حذف" onclick="delPort(${p})">✕</button></span>`).join(''):'<span class="mh">پورتی تعریف نشده</span>';
 if(c.role=='iran')$('codeBox').value=c.code||'';
 if(c.role=='kharej'&&!$('rcIp').value)$('rcIp').value=c.peer||'';
}catch(e){}}
document.querySelectorAll('#segMode button').forEach(b=>b.onclick=()=>{if(CFG&&b.dataset.v!=CFG.mode)act('mode',[b.dataset.v],'حالت سرعت '+b.textContent+' شود؟ تانل حدود ۱ ثانیه قطع و وصل می‌شود.')});
document.querySelectorAll('#segMethod button').forEach(b=>b.onclick=()=>{if(CFG&&b.dataset.v!=CFG.transport)act('method',[b.dataset.v],'روش تانل '+b.textContent+' شود؟')});
async function addPort(){const v=$('pIn').value.trim();if(!/^\d{1,5}$/.test(v)){toast('پورت نامعتبر است');return}if(await act('port-add',[v],'پورت '+v+' اضافه شود؟'))$('pIn').value=''}
$('pIn').addEventListener('keydown',e=>{if(e.key=='Enter')addPort()});
function delPort(p){act('port-del',[String(p)],'پورت '+p+' حذف شود؟ کاربرانی که از این پورت استفاده می‌کنند قطع می‌شوند.')}
async function reconnect(){const ip=$('rcIp').value.trim(),code=$('rcCode').value.replace(/\s+/g,'');if(!ip||!code){toast('IP و کد اتصال را وارد کنید');return}
 if(await act('reconnect',[ip,code],'تانل با این کد دوباره وصل شود؟'))$('rcCode').value=''}
function copyCode(){const t=$('codeBox');t.select();const done=()=>toast('کد کپی شد ✅');
 if(navigator.clipboard&&window.isSecureContext)navigator.clipboard.writeText(t.value).then(done,()=>{document.execCommand('copy');done()});else{document.execCommand('copy');done()}}
async function changePw(){const o=$('pwOld').value,n=$('pwNew').value;if(n.length<8){toast('رمز جدید حداقل ۸ کاراکتر');return}
 try{const d=await api('api/password',{old:o,new:n});showOut(d.output,d.ok);toast(d.ok?'رمز تغییر کرد ✅':'انجام نشد ❌');if(d.ok){$('pwOld').value='';$('pwNew').value=''}}catch(e){}}
async function logout(){try{await api('api/logout')}catch(e){}location.href='login'}

tick();logs();loadCfg();setInterval(logs,15000);
</script></body></html>'''

LOGIN_HTML = r'''<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Sign in</title>
<style>
:root{--bg:#f3f5f9;--card:#fff;--bd:#e5e8ef;--tx:#1d2330;--mu:#7a8396;--accent:#0f8a6b;--bad:#ef4444;--shadow:0 10px 40px rgba(16,24,40,.10)}
:root[data-theme=dark]{--bg:#0a0e16;--card:#111725;--bd:#1e2738;--tx:#e6eaf2;--mu:#8691a8;--shadow:0 10px 40px rgba(0,0,0,.45)}
*{box-sizing:border-box}html,body{margin:0;height:100%}
body{background:var(--bg);color:var(--tx);font:14px/1.6 Vazirmatn,Tahoma,system-ui,sans-serif;display:grid;place-items:center;padding:16px}
.box{width:100%;max-width:380px;background:var(--card);border:1px solid var(--bd);border-radius:22px;box-shadow:var(--shadow);padding:30px 26px}
.logo{width:54px;height:54px;border-radius:16px;margin:0 auto 14px;background:linear-gradient(135deg,#0f8a6b,#22c55e);display:grid;place-items:center;color:#fff;box-shadow:0 8px 22px rgba(15,138,107,.35)}
h1{font-size:19px;text-align:center;margin:0 0 4px}.sub{text-align:center;color:var(--mu);font-size:12.5px;margin-bottom:22px}
label{display:block;font-size:12.5px;color:var(--mu);margin:12px 0 6px}
input{font:inherit;width:100%;background:var(--bg);color:var(--tx);border:1px solid var(--bd);border-radius:12px;padding:11px 13px;outline:none;direction:ltr;text-align:left}
input:focus{border-color:var(--accent)}
button{font:inherit;width:100%;margin-top:20px;background:var(--accent);color:#fff;border:0;border-radius:12px;padding:12px;font-weight:800;cursor:pointer}
button:disabled{opacity:.6;cursor:wait}
.err{min-height:22px;margin-top:12px;color:var(--bad);font-size:12.5px;text-align:center}
</style></head><body>
<form class="box" id="f" autocomplete="on">
 <div class="logo"><svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="5" cy="12" r="2.5"/><circle cx="19" cy="12" r="2.5"/><path d="M7.5 12h9M14 8.5l2.5 3.5-2.5 3.5"/></svg></div>
 <h1>ورود به پنل تانل</h1><div class="sub">Over-Tun</div>
 <label for="u">نام کاربری</label><input id="u" name="username" autocomplete="username" required>
 <label for="p">رمز عبور</label><input id="p" name="password" type="password" autocomplete="current-password" required>
 <button id="b" type="submit">ورود</button>
 <div class="err" id="e"></div>
</form>
<script>
let th=null;try{th=localStorage.getItem('theme')}catch(e){}
document.documentElement.dataset.theme=th||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');
const $=id=>document.getElementById(id);$('u').focus();
$('f').onsubmit=async ev=>{ev.preventDefault();$('b').disabled=true;$('e').textContent='';
 try{const r=await fetch('api/login',{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify({user:$('u').value.trim(),pass:$('p').value})});
  const d=await r.json().catch(()=>({}));
  if(r.ok){location.href='./';return}
  if(r.status==429)$('e').textContent='به دلیل تلاش‌های ناموفق، ورود تا '+Math.ceil((d.wait||600)/60)+' دقیقه قفل است.';
  else $('e').textContent='نام کاربری یا رمز اشتباه است'+(d.left!=null?' ('+d.left+' تلاش باقی‌مانده)':'');
 }catch(e){$('e').textContent='ارتباط با سرور برقرار نشد'}
 $('b').disabled=false;$('p').value='';$('p').focus()};
</script></body></html>
'''

class H(BaseHTTPRequestHandler):
    server_version = 'nginx'
    sys_version = ''
    def log_message(self, *a):
        pass
    def _send(self, code, body, ctype, headers=()):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        for k, v in headers: self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)
    def _json(self, code, obj, headers=()):
        self._send(code, json.dumps(obj), 'application/json', headers)
    def _token(self):
        try:
            c = SimpleCookie(self.headers.get('Cookie', ''))
            return c['ot'].value if 'ot' in c else ''
        except Exception:
            return ''
    def _authed(self):
        t, now = self._token(), time.time()
        if not t: return False
        with SL:
            exp = SESS.get(t)
            if exp and exp > now:
                SESS[t] = now + SESSION_TTL
                return True
            SESS.pop(t, None)
        return False
    def _body(self):
        try:
            n = int(self.headers.get('Content-Length') or 0)
            return json.loads(self.rfile.read(n) or b'{}') if 0 < n <= 20000 else {}
        except Exception:
            return {}
    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/login':
            return self._send(200, LOGIN_HTML, 'text/html; charset=utf-8')
        if not self._authed():
            if p.startswith('/api/'): return self._json(401, {'error': 'auth'})
            return self._send(302, b'', 'text/plain', [('Location', 'login')])
        if p == '/':
            self._send(200, HTML, 'text/html; charset=utf-8')
        elif p == '/api/stats':
            self._json(200, stats())
        elif p == '/api/config':
            self._json(200, config_info())
        elif p == '/api/logs':
            out = sh(['journalctl', '-u', 'overtun', '-n', '40', '--no-pager', '-o', 'short-iso'])
            self._json(200, {'logs': out})
        else:
            self._send(404, 'not found', 'text/plain')
    def do_HEAD(self):
        self._send(200, b'', 'text/html; charset=utf-8')
    def do_POST(self):
        global PWHASH
        p = self.path.split('?')[0]
        if self.headers.get('X-Req') != '1':
            return self._send(403, 'forbidden', 'text/plain')
        if p == '/api/login':
            ip, now, d = self.client_address[0], time.time(), self._body()
            with SL:
                cnt, first = FAILS.get(ip, (0, now))
                if now - first > 600: cnt, first = 0, now
                if cnt >= 5:
                    return self._json(429, {'error': 'locked', 'wait': int(600 - (now - first))})
            if hmac.compare_digest(str(d.get('user', '')), USER) and check_pw(str(d.get('pass', ''))):
                t = secrets.token_urlsafe(32)
                with SL:
                    FAILS.pop(ip, None)
                    for k in [k for k, v in SESS.items() if v < now]: SESS.pop(k, None)
                    SESS[t] = now + SESSION_TTL
                return self._json(200, {'ok': True}, [('Set-Cookie', f'ot={t}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}')])
            with SL:
                FAILS[ip] = (cnt + 1, first)
            time.sleep(0.7)
            return self._json(401, {'error': 'bad', 'left': max(0, 4 - cnt)})
        if not self._authed():
            return self._json(401, {'error': 'auth'})
        if p == '/api/logout':
            with SL: SESS.pop(self._token(), None)
            return self._json(200, {'ok': True}, [('Set-Cookie', 'ot=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict')])
        if p == '/api/manage':
            d = self._body()
            ok, out = manage(str(d.get('action', '')), d.get('args') or [])
            return self._json(200, {'ok': ok, 'output': out})
        if p == '/api/password':
            d = self._body()
            if not check_pw(str(d.get('old', ''))):
                return self._json(200, {'ok': False, 'output': 'رمز فعلی اشتباه است'})
            new = str(d.get('new', ''))
            if len(new) < 8:
                return self._json(200, {'ok': False, 'output': 'رمز جدید باید حداقل ۸ کاراکتر باشد'})
            PWHASH = make_hash(new)
            save_web('WEB_HASH', PWHASH)
            with SL:
                keep = self._token()
                for k in [k for k in SESS if k != keep]: SESS.pop(k, None)
            return self._json(200, {'ok': True, 'output': 'رمز پنل تغییر کرد'})
        if p == '/api/restart':
            ok, out = manage('restart', [])
            return self._json(200, {'ok': ok, 'output': out})
        self._send(404, 'not found', 'text/plain')

if __name__ == '__main__':
    threading.Thread(target=sampler, daemon=True).start()
    threading.Thread(target=pinger, daemon=True).start()
    srv = ThreadingHTTPServer(('0.0.0.0', LISTEN), H)
    srv.daemon_threads = True
    srv.serve_forever()
PYEOF
  chmod +x /usr/local/bin/overtun-web.py

  cat > /etc/systemd/system/overtun-web.service <<'EOF'
[Unit]
Description=Over-Tun Web Monitor
After=network-online.target overtun.service
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/env python3 /usr/local/bin/overtun-web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable overtun-web >/dev/null 2>&1
  systemctl restart overtun-web
  sleep 2
  if systemctl is-active --quiet overtun-web; then
    IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GRN}Web monitor is running${NC}"
    echo -e "URL:      ${YEL}http://$IP:$WP${NC}"
    echo -e "Username: ${YEL}$WU${NC}"
    echo -e "Password: ${YEL}$WPASS${NC}"
  else
    echo -e "${RED}Web monitor failed to start:${NC}"
    journalctl -u overtun-web -n 15 --no-pager
  fi
}

remove_web() {
  systemctl disable --now overtun-web 2>/dev/null
  rm -f /etc/systemd/system/overtun-web.service /usr/local/bin/overtun-web.py $CONF_DIR/web.conf
  systemctl daemon-reload
  echo -e "${GRN}Web monitor removed.${NC}"
}


uninstall() {
  read -rp "Remove the tunnel and all its settings from this server? [y/N]: " y
  [[ $y =~ ^[Yy]$ ]] || { echo "Cancelled."; return; }
  remove_web >/dev/null 2>&1
  systemctl disable --now $SVC_NAME overtun-watchdog.timer 2>/dev/null
  rm -f $SVC /etc/systemd/system/overtun-watchdog.* /usr/local/bin/overtun-watchdog.sh
  /usr/local/bin/overtun-nic.sh medium >/dev/null 2>&1
  rm -rf $CONF_DIR /usr/local/bin/frps /usr/local/bin/frpc /etc/sysctl.d/99-tunnel.conf $DROPIN_DIR /usr/local/bin/overtun-nic.sh
  cleanup_legacy >/dev/null 2>&1
  systemctl daemon-reload
  echo -e "${GRN}Tunnel removed. To install again run: over-tun${NC}"
}

# ---------- "over-tun" command ----------
install_cmd() {
  local src; src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
  if [[ -f $src && $src != "$(readlink -f $CMD 2>/dev/null)" ]]; then
    cp -f "$src" $CMD                                   # run from a local file
  elif [[ ! -f $src ]]; then                            # run via: bash <(curl ...)
    curl -fsSL --connect-timeout 8 "$REPO_RAW" -o $CMD.tmp 2>/dev/null && [[ -s $CMD.tmp ]] && mv -f $CMD.tmp $CMD
    rm -f $CMD.tmp
  fi
  [[ -f $CMD ]] && chmod +x $CMD && ln -sf $CMD /usr/local/bin/Over-Tun
}

update_script() {
  echo -e "${YEL}Downloading latest version...${NC}"
  if curl -fsSL --connect-timeout 10 "$REPO_RAW" -o $CMD.tmp && bash -n $CMD.tmp && [[ -s $CMD.tmp ]]; then
    mv -f $CMD.tmp $CMD; chmod +x $CMD; ln -sf $CMD /usr/local/bin/Over-Tun
    echo -e "${GRN}Updated. Run: over-tun${NC}"
    [[ -f /usr/local/bin/overtun-web.py ]] && echo "Tip: run option 6 again to update the web panel too."
  else
    rm -f $CMD.tmp; echo -e "${RED}Download failed (GitHub may be blocked on this server).${NC}"
  fi
}

speed_test() {
  echo -e "${YEL}Testing this server's own internet speed (~30s)...${NC}"
  local d u
  d=$(curl -s --max-time 15 -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=200000000')
  u=$(head -c 50000000 /dev/zero | curl -s --max-time 15 -o /dev/null -w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up')
  echo -e "Download: ${GRN}$(awk -v v="${d:-0}" 'BEGIN{printf "%.0f", v*8/1e6}') Mbps${NC}"
  echo -e "Upload:   ${GRN}$(awk -v v="${u:-0}" 'BEGIN{printf "%.0f", v*8/1e6}') Mbps${NC}"
  awk -v v="${d:-0}" 'BEGIN{exit !(v<1000)}' && echo -e "${YEL}(speed test server not reachable from this server - result not valid)${NC}"
  if [[ -f $CONF ]]; then
    . $CONF
    local peer=$PEER
    [[ -z $peer ]] && peer=$(ss -Htn state established "( sport = :$TPORT )" | awk '{print $4}' | sed -E 's/:[0-9]+$//;s/^\[|\]$//g;s/^::ffff://' | head -1)
    [[ -n $peer ]] && { echo "Ping to other server ($peer):"; ping -c 10 -i 0.3 -q "$peer" | tail -2; }
  fi
  echo "Tunnel speed can never be higher than the SLOWER of the two servers."
}

stop_tunnel() {
  systemctl stop overtun-watchdog.timer 2>/dev/null
  systemctl stop $SVC_NAME && echo -e "${GRN}Tunnel stopped. (Start it again with option 13)${NC}"
}

start_tunnel() {
  [[ -f $CONF ]] || { echo -e "${RED}Tunnel is not installed (option 1 or 2)${NC}"; return; }
  systemctl start $SVC_NAME
  [[ -f /etc/systemd/system/overtun-watchdog.timer ]] && systemctl start overtun-watchdog.timer
  sleep 1; systemctl is-active --quiet $SVC_NAME && echo -e "${GRN}Tunnel started.${NC}" || status
}

# ---------------- non-interactive commands (used by the web panel) ----------------
#   over-tun restart|stop|start
#   over-tun mode medium|turbo|advanced
#   over-tun port-add <port>  |  over-tun port-del <port>
#   over-tun method wss|tls          (kharej)
#   over-tun reconnect <iran_ip> <code>   (kharej)
#   over-tun code                    (iran)
set_env() { sed -i "s|^$1=.*|$1=$2|" $CONF; }

regen_ports() {
  . $CONF
  local list="" p
  if [[ $ROLE == iran ]]; then
    for p in ${PORTS//,/ }; do list+="${list:+, }{ single = $p }"; done
    sed -i "s/^allowPorts = .*/allowPorts = [$list]/" $FRP_CONF
    if [[ -f $CONF_DIR/code.txt ]]; then   # keep the connection code in sync
      base64 -d $CONF_DIR/code.txt 2>/dev/null | sed "s/^PORTS=.*/PORTS=$PORTS/" | base64 -w0 > $CONF_DIR/code.tmp && mv -f $CONF_DIR/code.tmp $CONF_DIR/code.txt
    fi
  else
    sed -i '/^\[\[proxies\]\]/,$d' $FRP_CONF
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' $FRP_CONF
    for p in ${PORTS//,/ }; do
      printf '\n[[proxies]]\nname = "t%s"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' "$p" "$p" "$p" >> $FRP_CONF
      [[ $UDP == y ]] && printf '\n[[proxies]]\nname = "u%s"\ntype = "udp"\nlocalIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' "$p" "$p" "$p" >> $FRP_CONF
    done
  fi
}

cli_fail() { echo "ERROR: $*"; exit 1; }

cli() {
  [[ $EUID -ne 0 ]] && cli_fail "run as root"
  [[ -f $CONF ]] || cli_fail "tunnel is not installed"
  . $CONF
  local a=$1; shift
  case $a in
    restart) systemctl restart $SVC_NAME && echo "OK: tunnel restarted" ;;
    stop)    systemctl stop overtun-watchdog.timer 2>/dev/null; systemctl stop $SVC_NAME && echo "OK: tunnel stopped" ;;
    start)   systemctl start $SVC_NAME; [[ -f /etc/systemd/system/overtun-watchdog.timer ]] && systemctl start overtun-watchdog.timer
             echo "OK: tunnel started" ;;
    mode)
      [[ $1 =~ ^(medium|turbo|advanced)$ ]] || cli_fail "mode must be medium, turbo or advanced"
      apply_profile "$1" >/dev/null; pool_for_mode "$1"
      sed -i -E "s/^transport\.poolCount = .*/transport.poolCount = $POOL/; s/^transport\.maxPoolCount = .*/transport.maxPoolCount = $MAXPOOL/" $FRP_CONF
      systemctl restart $SVC_NAME && echo "OK: speed mode = $1 (set the same on the other server)" ;;
    port-add)
      local p=$1 webp
      [[ $p =~ ^[0-9]{1,5}$ ]] && (( p >= 1 && p <= 65535 )) || cli_fail "invalid port"
      [[ ,$PORTS, == *",$p,"* ]] && cli_fail "port $p is already in the list"
      webp=$(grep -oP '^WEB_PORT=\K\d+' $CONF_DIR/web.conf 2>/dev/null)
      [[ $p == 7400 || $p == 7500 || $p == "$webp" ]] && cli_fail "port $p is reserved"
      if [[ $ROLE == iran ]]; then
        [[ $p == "$TPORT" ]] && cli_fail "port $p is the tunnel port"
        port_in_use "$p" && cli_fail "port $p is already used by another program on this server"
      fi
      set_env PORTS "${PORTS:+$PORTS,}$p"; regen_ports
      systemctl restart $SVC_NAME
      echo "OK: port $p added - add it on the other server too"
      [[ $ROLE == kharej ]] && ! port_in_use "$p" && echo "Note: nothing is listening on port $p on this server yet (e.g. Xray inbound)."
      true ;;
    port-del)
      local p=$1
      [[ ,$PORTS, == *",$p,"* ]] || cli_fail "port $p is not in the list"
      [[ $PORTS == "$p" ]] && cli_fail "cannot remove the last port"
      set_env PORTS "$(echo ",$PORTS," | sed "s/,$p,/,/; s/^,//; s/,$//")"; regen_ports
      systemctl restart $SVC_NAME && echo "OK: port $p removed - remove it on the other server too" ;;
    method)
      [[ $ROLE == kharej ]] || cli_fail "change the method on the KHAREJ server (Iran accepts both WSS and TLS)"
      [[ $1 =~ ^(wss|tls)$ ]] || cli_fail "method must be wss or tls"
      [[ $TRANSPORT =~ ^(wss|tls)$ ]] || cli_fail "current method is $TRANSPORT - reinstall to switch"
      local proto=tcp; [[ $1 == wss ]] && proto=websocket
      sed -i "s/^transport.protocol = .*/transport.protocol = \"$proto\"/" $FRP_CONF; set_env TRANSPORT "$1"
      systemctl restart $SVC_NAME && echo "OK: method = $1" ;;
    reconnect)
      [[ $ROLE == kharej ]] || cli_fail "reconnect is for the KHAREJ server"
      [[ $1 =~ ^[A-Za-z0-9.:-]{3,100}$ ]] || cli_fail "invalid Iran IP"
      local prev=$TRANSPORT
      gen_kharej_config "$1" "$2" "$(cat $MODE_FILE 2>/dev/null || echo turbo)" || exit 1
      . $CONF   # keep the user's WSS/TLS choice if the new code is also WSS/TLS
      if [[ $prev =~ ^(wss|tls)$ && $TRANSPORT =~ ^(wss|tls)$ && $prev != "$TRANSPORT" ]]; then
        local proto=tcp; [[ $prev == wss ]] && proto=websocket
        sed -i "s/^transport.protocol = .*/transport.protocol = \"$proto\"/" $FRP_CONF; set_env TRANSPORT "$prev"
      fi
      systemctl restart $SVC_NAME
      for i in $(seq 12); do kharej_linked && break; sleep 1; done
      kharej_linked && echo "OK: connected to $1" || echo "ERROR: saved, but not connected yet - check logs" ;;
    code)
      [[ -f $CONF_DIR/code.txt ]] || cli_fail "no connection code on this server"
      cat $CONF_DIR/code.txt; echo ;;
    *) cli_fail "unknown command: $a" ;;
  esac
}

main() {
  [[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root${NC}"; exit 1; }
  install_cmd
  clear
  echo "=================================="
  echo "   Over-Tun  (Iran <-> Kharej)"
  echo "  open this menu anytime: over-tun"
  echo "=================================="
  echo "1) Install on IRAN server"
  echo "2) Install on KHAREJ server"
  echo "3) Status / logs"
  echo "4) Restart tunnel"
  echo "5) Show connection code (Iran)"
  echo "6) Install WEB monitor panel"
  echo "7) Remove WEB monitor panel"
  echo "8) REMOVE tunnel completely (uninstall)"
  echo "9) Change speed mode (Medium / Turbo / Advanced)"
  echo "10) Speed test (this server)"
  echo "11) Update script"
  echo "12) Stop tunnel (temporary)"
  echo "13) Start tunnel"
  read -rp "Choose: " c
  case $c in
    1) setup_iran ;;
    2) setup_kharej ;;
    3) status ;;
    4) systemctl restart $SVC_NAME && echo "Restarted" ;;
    5) show_code ;;
    6) install_web ;;
    7) remove_web ;;
    8) uninstall ;;
    9) change_mode ;;
    10) speed_test ;;
    11) update_script ;;
    12) stop_tunnel ;;
    13) start_tunnel ;;
    *) echo "Invalid" ;;
  esac
}

(return 0 2>/dev/null) || { if [[ $# -gt 0 ]]; then cli "$@"; exit $?; fi; main; }
