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
    printf 'transport.maxPoolCount = %s\ntransport.tcpMux = false\ntransport.heartbeatTimeout = 40\n' "$MAXPOOL"
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
    printf 'transport.dialServerTimeout = 10\ntransport.dialServerKeepalive = 300\n'
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

# ---- non-interactive core (used by the menu AND the web panel) ----
# do_setup_iran <method> <tunnel_port> <sni> <ports_csv> <udp y|n> <mode>
do_setup_iran() {
  local tr=$1 tport=$2 sni=$3 ports=$4 udp=$5 mode=$6 p
  [[ $tr =~ ^(tls|wss|quic|kcp)$ ]] || { echo -e "${RED}ERROR: invalid method${NC}"; return 1; }
  [[ $tport =~ ^[0-9]{1,5}$ ]] && (( tport >= 1 && tport <= 65535 )) || { echo -e "${RED}ERROR: invalid tunnel port${NC}"; return 1; }
  [[ $sni =~ ^[A-Za-z0-9.-]{3,100}$ ]] || { echo -e "${RED}ERROR: invalid SNI domain${NC}"; return 1; }
  [[ $ports =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo -e "${RED}ERROR: invalid port list${NC}"; return 1; }
  [[ $udp == y ]] || udp=n
  [[ $mode =~ ^(medium|turbo|advanced)$ ]] || mode=turbo
  install_deps; install_binary; cleanup_legacy
  systemctl stop $SVC_NAME 2>/dev/null
  if port_in_use "$tport"; then echo -e "${RED}ERROR: TCP port $tport is already in use. Pick another (e.g. 8443 or 2053).${NC}"; return 1; fi
  if is_udp "$tr" && port_in_use "$tport" udp; then echo -e "${RED}ERROR: UDP port $tport is already in use.${NC}"; return 1; fi
  for p in ${ports//,/ }; do
    [[ $p == "$tport" ]] && ! is_udp "$tr" && { echo -e "${RED}ERROR: port $p is the tunnel port${NC}"; return 1; }
    [[ $p == 7400 || $p == 7500 ]] && { echo -e "${RED}ERROR: port $p is reserved${NC}"; return 1; }
    port_in_use "$p" && { echo -e "${RED}ERROR: port $p is already in use on this server${NC}"; return 1; }
  done
  apply_profile "$mode"
  local token; token=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
  gen_iran_config "$tr" "$tport" "$token" "$ports" "$udp" "$sni" "$mode" || return 1
  write_service frps
  sleep 2
  if systemctl is-active --quiet $SVC_NAME; then
    echo -e "\n${GRN}OK: Iran server ready  (method: $tr, tunnel port: $tport, ports: $ports, mode: $mode)${NC}"
    is_udp "$tr" && echo -e "${YEL}Make sure UDP port $tport is open in your server provider's firewall.${NC}"
  else
    echo -e "${RED}ERROR: tunnel failed to start:${NC}"; journalctl -u $SVC_NAME -n 15 --no-pager; return 1
  fi
  show_code
}

# do_setup_kharej <iran_ip> <code> <mode>
do_setup_kharej() {
  local ip=$1 code=$2 mode=$3 p
  [[ $ip =~ ^[A-Za-z0-9.:-]{3,100}$ ]] || { echo -e "${RED}ERROR: invalid Iran IP${NC}"; return 1; }
  [[ $mode =~ ^(medium|turbo|advanced)$ ]] || mode=turbo
  install_deps; install_binary; cleanup_legacy
  apply_profile "$mode"
  systemctl stop $SVC_NAME 2>/dev/null
  gen_kharej_config "$ip" "$code" "$mode" || return 1
  write_service frpc
  write_watchdog
  for p in ${KH_PORTS//,/ }; do
    port_in_use "$p" || echo -e "${YEL}Warning: nothing is listening on port $p on this server yet (start your service, e.g. Xray, on it).${NC}"
  done
  echo -ne "${YEL}Connecting${NC}"
  for i in $(seq 15); do kharej_linked && break; echo -n "."; sleep 1; done; echo
  if kharej_linked; then
    echo -e "${GRN}OK: tunnel connected to $ip:$KH_TPORT  (method: $KH_TR, mode: $mode)${NC}"
  else
    echo -e "${YEL}ERROR: not connected yet. Check logs.${NC}"
    journalctl -u $SVC_NAME -n 8 --no-pager | cut -c1-220; return 1
  fi
}

setup_iran() {
  choose_mode; choose_transport
  read -rp "Tunnel port [443]: " TPORT; TPORT=${TPORT:-443}
  read -rp "TLS domain / SNI [www.speedtest.net]: " SNI; SNI=${SNI:-www.speedtest.net}
  ask_ports "$TPORT" || return
  do_setup_iran "$TRANSPORT" "$TPORT" "$SNI" "$PORTS_IN" "$UDP" "$MODE"
}

setup_kharej() {
  choose_mode
  read -rp "Iran server IP: " IRIP
  read -rp "Connection code (from Iran server): " CODE
  do_setup_kharej "$IRIP" "$CODE" "$MODE"
}

# remove the tunnel but keep the web panel and its data (used by the panel)
remove_tunnel() {
  systemctl disable --now $SVC_NAME overtun-watchdog.timer 2>/dev/null
  rm -f $SVC /etc/systemd/system/overtun-watchdog.* /usr/local/bin/overtun-watchdog.sh
  /usr/local/bin/overtun-nic.sh medium >/dev/null 2>&1
  rm -rf $FRP_CONF $CONF $CONF_DIR/tls $CONF_DIR/code.txt $MODE_FILE $DROPIN_DIR /etc/sysctl.d/99-tunnel.conf
  systemctl daemon-reload
  echo "OK: tunnel removed (web panel kept)"
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
  command -v python3 >/dev/null || { apt install -y python3 >/dev/null 2>&1 || yum install -y python3 >/dev/null 2>&1; }
  command -v python3 >/dev/null || { echo -e "${RED}python3 not available${NC}"; return; }
  local RP=$((RANDOM % 30000 + 20000)) old
  old=$(grep -oP '^WEB_PORT=\K\d+' $CONF_DIR/web.conf 2>/dev/null); [[ -n $old ]] && RP=$old
  read -rp "Panel port [$RP]: " WP; WP=${WP:-$RP}
  read -rp "Username [admin]: " WU; WU=${WU:-admin}
  read -rp "Password [random]: " WPASS
  [[ -z $WPASS ]] && WPASS=$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
  read -rp "Server port speed in Mbps for the gauges, e.g. 1000 [auto]: " LINK
  [[ $LINK =~ ^[0-9]+$ ]] || LINK=0
  mkdir -p $CONF_DIR; chmod 700 $CONF_DIR
  local WHASH
  WHASH=$(python3 -c 'import hashlib,os,sys;s=os.urandom(16);print(s.hex()+"$"+hashlib.pbkdf2_hmac("sha256",sys.argv[1].encode(),s,200000).hex())' "$WPASS")
  printf 'WEB_PORT=%s\nWEB_USER=%s\nWEB_HASH=%s\nLINK_MBPS=%s\n' "$WP" "$WU" "$WHASH" "$LINK" > $CONF_DIR/web.conf
  chmod 600 $CONF_DIR/web.conf
  write_panel
  sleep 2
  if systemctl is-active --quiet overtun-web; then
    IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GRN}Web panel is running${NC}"
    echo -e "URL:      ${YEL}http://$IP:$WP${NC}"
    echo -e "Username: ${YEL}$WU${NC}"
    echo -e "Password: ${YEL}$WPASS${NC}"
    [[ -f $CONF ]] || echo -e "${CYN}Tip: you can create the tunnel from the panel (menu: Tunnel).${NC}"
  else
    echo -e "${RED}Web panel failed to start:${NC}"
    journalctl -u overtun-web -n 15 --no-pager
  fi
}

# write (or refresh) the panel program + its service, keeps web.conf and all data
write_panel() {
  cat > /usr/local/bin/overtun-web.py <<'PYEOF'
#!/usr/bin/env python3
# Over-Tun web panel  -  Overal-Team
# no external dependencies (python3 standard library only)
import json, os, re, socket, subprocess, threading, time, hashlib, hmac, secrets, urllib.request, shlex
from datetime import datetime, timedelta
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from http.cookies import SimpleCookie
from urllib.parse import urlparse, parse_qs
from collections import deque

VERSION = '3.0'
CONF_DIR = '/etc/overtun'
CMD = '/usr/local/bin/over-tun'
F_TRAFFIC, F_EVENTS, F_AUDIT = CONF_DIR + '/traffic.json', CONF_DIR + '/events.json', CONF_DIR + '/audit.json'
F_JOB, F_JOBLOG = CONF_DIR + '/job.json', CONF_DIR + '/job.log'
ANSI = re.compile(r'\x1b\[[0-9;]*m')

# ---------------------------------------------------------------- helpers
def load_kv(path):
    d = {}
    try:
        for line in open(path):
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                d[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    return d

def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default

def save_json(path, obj):
    try:
        tmp = path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(obj, f, separators=(',', ':'))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        pass

def sh(cmd, t=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=t).stdout
    except Exception:
        return ''

# ---------------------------------------------------------------- web config / password
WEB = load_kv(CONF_DIR + '/web.conf')
LISTEN = int(WEB.get('WEB_PORT', '9090') or 9090)
USER = WEB.get('WEB_USER', 'admin')
try:
    LINK_MBPS = int(WEB.get('LINK_MBPS', '0') or 0)
except ValueError:
    LINK_MBPS = 0

def make_hash(pw):
    salt = os.urandom(16)
    return salt.hex() + '$' + hashlib.pbkdf2_hmac('sha256', pw.encode(), salt, 200000).hex()

def save_web(key, val):
    lines = [l for l in open(CONF_DIR + '/web.conf').read().splitlines()
             if l and not l.startswith(key + '=') and not l.startswith('WEB_PASS=')]
    lines.append(f'{key}={val}')
    open(CONF_DIR + '/web.conf', 'w').write('\n'.join(lines) + '\n')
    os.chmod(CONF_DIR + '/web.conf', 0o600)

PWHASH = WEB.get('WEB_HASH', '')
if not PWHASH:                                   # migrate an old plain-text password
    PWHASH = make_hash(WEB.get('WEB_PASS', 'admin'))
    try: save_web('WEB_HASH', PWHASH)
    except OSError: pass

def check_pw(pw):
    try:
        salt, h = PWHASH.split('$', 1)
        return hmac.compare_digest(hashlib.pbkdf2_hmac('sha256', pw.encode(), bytes.fromhex(salt), 200000).hex(), h)
    except Exception:
        return False

# ---------------------------------------------------------------- tunnel info (always fresh)
_envc = [0.0, {}]
def env():
    if time.time() - _envc[0] > 2:
        _envc[0], _envc[1] = time.time(), load_kv(CONF_DIR + '/tunnel.env')
    return _envc[1]

def role():
    r = env().get('ROLE', '')
    return r if r in ('iran', 'kharej') and os.path.exists(CONF_DIR + '/frp.toml') else ''

def ports():
    return sorted({int(p) for p in env().get('PORTS', '').split(',') if p.strip().isdigit()})

def tport():
    try: return int(env().get('TPORT') or 0)
    except ValueError: return 0

def cur_mode():
    try: return open(CONF_DIR + '/mode').read().strip() or 'turbo'
    except OSError: return 'turbo'

def api(path):
    r = role()
    if not r: return None
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{7500 if r == "iran" else 7400}{path}', timeout=2) as res:
            return json.loads(res.read().decode())
    except Exception:
        return None

def link_up():
    r = role()
    if r == 'iran':
        d = api('/api/serverinfo')
        return bool(d) and (d.get('clientCounts') or 0) > 0
    if r == 'kharej':
        d = api('/api/status')
        return bool(d) and any(isinstance(v, list) and any(p.get('status') == 'running' for p in v) for v in d.values())
    return False

def svc_active():
    return sh(['systemctl', 'is-active', 'overtun']).strip() == 'active'

# ---------------------------------------------------------------- system metrics
m = re.search(r'dev (\S+)', sh(['ip', 'route', 'get', '1.1.1.1']))
IFACE = WEB.get('IFACE') or (m.group(1) if m else 'eth0')

def rd(path):
    try: return int(open(path).read())
    except Exception: return 0

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
    out = []
    for fn in ('/proc/net/tcp', '/proc/net/tcp6'):
        try: lines = open(fn).read().splitlines()[1:]
        except OSError: continue
        for l in lines:
            f = l.split()
            if len(f) < 4 or f[3] != '01': continue
            la, lp = f[1].split(':'); ra, rp = f[2].split(':')
            out.append((hexip(la), int(lp, 16), hexip(ra), int(rp, 16)))
    return out

def conns():
    r, tp = role(), tport()
    tun, per = [], {p: 0 for p in ports()}
    for lh, lp, ph, pp in established():
        if r == 'iran':
            if lp == tp: tun.append(ph)
            elif lp in per and not ph.startswith('127.'): per[lp] += 1
        elif r == 'kharej':
            if pp == tp: tun.append(ph)
            elif pp in per and ph in ('127.0.0.1', '::1'): per[pp] += 1
    return tun, per

# ---------------------------------------------------------------- events / audit (persistent)
LOCK = threading.Lock()
EVENTS = deque(load_json(F_EVENTS, []), maxlen=300)
AUDIT = deque(load_json(F_AUDIT, []), maxlen=300)

def add_event(kind):
    with LOCK:
        EVENTS.appendleft([int(time.time()), kind])
        save_json(F_EVENTS, list(EVENTS))

def audit(ip, action, ok=True, detail=''):
    with LOCK:
        AUDIT.appendleft([int(time.time()), ip, action, bool(ok), str(detail)[:160]])
        save_json(F_AUDIT, list(AUDIT))

# ---------------------------------------------------------------- live sampler
S = {'hist': deque(maxlen=150), 'lat': deque(maxlen=120), 'cpu': 0.0, 'up': None,
     'up_since': time.time(), 'down_since': None, 'total_down': 0.0, 'active': False}

def sampler():
    rx0, tx0 = net(); i0, t0 = cpu_times(); last = time.time(); pend = 0; n = 0
    while True:
        time.sleep(1)
        now = time.time(); dt = max(now - last, 0.001); last = now
        rx1, tx1 = net(); i1, t1 = cpu_times()
        rxr, txr = max(0, rx1 - rx0) * 8 / dt, max(0, tx1 - tx0) * 8 / dt
        cpu = 100 * (1 - (i1 - i0) / max(t1 - t0, 1))
        rx0, tx0, i0, t0 = rx1, tx1, i1, t1
        if n % 3 == 0: S['active'] = svc_active()
        n += 1
        installed = bool(role())
        up = installed and S['active'] and link_up()
        with LOCK:
            S['hist'].append([round(now, 1), round(rxr), round(txr)]); S['cpu'] = cpu
        if not installed:
            S['up'] = None; continue
        if S['up'] is None:
            S['up'] = up
            if not up: S['down_since'] = now
            else: S['up_since'] = now
        elif up != S['up']:
            pend += 1
            if pend >= 3:                       # 3s stable before changing state
                pend = 0; S['up'] = up
                add_event('up' if up else 'down')
                if up:
                    if S['down_since']: S['total_down'] += now - S['down_since']
                    S['down_since'] = None; S['up_since'] = now
                else:
                    S['down_since'] = now
        else:
            pend = 0

def tcp_rtt(host, port):
    try:
        t = time.time(); s = socket.create_connection((host, port), timeout=3); s.close()
        return (time.time() - t) * 1000
    except OSError:
        return None

def pinger():
    while True:
        lat = None
        if role():
            tun, _ = conns()
            peer = env().get('PEER') or (tun[0] if tun else '')
            if peer:
                m2 = re.search(r'time=([\d.]+)', sh(['ping', '-c1', '-W2', peer]))
                lat = float(m2.group(1)) if m2 else None
                if lat is None and role() == 'kharej': lat = tcp_rtt(peer, tport())
        with LOCK:
            S['lat'].append([round(time.time(), 1), None if lat is None else round(lat, 1)])
        time.sleep(3)

# ---------------------------------------------------------------- traffic ledger (per forwarded port)
# FRP (Iran side) counts the real bytes of every forwarded port = the same bytes x-ui counts.
LEDGER = load_json(F_TRAFFIC, {})
LEDGER.setdefault('ports', {}); LEDGER.setdefault('last', {}); LEDGER.setdefault('since', int(time.time()))
CURCONNS = {}

def today():
    return datetime.now().strftime('%Y-%m-%d')

def ledger_tick():
    if role() != 'iran': return
    changed = False
    for typ in ('tcp', 'udp'):
        d = api('/api/proxy/' + typ)
        if not d: continue
        for px in d.get('proxies') or []:
            mm = re.match(r'^[tu](\d+)$', px.get('name', ''))
            if not mm: continue
            port, key = mm.group(1), typ[0] + mm.group(1)
            cin, cout = int(px.get('todayTrafficIn') or 0), int(px.get('todayTrafficOut') or 0)
            if typ == 'tcp': CURCONNS[port] = int(px.get('curConns') or 0)
            last = LEDGER['last'].get(key)
            if last is None: din, dout = cin, cout
            else:
                din = cin - last[0] if cin >= last[0] else cin
                dout = cout - last[1] if cout >= last[1] else cout
            if last != [cin, cout]:
                LEDGER['last'][key] = [cin, cout]; changed = True
            if din or dout:
                with LOCK:
                    p = LEDGER['ports'].setdefault(port, {'in': 0, 'out': 0, 'days': {}})
                    p['in'] += din; p['out'] += dout
                    dd = p['days'].setdefault(today(), [0, 0]); dd[0] += din; dd[1] += dout
                    cut = (datetime.now() - timedelta(days=60)).strftime('%Y-%m-%d')
                    for k in [k for k in p['days'] if k < cut]: p['days'].pop(k)
                changed = True
    if changed:
        with LOCK: save_json(F_TRAFFIC, LEDGER)

def ledger_loop():
    while True:
        try: ledger_tick()
        except Exception: pass
        time.sleep(15)

def traffic_info():
    r = role()
    _, per = conns()
    days14 = [(datetime.now() - timedelta(days=i)).strftime('%Y-%m-%d') for i in range(13, -1, -1)]
    week = set(days14[-7:]); td = today()
    rows, agg = [], {d: [0, 0] for d in days14}
    with LOCK:
        led = json.loads(json.dumps(LEDGER['ports']))
    for p in sorted(set(map(str, ports())) | set(led.keys()), key=int):
        e = led.get(p, {'in': 0, 'out': 0, 'days': {}})
        t = e['days'].get(td, [0, 0])
        w = [sum(v[0] for k, v in e['days'].items() if k in week), sum(v[1] for k, v in e['days'].items() if k in week)]
        for d in days14:
            v = e['days'].get(d)
            if v: agg[d][0] += v[0]; agg[d][1] += v[1]
        rows.append({'port': int(p), 'active': int(p) in ports(), 'conns': CURCONNS.get(p, per.get(int(p), 0)) if r == 'iran' else per.get(int(p), 0),
                     'today': t, 'week': w, 'total': [e['in'], e['out']]})
    return {'role': r, 'rows': rows, 'days': [[d] + agg[d] for d in days14], 'since': LEDGER.get('since')}

# ---------------------------------------------------------------- jobs (long tasks: setup / update), run outside the panel
def job_status():
    j = load_json(F_JOB, {})
    try: log = open(F_JOBLOG, errors='ignore').read()[-20000:]
    except OSError: log = ''
    mm = re.search(r'__EXIT__:(\d+)', log)
    done = bool(mm) or not j or time.time() - j.get('start', 0) > 1800
    return {'label': j.get('label', ''), 'action': j.get('action', ''), 'start': j.get('start', 0), 'running': not done,
            'code': int(mm.group(1)) if mm else None, 'log': ANSI.sub('', log.replace('__EXIT__:', 'exit code: '))}

def start_job(args, label):
    if job_status()['running']: return False, 'یک عملیات دیگر در حال اجراست'
    open(F_JOBLOG, 'w').write('')
    save_json(F_JOB, {'label': label, 'action': args[0], 'start': time.time()})
    script = f'{shlex.join([CMD] + args)} > {F_JOBLOG} 2>&1; echo "__EXIT__:$?" >> {F_JOBLOG}'
    unit = f'overtun-job-{int(time.time())}'
    try:
        subprocess.run(['systemd-run', '--unit', unit, '--collect', '--quiet', '/bin/bash', '-c', script], timeout=15, check=True)
    except Exception:
        subprocess.Popen(['/bin/bash', '-c', script], start_new_session=True)
    return True, 'started'

# ---------------------------------------------------------------- management actions
ARG_RX = {'mode': [r'^(medium|turbo|advanced)$'], 'port-add': [r'^\d{1,5}$'], 'port-del': [r'^\d{1,5}$'],
          'method': [r'^(wss|tls)$'], 'reconnect': [r'^[A-Za-z0-9.:-]{3,100}$', r'^[A-Za-z0-9+/=]{20,10000}$'],
          'restart': [], 'stop': [], 'start': [], 'remove-tunnel': []}
JOB_RX = {'setup-iran': [r'^(tls|wss|quic|kcp)$', r'^\d{1,5}$', r'^[A-Za-z0-9.-]{3,100}$', r'^\d{1,5}(,\d{1,5}){0,30}$', r'^[yn]$', r'^(medium|turbo|advanced)$'],
          'setup-kharej': [r'^[A-Za-z0-9.:-]{3,100}$', r'^[A-Za-z0-9+/=]{20,10000}$', r'^(medium|turbo|advanced)$'],
          'update': []}
JOB_LABEL = {'setup-iran': 'ساخت تانل سرور ایران', 'setup-kharej': 'اتصال سرور خارج', 'update': 'آپدیت اسکریپت و پنل'}

def clean_args(action, args, table):
    rx = table[action]
    args = [str(a).strip() for a in (args or [])]
    args = [re.sub(r'\s+', '', a) if len(a) > 100 else a for a in args]
    if len(args) != len(rx) or not all(re.match(r, a) for r, a in zip(rx, args)): return None
    return args

def manage(action, args):
    if action not in ARG_RX: return False, 'unknown action'
    args = clean_args(action, args, ARG_RX)
    if args is None: return False, 'ERROR: invalid input'
    try:
        r = subprocess.run([CMD, action] + args, capture_output=True, text=True, timeout=120)
        out = ANSI.sub('', (r.stdout + r.stderr).strip())
        return r.returncode == 0 and 'ERROR' not in out, out or 'done'
    except Exception as e:
        return False, f'ERROR: {e}'

def config_info():
    e, r = env(), role()
    d = {'installed': bool(r), 'role': r, 'transport': e.get('TRANSPORT', ''), 'tport': tport(), 'ports': ports(),
         'udp': e.get('UDP') == 'y', 'sni': e.get('SNI', ''), 'mode': cur_mode(), 'peer': e.get('PEER', ''),
         'user': USER, 'code': '', 'version': VERSION, 'panel_port': LISTEN, 'pstatus': {}}
    if r == 'iran':
        try: d['code'] = open(CONF_DIR + '/code.txt').read().strip()
        except OSError: pass
    elif r == 'kharej':
        for v in (api('/api/status') or {}).values():
            for x in (v if isinstance(v, list) else []):
                mm = re.match(r'^[tu](\d+)$', x.get('name', ''))
                if mm and x.get('status') != 'running': d['pstatus'][mm.group(1)] = x.get('err') or x.get('status')
    return d

def stats(since):
    tun, per = conns()
    mi = {}
    for l in open('/proc/meminfo'):
        k, v = l.split(':', 1); mi[k] = int(v.split()[0]) * 1024
    try: restarts = int(sh(['systemctl', 'show', 'overtun', '-p', 'NRestarts', '--value']).strip() or 0)
    except ValueError: restarts = 0
    rx, tx = net(); now = time.time(); e = env()
    with LOCK:
        down = S['total_down'] + ((now - S['down_since']) if S['down_since'] else 0)
        hist = [h for h in S['hist'] if h[0] > since]
        lat = [h for h in S['lat'] if h[0] > since]
        ev = list(EVENTS)[:12]
    return {'installed': bool(role()), 'role': role(), 'mode': cur_mode(), 'transport': e.get('TRANSPORT', ''), 'tport': tport(),
            'peer': e.get('PEER') or (tun[0] if tun else ''), 'up': bool(S['up']), 'active': S['active'], 'ports': per,
            'restarts': restarts, 'up_for': (now - S['up_since']) if S['up'] else 0, 'total_down': down,
            'hist': hist, 'lat': lat, 'cpu': S['cpu'], 'cores': os.cpu_count() or 1, 'load': open('/proc/loadavg').read().split()[:3],
            'mem_total': mi.get('MemTotal', 0), 'mem_used': mi.get('MemTotal', 0) - mi.get('MemAvailable', 0),
            'rx_total': rx, 'tx_total': tx, 'link_mbps': LINK_MBPS, 'events': ev, 'iface': IFACE, 'now': now, 'version': VERSION}

# ---------------------------------------------------------------- pages
LOGIN_HTML = r'''<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Over-Tun · Sign in</title>
<style>
:root{--bg:#07070a;--card:rgba(20,18,14,.82);--bd:rgba(212,175,55,.20);--tx:#f4ecd6;--mu:#a59a80;--in:#0c0b09;
--g1:#f7e08a;--g2:#d4af37;--g3:#a67c1b;--bad:#f87171;--sh:0 30px 80px rgba(0,0,0,.6),0 0 60px rgba(212,175,55,.10)}
:root[data-theme=light]{--bg:#faf7ef;--card:rgba(255,255,255,.9);--bd:rgba(166,124,27,.22);--tx:#2b2416;--mu:#85795f;--in:#fffdf8;
--g1:#e6c35c;--g2:#b8860b;--g3:#8a6410;--sh:0 30px 70px rgba(120,90,20,.16),0 0 50px rgba(212,175,55,.12)}
*{box-sizing:border-box}html,body{margin:0;min-height:100%}
body{background:radial-gradient(900px 500px at 80% -10%,rgba(212,175,55,.20),transparent 60%),radial-gradient(800px 500px at 0% 110%,rgba(212,175,55,.12),transparent 60%),var(--bg);
color:var(--tx);font:14px/1.7 Vazirmatn,"IRANSansX",Tahoma,system-ui,sans-serif;display:grid;place-items:center;padding:16px;min-height:100vh}
.box{width:100%;max-width:400px;background:var(--card);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px);border:1px solid var(--bd);border-radius:26px;box-shadow:var(--sh);padding:34px 28px;position:relative;overflow:hidden}
.box::before{content:"";position:absolute;inset:0 0 auto 0;height:2px;background:linear-gradient(90deg,transparent,var(--g1),var(--g2),transparent)}
.logo{width:66px;height:66px;margin:0 auto 16px;border-radius:20px;display:grid;place-items:center;color:#1a1406;
background:linear-gradient(135deg,var(--g1),var(--g2) 55%,var(--g3));box-shadow:0 10px 30px rgba(212,175,55,.45),inset 0 1px 0 rgba(255,255,255,.5);animation:float 4s ease-in-out infinite}
@keyframes float{50%{transform:translateY(-4px)}}
h1{font-size:24px;text-align:center;margin:0;font-weight:900;letter-spacing:.5px;direction:ltr;background:linear-gradient(135deg,var(--g1),var(--g2) 50%,var(--g3));-webkit-background-clip:text;background-clip:text;color:transparent}
.sub{text-align:center;color:var(--mu);font-size:12.5px;margin:2px 0 24px;letter-spacing:2px;direction:ltr}
label{display:block;font-size:12.5px;color:var(--mu);margin:14px 0 7px}
input{font:inherit;width:100%;background:var(--in);color:var(--tx);border:1px solid var(--bd);border-radius:14px;padding:12px 14px;outline:none;direction:ltr;text-align:left;transition:border-color .2s,box-shadow .2s}
input:focus{border-color:var(--g2);box-shadow:0 0 0 4px rgba(212,175,55,.15)}
button{font:inherit;width:100%;margin-top:24px;border:0;border-radius:14px;padding:13px;font-weight:900;cursor:pointer;color:#1a1406;
background:linear-gradient(135deg,var(--g1),var(--g2) 55%,var(--g3));box-shadow:0 10px 26px rgba(212,175,55,.35);transition:transform .1s,filter .2s}
button:hover{filter:brightness(1.07)}button:active{transform:scale(.98)}button:disabled{opacity:.6;cursor:wait}
.err{min-height:24px;margin-top:14px;color:var(--bad);font-size:12.5px;text-align:center}
.foot{text-align:center;color:var(--mu);font-size:11px;margin-top:6px;direction:ltr;letter-spacing:1px}

.orbs{position:fixed;inset:0;z-index:-1;overflow:hidden;pointer-events:none}
.orbs i{position:absolute;border-radius:50%;filter:blur(70px);opacity:.6;animation:drift 24s ease-in-out infinite alternate}
.orbs i:nth-child(1){width:480px;height:480px;top:-120px;right:-60px;background:radial-gradient(circle,#d4af37,transparent 70%)}
.orbs i:nth-child(2){width:440px;height:440px;bottom:-150px;left:-100px;background:radial-gradient(circle,#b8860b,transparent 70%);animation-duration:30s}
.orbs i:nth-child(3){width:320px;height:320px;top:45%;left:45%;background:radial-gradient(circle,#f7e08a,transparent 70%);opacity:.3;animation-duration:36s}
@keyframes drift{0%{transform:translate(0,0) scale(1)}50%{transform:translate(50px,30px) scale(1.1)}100%{transform:translate(-40px,60px) scale(.95)}}
body{background:var(--bg)}
.box{background:linear-gradient(145deg,rgba(255,255,255,.09),rgba(255,255,255,.025));border:1px solid rgba(255,255,255,.12);backdrop-filter:blur(26px) saturate(160%);-webkit-backdrop-filter:blur(26px) saturate(160%);
 box-shadow:inset 0 1px 0 rgba(255,255,255,.14),0 30px 80px rgba(0,0,0,.55)}
:root[data-theme=light] .box{background:linear-gradient(145deg,rgba(255,255,255,.75),rgba(255,255,255,.4));border-color:rgba(255,255,255,.8);box-shadow:inset 0 1px 0 #fff,0 30px 70px rgba(140,100,20,.16)}
input{background:rgba(0,0,0,.28);border-color:rgba(255,255,255,.12)}:root[data-theme=light] input{background:rgba(255,255,255,.6);border-color:rgba(166,124,27,.2)}
button{position:relative;overflow:hidden;color:#1a1406;border:1px solid rgba(255,240,190,.55);
 background:linear-gradient(180deg,rgba(255,255,255,.35),rgba(255,255,255,0) 48%),linear-gradient(135deg,#fbe9a2,#e6c35c 30%,#d4af37 55%,#a67c1b);
 box-shadow:inset 0 1px 0 rgba(255,255,255,.75),inset 0 -3px 8px rgba(120,80,0,.35),0 10px 28px rgba(212,175,55,.4);transition:transform .18s,filter .2s,box-shadow .25s}
button:hover{transform:translateY(-2px);box-shadow:inset 0 1px 0 rgba(255,255,255,.8),inset 0 -3px 8px rgba(120,80,0,.35),0 16px 36px rgba(212,175,55,.55)}
button::before{content:"";position:absolute;top:0;bottom:0;left:-75%;width:45%;background:linear-gradient(100deg,transparent,rgba(255,255,255,.7),transparent);transform:skewX(-20deg);transition:left .7s}
button:hover::before{left:130%}
</style></head><body>
<div class="orbs"><i></i><i></i><i></i></div>
<form class="box" id="f" autocomplete="on">
 <div class="logo"><svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2l8.5 5v10L12 22l-8.5-5V7z"/><path d="M8 12h8M13 9l3 3-3 3"/></svg></div>
 <h1>Over-Tun</h1><div class="sub">OVERAL-TEAM</div>
 <label for="u">نام کاربری</label><input id="u" name="username" autocomplete="username" required>
 <label for="p">رمز عبور</label><input id="p" name="password" type="password" autocomplete="current-password" required>
 <button id="b" type="submit">ورود به پنل</button>
 <div class="err" id="e"></div>
 <div class="foot">secure tunnel panel</div>
</form>
<script>
let th=null;try{th=localStorage.getItem('ot-theme')}catch(e){}
document.documentElement.dataset.theme=th||'dark';
const $=id=>document.getElementById(id);$('u').focus();
$('f').onsubmit=async ev=>{ev.preventDefault();$('b').disabled=true;$('e').textContent='';
 try{const r=await fetch('api/login',{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify({user:$('u').value.trim(),pass:$('p').value})});
  const d=await r.json().catch(()=>({}));
  if(r.ok){location.href='./';return}
  if(r.status==429)$('e').textContent='به دلیل تلاش‌های ناموفق، ورود تا '+Math.ceil((d.wait||600)/60)+' دقیقه قفل است.';
  else $('e').textContent='نام کاربری یا رمز اشتباه است'+(d.left!=null?' ('+d.left+' تلاش باقی‌مانده)':'');
 }catch(e){$('e').textContent='ارتباط با سرور برقرار نشد'}
 $('b').disabled=false;$('p').value='';$('p').focus()};
</script></body></html>'''
HTML = r'''<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Over-Tun</title>
<style>
:root{--bg:#07070a;--side:rgba(12,11,8,.86);--card:rgba(20,18,14,.74);--card2:rgba(30,27,20,.6);--in:#0c0b09;
--bd:rgba(212,175,55,.15);--bd2:rgba(212,175,55,.34);--tx:#f4ecd6;--mu:#a59a80;--mu2:#6f6754;--track:rgba(212,175,55,.10);
--g1:#f7e08a;--g2:#d4af37;--g3:#a67c1b;--ok:#34d399;--bad:#f87171;--warn:#fbbf24;--dl:#f2c94c;--ul:#c9d3e3;
--sh:0 0 0 1px rgba(212,175,55,.04),0 14px 40px rgba(0,0,0,.5),0 0 40px rgba(212,175,55,.05);--glowc:rgba(212,175,55,.55);--onG:#1a1406;
--bgimg:radial-gradient(1100px 600px at 90% -10%,rgba(212,175,55,.17),transparent 60%),radial-gradient(900px 600px at -10% 110%,rgba(212,175,55,.10),transparent 60%)}
:root[data-theme=light]{--bg:#f8f4ea;--side:rgba(255,253,247,.9);--card:rgba(255,255,255,.82);--card2:rgba(250,245,232,.8);--in:#fffdf8;
--bd:rgba(166,124,27,.16);--bd2:rgba(166,124,27,.40);--tx:#2b2416;--mu:#85795f;--mu2:#b3a88e;--track:rgba(166,124,27,.10);
--g1:#e6c35c;--g2:#b8860b;--g3:#8a6410;--dl:#c99a1e;--ul:#5f6f8a;--sh:0 1px 0 rgba(255,255,255,.8) inset,0 12px 34px rgba(120,90,20,.10);--glowc:rgba(184,134,11,.35);
--bgimg:radial-gradient(1100px 600px at 90% -10%,rgba(230,195,92,.30),transparent 60%),radial-gradient(900px 600px at -10% 110%,rgba(230,195,92,.18),transparent 60%)}
*{box-sizing:border-box}html,body{margin:0}
body{background:var(--bgimg),var(--bg);background-attachment:fixed;color:var(--tx);font:14px/1.7 Vazirmatn,"IRANSansX",Tahoma,system-ui,-apple-system,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased;min-height:100vh}
.num{font-variant-numeric:tabular-nums;direction:ltr;unicode-bidi:isolate}
.gt{background:linear-gradient(135deg,var(--g1),var(--g2) 50%,var(--g3));-webkit-background-clip:text;background-clip:text;color:transparent}
.app{display:grid;grid-template-columns:250px 1fr;min-height:100vh}
/* sidebar */
.side{position:sticky;top:0;height:100vh;background:var(--side);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);border-inline-end:1px solid var(--bd);display:flex;flex-direction:column;padding:22px 16px}
.brand{display:flex;align-items:center;gap:12px;padding:4px 8px 22px;border-bottom:1px solid var(--bd);margin-bottom:16px}
.logo{flex:none;width:46px;height:46px;border-radius:14px;display:grid;place-items:center;color:var(--onG);background:linear-gradient(135deg,var(--g1),var(--g2) 55%,var(--g3));box-shadow:0 8px 24px var(--glowc),inset 0 1px 0 rgba(255,255,255,.5)}
.bname{font-size:20px;font-weight:900;letter-spacing:.4px;direction:ltr;text-align:right;line-height:1.1}
.bteam{font-size:10.5px;color:var(--mu);letter-spacing:2.4px;direction:ltr;text-align:right;margin-top:3px}
nav.menu{display:flex;flex-direction:column;gap:4px}
nav.menu a{display:flex;align-items:center;gap:12px;padding:11px 14px;border-radius:13px;color:var(--mu);text-decoration:none;font-weight:700;position:relative;transition:background .2s,color .2s}
nav.menu a svg{flex:none;opacity:.85}
nav.menu a:hover{color:var(--tx);background:var(--track)}
nav.menu a.on{color:var(--g1);background:linear-gradient(270deg,rgba(212,175,55,.20),rgba(212,175,55,.02))}
:root[data-theme=light] nav.menu a.on{color:var(--g3)}
nav.menu a.on::before{content:"";position:absolute;inset-inline-start:-16px;top:9px;bottom:9px;width:3px;border-radius:3px;background:linear-gradient(var(--g1),var(--g3));box-shadow:0 0 12px var(--glowc)}
.side-foot{margin-top:auto;padding:14px;border:1px solid var(--bd);border-radius:16px;background:var(--card2);font-size:12px}
.side-foot .row{display:flex;justify-content:space-between;gap:8px;color:var(--mu)}
.side-foot b{color:var(--tx)}
/* main */
.main{min-width:0;padding:22px 26px 40px}
.top{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:20px}
.ptitle{font-size:22px;font-weight:900;margin:0}.psub{color:var(--mu);font-size:12.5px}
.tools{display:flex;gap:8px;align-items:center}
.pill{display:inline-flex;align-items:center;gap:8px;padding:7px 14px;border-radius:99px;border:1px solid var(--bd);background:var(--card);font-size:12.5px;font-weight:700;white-space:nowrap}
.dot{width:9px;height:9px;border-radius:50%;background:var(--mu2);flex:none}
.dot.ok{background:var(--ok);box-shadow:0 0 10px var(--ok)}.dot.bad{background:var(--bad);box-shadow:0 0 10px var(--bad)}.dot.idle{background:var(--warn);box-shadow:0 0 10px var(--warn)}
button,.btn{font:inherit;cursor:pointer;border:1px solid var(--bd);background:var(--card);color:var(--tx);border-radius:12px;padding:8px 14px;white-space:nowrap;transition:transform .1s,border-color .2s,filter .2s,background .2s}
button:hover{border-color:var(--bd2)}button:active{transform:scale(.97)}button:disabled{opacity:.55;cursor:wait}
.gold{border:0;color:var(--onG);font-weight:800;background:linear-gradient(135deg,var(--g1),var(--g2) 55%,var(--g3));box-shadow:0 6px 18px rgba(212,175,55,.30)}
:root[data-theme=light] .gold{color:#fff}
.gold:hover{filter:brightness(1.08)}
.danger{border-color:rgba(248,113,113,.4);color:var(--bad);background:rgba(248,113,113,.08)}
.icon{display:grid;place-items:center;padding:8px 10px}
.page{display:none;flex-direction:column;gap:18px;animation:fade .35s ease}
.page.on{display:flex}
@keyframes fade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.card{background:var(--card);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border:1px solid var(--bd);border-radius:22px;box-shadow:var(--sh);padding:20px 22px;position:relative;min-width:0}
.card.glowtop::before{content:"";position:absolute;inset:0 22px auto;height:1px;background:linear-gradient(90deg,transparent,var(--g2),transparent);opacity:.7}
h2{font-size:15px;margin:0;font-weight:900}
.ch{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:14px;flex-wrap:wrap}
.mu{color:var(--mu)}.small{font-size:12px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:18px}
.grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:18px}
/* hero */
.hero{display:flex;align-items:center;justify-content:space-between;gap:20px 34px;flex-wrap:wrap;overflow:hidden}
.hero::after{content:"";position:absolute;width:420px;height:420px;inset-inline-start:-140px;top:-220px;background:radial-gradient(circle,rgba(212,175,55,.16),transparent 65%);pointer-events:none}
.orbw{display:flex;align-items:center;gap:18px;position:relative;z-index:1}
.orb{flex:none;width:62px;height:62px;border-radius:50%;display:grid;place-items:center;background:radial-gradient(circle at 35% 30%,rgba(255,255,255,.35),transparent 45%),var(--mu2);position:relative}
.orb::after{content:"";position:absolute;inset:-8px;border-radius:50%;border:2px solid currentColor;opacity:0;animation:ring 2.2s ease-out infinite}
.orb.ok{background:radial-gradient(circle at 35% 30%,rgba(255,255,255,.45),transparent 45%),linear-gradient(135deg,#6ee7b7,#059669);color:var(--ok);box-shadow:0 0 30px rgba(52,211,153,.45)}
.orb.bad{background:radial-gradient(circle at 35% 30%,rgba(255,255,255,.45),transparent 45%),linear-gradient(135deg,#fca5a5,#dc2626);color:var(--bad);box-shadow:0 0 30px rgba(248,113,113,.45)}
.orb.idle{background:radial-gradient(circle at 35% 30%,rgba(255,255,255,.45),transparent 45%),linear-gradient(135deg,var(--g1),var(--g3));color:var(--g2);box-shadow:0 0 30px var(--glowc)}
@keyframes ring{0%{transform:scale(.8);opacity:.9}100%{transform:scale(1.35);opacity:0}}
.htitle{font-size:20px;font-weight:900}.hsub{color:var(--mu);font-size:12.5px}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.chip{font-size:11.5px;padding:2px 10px;border-radius:99px;border:1px solid var(--bd);color:var(--mu);background:var(--card2)}
.chip.hl{color:var(--g1);border-color:var(--bd2)}:root[data-theme=light] .chip.hl{color:var(--g3)}
.kpis{display:grid;grid-template-columns:repeat(5,auto);gap:10px 30px;position:relative;z-index:1}
.kpi .l{font-size:11.5px;color:var(--mu)}.kpi .v{font-size:19px;font-weight:900}
/* gauges */
.gauge{display:flex;flex-direction:column;align-items:center;padding:22px 12px 18px}
.gw{position:relative;width:160px;height:160px}
.g{width:100%;height:100%;display:block;overflow:visible}
.g circle{fill:none;stroke-width:9;stroke-linecap:round}
.g .trk{stroke:var(--track)}
.g .val{transition:stroke-dashoffset .9s cubic-bezier(.2,.8,.2,1);filter:drop-shadow(0 0 6px var(--glowc))}
.gc{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;padding-bottom:6px}
.gv{font-size:30px;font-weight:900;line-height:1.1}.gu{font-size:12px;color:var(--mu);font-weight:700}
.gl{margin-top:-8px;font-weight:900}.gs{font-size:11.5px;color:var(--mu);margin-top:2px;text-align:center}
/* charts */
.legend{display:flex;gap:14px;font-size:12px;color:var(--mu);align-items:center;flex-wrap:wrap}
.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-inline-end:6px;vertical-align:-1px}
.live{display:inline-flex;align-items:center;gap:6px;font-size:11px;color:var(--g1);font-weight:800;letter-spacing:1px}
:root[data-theme=light] .live{color:var(--g3)}
.live::before{content:"";width:7px;height:7px;border-radius:50%;background:var(--g2);box-shadow:0 0 8px var(--g2);animation:blink 1.4s infinite}
@keyframes blink{50%{opacity:.25}}
.cbox{position:relative;direction:ltr}canvas{display:block;width:100%}
#cBw{height:260px}#cLat{height:180px}#cDays{height:240px}
.tip{position:absolute;top:4px;pointer-events:none;background:var(--card);backdrop-filter:blur(10px);border:1px solid var(--bd2);color:var(--tx);font-size:12px;line-height:1.8;padding:8px 12px;border-radius:12px;opacity:0;transition:opacity .15s;white-space:nowrap;direction:rtl;box-shadow:var(--sh);z-index:2}
/* lists */
.tl{list-style:none;margin:0;padding:0;max-height:300px;overflow:auto}
.tl li{display:flex;justify-content:space-between;gap:10px;padding:10px 2px;border-bottom:1px dashed var(--bd);font-size:13px}
.tl li:last-child{border:0}
.ev{display:flex;align-items:center;gap:9px;font-weight:800}.ev i{width:9px;height:9px;border-radius:50%}
.empty{color:var(--mu);font-size:13px;padding:14px 0;text-align:center}
/* stat cards */
.stat .l{color:var(--mu);font-size:12px}.stat .v{font-size:23px;font-weight:900;margin-top:4px}.stat .s{font-size:12px;color:var(--mu);margin-top:2px}
.stat .ic{position:absolute;inset-inline-end:18px;top:18px;width:38px;height:38px;border-radius:12px;display:grid;place-items:center;background:var(--track);color:var(--g2)}
/* table */
.tbl{width:100%;border-collapse:separate;border-spacing:0;font-size:13px}
.tbl th{color:var(--mu);font-weight:700;font-size:12px;text-align:start;padding:10px 12px;border-bottom:1px solid var(--bd);white-space:nowrap}
.tbl td{padding:12px;border-bottom:1px dashed var(--bd);white-space:nowrap}
.tbl tr:last-child td{border-bottom:0}.tbl tbody tr:hover td{background:var(--track)}
.pbadge{display:inline-flex;align-items:center;gap:7px;font-weight:900}
.pbadge i{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 8px var(--ok)}
.pbadge.off i{background:var(--mu2);box-shadow:none}
.share{height:7px;min-width:90px;background:var(--track);border-radius:99px;overflow:hidden}
.share b{display:block;height:100%;background:linear-gradient(270deg,var(--g1),var(--g3));border-radius:99px;box-shadow:0 0 10px var(--glowc)}
.tw{overflow-x:auto;margin:0 -6px;padding:0 6px}
.note{display:flex;gap:12px;align-items:flex-start;padding:14px 16px;border-radius:16px;border:1px solid var(--bd);background:var(--card2);font-size:12.5px;color:var(--mu)}
.note b{color:var(--tx)}
/* forms / manage */
.mgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}
.mbox{border:1px solid var(--bd);border-radius:18px;padding:16px;display:flex;flex-direction:column;gap:11px;min-width:0;background:var(--card2)}
.mbox.wide{grid-column:span 2}.mbox.full{grid-column:1/-1}
.mt{font-weight:900;font-size:13.5px;display:flex;align-items:center;gap:8px}.mt svg{color:var(--g2)}
.mh{font-size:11.5px;color:var(--mu)}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.row .inp{flex:1;min-width:110px}
.inp{font:inherit;width:100%;background:var(--in);color:var(--tx);border:1px solid var(--bd);border-radius:12px;padding:9px 12px;outline:none;transition:border-color .2s,box-shadow .2s}
.inp:focus{border-color:var(--g2);box-shadow:0 0 0 4px rgba(212,175,55,.13)}
textarea.inp{resize:vertical;font-size:11px;direction:ltr;word-break:break-all}
select.inp{appearance:none;cursor:pointer}
.seg{display:flex;border:1px solid var(--bd);border-radius:13px;overflow:hidden;background:var(--in)}
.seg button{flex:1;border:0;border-radius:0;background:transparent;padding:9px 6px;color:var(--mu);font-weight:700}
.seg button+button{border-inline-start:1px solid var(--bd)}
.seg button.on{background:linear-gradient(135deg,var(--g1),var(--g2) 55%,var(--g3));color:var(--onG)}
:root[data-theme=light] .seg button.on{color:#fff}
.plist{display:flex;flex-wrap:wrap;gap:7px}
.pchip{display:inline-flex;align-items:center;gap:4px;background:var(--track);border:1px solid var(--bd);border-radius:99px;padding:3px 13px 3px 5px;font-weight:900;font-size:13px}
.pchip.perr{background:rgba(248,113,113,.12);color:var(--bad);border-color:rgba(248,113,113,.35)}
.pchip button{border:0;background:transparent;padding:0 6px;color:var(--bad);font-size:13px;line-height:1.5}
.lbl{font-size:12px;color:var(--mu);margin-bottom:-4px}
.switch{display:inline-flex;align-items:center;gap:10px;cursor:pointer;user-select:none;font-size:13px}
.switch input{display:none}.switch span{width:40px;height:22px;border-radius:99px;background:var(--track);border:1px solid var(--bd);position:relative;transition:.2s}
.switch span::after{content:"";position:absolute;top:2px;inset-inline-start:2px;width:16px;height:16px;border-radius:50%;background:var(--mu);transition:.2s}
.switch input:checked+span{background:linear-gradient(135deg,var(--g1),var(--g3));border-color:transparent}
.switch input:checked+span::after{inset-inline-start:20px;background:#fff}
/* wizard */
.roles{display:grid;grid-template-columns:1fr 1fr;gap:18px}
.rolecard{cursor:pointer;text-align:center;padding:30px 20px;border:1px solid var(--bd);border-radius:22px;background:var(--card2);transition:transform .2s,border-color .2s,box-shadow .2s}
.rolecard:hover{transform:translateY(-3px);border-color:var(--bd2);box-shadow:0 0 34px rgba(212,175,55,.14)}
.rolecard.on{border-color:var(--g2);box-shadow:0 0 0 1px var(--g2),0 0 40px rgba(212,175,55,.2)}
.rolecard .ri{width:64px;height:64px;margin:0 auto 12px;border-radius:20px;display:grid;place-items:center;color:var(--onG);background:linear-gradient(135deg,var(--g1),var(--g2) 55%,var(--g3));box-shadow:0 8px 24px var(--glowc)}
.rolecard h3{margin:0 0 4px;font-size:17px}.rolecard p{margin:0;color:var(--mu);font-size:12.5px}
pre.console{margin:0;background:#050504;color:#e8dfc6;border:1px solid var(--bd);border-radius:16px;padding:14px;max-height:340px;overflow:auto;direction:ltr;text-align:left;font:11.5px/1.65 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-all}
.le{color:#f87171}.lw{color:#fbbf24}.lo{color:#4ade80}.lg{color:#f2c94c}
.tabs{display:flex;gap:6px;flex-wrap:wrap}
.tabs button{border-radius:99px;padding:7px 16px;color:var(--mu);font-weight:700}
.tabs button.on{color:var(--onG);border-color:transparent;background:linear-gradient(135deg,var(--g1),var(--g2) 55%,var(--g3))}
:root[data-theme=light] .tabs button.on{color:#fff}
.themes{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.tcard{cursor:pointer;border-radius:18px;border:1px solid var(--bd);padding:12px;background:var(--card2);transition:border-color .2s,box-shadow .2s}
.tcard.on{border-color:var(--g2);box-shadow:0 0 0 1px var(--g2),0 0 26px rgba(212,175,55,.18)}
.tprev{height:86px;border-radius:12px;margin-bottom:10px;position:relative;overflow:hidden}
.tprev.d{background:radial-gradient(200px 90px at 85% 0,rgba(212,175,55,.35),transparent 70%),#0a0907}
.tprev.l{background:radial-gradient(200px 90px at 85% 0,rgba(230,195,92,.55),transparent 70%),#f8f4ea;border:1px solid rgba(166,124,27,.18)}
.tprev i{position:absolute;bottom:12px;inset-inline-start:12px;width:58%;height:10px;border-radius:99px;background:linear-gradient(90deg,#f7e08a,#d4af37,#a67c1b);box-shadow:0 0 12px rgba(212,175,55,.6)}
.tprev u{position:absolute;top:14px;inset-inline-start:12px;width:30px;height:30px;border-radius:9px;background:linear-gradient(135deg,#f7e08a,#a67c1b)}
.info{display:grid;grid-template-columns:auto 1fr;gap:8px 18px;font-size:13px}.info dt{color:var(--mu)}.info dd{margin:0;font-weight:800;text-align:right}
.toast{position:fixed;bottom:24px;left:50%;transform:translate(-50%,20px);background:var(--card);backdrop-filter:blur(12px);border:1px solid var(--bd2);color:var(--tx);padding:11px 20px;border-radius:14px;font-size:13px;font-weight:700;opacity:0;transition:.25s;pointer-events:none;z-index:50;box-shadow:var(--sh)}
.toast.show{opacity:1;transform:translate(-50%,0)}
.busy .mbox button,.busy .rolecard{pointer-events:none;opacity:.55}
.bnav{display:none}
@media(max-width:1100px){.grid4{grid-template-columns:repeat(2,1fr)}.mgrid{grid-template-columns:1fr 1fr}.kpis{grid-template-columns:repeat(3,auto)}}
@media(max-width:900px){
 .app{grid-template-columns:1fr}.side{display:none}.main{padding:16px 14px 96px}
 .bnav{display:flex;position:fixed;bottom:0;left:0;right:0;z-index:40;background:var(--side);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);border-top:1px solid var(--bd);padding:6px 6px calc(6px + env(safe-area-inset-bottom))}
 .bnav a{flex:1;display:flex;flex-direction:column;align-items:center;gap:2px;padding:6px 0;color:var(--mu);text-decoration:none;font-size:10.5px;font-weight:700;border-radius:12px}
 .bnav a.on{color:var(--g1);background:var(--track)}:root[data-theme=light] .bnav a.on{color:var(--g3)}
 .grid2,.roles{grid-template-columns:1fr}.mbox.wide{grid-column:auto}
 .mobrand{display:flex!important}
}
@media(max-width:560px){.grid4{gap:12px}.gw{width:132px;height:132px}.gv{font-size:24px}.kpis{grid-template-columns:repeat(2,1fr);width:100%}
 .mgrid{grid-template-columns:1fr}.card{padding:16px}.ptitle{font-size:18px}#cBw{height:220px}.hide-sm{display:none}.themes{grid-template-columns:1fr 1fr}}
.mobrand{display:none;align-items:center;gap:10px}.mobrand .logo{width:38px;height:38px;border-radius:12px}

/* ================= GLASS THEME ================= */
:root{--glass:linear-gradient(145deg,rgba(255,255,255,.085),rgba(255,255,255,.025));--glass2:linear-gradient(145deg,rgba(255,255,255,.06),rgba(255,255,255,.015));
--gbd:rgba(255,255,255,.10);--gin:inset 0 1px 0 rgba(255,255,255,.10),inset 0 0 0 1px rgba(255,255,255,.02);
--gsh:0 24px 60px rgba(0,0,0,.50),0 0 50px rgba(212,175,55,.05);--edge:rgba(247,224,138,.55);--in:rgba(0,0,0,.28);--side:rgba(14,12,9,.42)}
:root[data-theme=light]{--glass:linear-gradient(145deg,rgba(255,255,255,.72),rgba(255,255,255,.38));--glass2:linear-gradient(145deg,rgba(255,255,255,.62),rgba(255,255,255,.28));
--gbd:rgba(255,255,255,.75);--gin:inset 0 1px 0 rgba(255,255,255,.95),inset 0 0 0 1px rgba(255,255,255,.35);
--gsh:0 20px 50px rgba(140,100,20,.14),0 0 40px rgba(230,195,92,.12);--edge:rgba(184,134,11,.55);--in:rgba(255,255,255,.55);--side:rgba(255,252,243,.45)}
/* floating gold lights behind the glass */
.orbs{position:fixed;inset:0;z-index:-1;overflow:hidden;pointer-events:none}
.orbs i{position:absolute;border-radius:50%;filter:blur(70px);opacity:.55;animation:drift 26s ease-in-out infinite alternate}
.orbs i:nth-child(1){width:520px;height:520px;top:-140px;right:-80px;background:radial-gradient(circle,#d4af37,transparent 70%)}
.orbs i:nth-child(2){width:460px;height:460px;bottom:-160px;left:-120px;background:radial-gradient(circle,#b8860b,transparent 70%);animation-duration:32s}
.orbs i:nth-child(3){width:380px;height:380px;top:40%;left:38%;background:radial-gradient(circle,#f7e08a,transparent 70%);opacity:.22;animation-duration:38s}
.orbs i:nth-child(4){width:300px;height:300px;top:12%;left:8%;background:radial-gradient(circle,#e9a23b,transparent 70%);opacity:.25;animation-duration:29s}
:root[data-theme=light] .orbs i{opacity:.45}:root[data-theme=light] .orbs i:nth-child(3){opacity:.35}
@keyframes drift{0%{transform:translate(0,0) scale(1)}50%{transform:translate(60px,40px) scale(1.12)}100%{transform:translate(-50px,70px) scale(.95)}}
@media (prefers-reduced-motion:reduce){.orbs i{animation:none}}
body{background:var(--bg)}
/* glass surfaces */
.card,.side-foot,.mbox,.rolecard,.tcard,.note,.pill{background:var(--glass);border:1px solid var(--gbd);box-shadow:var(--gin),var(--gsh);
 backdrop-filter:blur(22px) saturate(160%);-webkit-backdrop-filter:blur(22px) saturate(160%)}
.mbox,.note,.pill,.side-foot{background:var(--glass2);box-shadow:var(--gin)}
.card{border-radius:24px}
.card::after{content:"";position:absolute;inset:0;width:auto;height:auto;border-radius:inherit;padding:1px;pointer-events:none;
 background:linear-gradient(140deg,var(--edge),rgba(255,255,255,.10) 28%,transparent 55%,rgba(212,175,55,.22));
 -webkit-mask:linear-gradient(#000 0 0) content-box,linear-gradient(#000 0 0);-webkit-mask-composite:xor;mask-composite:exclude}
.card.glowtop::before{inset:0 30px auto;height:1px;opacity:1;background:linear-gradient(90deg,transparent,var(--g1),transparent)}
.side{background:var(--side);backdrop-filter:blur(26px) saturate(160%);-webkit-backdrop-filter:blur(26px) saturate(160%);border-inline-end:1px solid var(--gbd);box-shadow:inset 1px 0 0 rgba(255,255,255,.04)}
.bnav{background:var(--side)!important;backdrop-filter:blur(26px) saturate(160%)!important}
nav.menu a.on{background:var(--glass);box-shadow:var(--gin);border:1px solid var(--gbd)}
nav.menu a{border:1px solid transparent}
.rolecard:hover,.tcard:hover{box-shadow:var(--gin),0 0 0 1px var(--edge),0 18px 50px rgba(212,175,55,.18)}
pre.console{background:rgba(0,0,0,.55);backdrop-filter:blur(10px);border-color:var(--gbd);box-shadow:inset 0 2px 12px rgba(0,0,0,.35)}
:root[data-theme=light] pre.console{background:rgba(26,22,14,.86)}
.tbl tbody tr:hover td{background:rgba(212,175,55,.07)}
/* glass inputs */
.inp,select.inp{background:var(--in);border:1px solid var(--gbd);box-shadow:inset 0 1px 3px rgba(0,0,0,.18);backdrop-filter:blur(8px)}
.inp:focus{border-color:var(--g2);box-shadow:0 0 0 4px rgba(212,175,55,.16),inset 0 1px 3px rgba(0,0,0,.18)}
/* glass buttons */
button,.btn{position:relative;overflow:hidden;border-radius:14px;background:var(--glass);border:1px solid var(--gbd);
 box-shadow:var(--gin),0 4px 14px rgba(0,0,0,.18);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);font-weight:700;
 transition:transform .18s cubic-bezier(.2,.8,.2,1),box-shadow .25s,border-color .25s,filter .25s}
button:hover{transform:translateY(-2px);border-color:var(--edge);box-shadow:var(--gin),0 10px 26px rgba(0,0,0,.25),0 0 22px rgba(212,175,55,.18)}
button:active{transform:translateY(0) scale(.97)}
button::before{content:"";position:absolute;top:0;bottom:0;left:-75%;width:45%;pointer-events:none;
 background:linear-gradient(100deg,transparent,rgba(255,255,255,.28),transparent);transform:skewX(-20deg);transition:left .7s ease}
button:hover::before{left:130%}
.gold{border:1px solid rgba(255,240,190,.55)!important;color:#1a1406!important;
 background:linear-gradient(180deg,rgba(255,255,255,.35),rgba(255,255,255,0) 48%),linear-gradient(135deg,#fbe9a2,#e6c35c 30%,#d4af37 55%,#a67c1b)!important;
 box-shadow:inset 0 1px 0 rgba(255,255,255,.75),inset 0 -3px 8px rgba(120,80,0,.35),0 8px 24px rgba(212,175,55,.38)!important;text-shadow:0 1px 0 rgba(255,255,255,.35)}
.gold:hover{filter:brightness(1.06) saturate(1.1);box-shadow:inset 0 1px 0 rgba(255,255,255,.8),inset 0 -3px 8px rgba(120,80,0,.35),0 14px 34px rgba(212,175,55,.5)!important}
.gold::before{background:linear-gradient(100deg,transparent,rgba(255,255,255,.7),transparent)}
.danger{background:linear-gradient(145deg,rgba(248,113,113,.16),rgba(248,113,113,.05))!important;border-color:rgba(248,113,113,.35)!important;color:var(--bad)!important}
.danger:hover{box-shadow:var(--gin),0 0 24px rgba(248,113,113,.25)!important;border-color:rgba(248,113,113,.6)!important}
.icon{width:42px;height:42px;padding:0;border-radius:14px}
/* glass segmented controls & tabs */
.seg{background:var(--in);border:1px solid var(--gbd);border-radius:15px;padding:4px;gap:4px;box-shadow:inset 0 1px 3px rgba(0,0,0,.2)}
.seg button{border:0!important;border-radius:11px!important;background:transparent;box-shadow:none;backdrop-filter:none;padding:8px 6px}
.seg button+button{border-inline-start:0!important}
.seg button:hover{transform:none;box-shadow:none;background:rgba(212,175,55,.08)}
.seg button.on,.tabs button.on{color:#1a1406!important;background:linear-gradient(180deg,rgba(255,255,255,.35),rgba(255,255,255,0) 50%),linear-gradient(135deg,#fbe9a2,#e6c35c 30%,#d4af37 60%,#a67c1b)!important;
 box-shadow:inset 0 1px 0 rgba(255,255,255,.7),0 4px 14px rgba(212,175,55,.35)!important}
.tabs button{border-radius:99px}
.pchip{background:var(--glass);border:1px solid var(--gbd);box-shadow:var(--gin);backdrop-filter:blur(8px)}
.pchip button{box-shadow:none;backdrop-filter:none;background:transparent;border:0;border-radius:99px}
.pchip button:hover{transform:none;box-shadow:none;background:rgba(248,113,113,.15)}
.switch span{background:var(--in);border-color:var(--gbd);box-shadow:inset 0 1px 3px rgba(0,0,0,.25)}
.switch input:checked+span{background:linear-gradient(135deg,#fbe9a2,#d4af37,#a67c1b);box-shadow:0 0 14px rgba(212,175,55,.45)}
.logo{box-shadow:inset 0 1px 0 rgba(255,255,255,.7),inset 0 -3px 8px rgba(120,80,0,.3),0 10px 28px var(--glowc)}
.stat .ic{background:var(--glass);border:1px solid var(--gbd);box-shadow:var(--gin)}
.toast{background:var(--glass);border:1px solid var(--edge);backdrop-filter:blur(20px)}
.tip{background:var(--glass);border:1px solid var(--edge);backdrop-filter:blur(18px)}
</style></head><body>
<div class="orbs"><i></i><i></i><i></i><i></i></div>
<div class="app">
<aside class="side">
 <div class="brand">
  <div class="logo"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2l8.5 5v10L12 22l-8.5-5V7z"/><path d="M8 12h8M13 9l3 3-3 3"/></svg></div>
  <div><div class="bname gt">Over-Tun</div><div class="bteam">OVERAL-TEAM</div></div>
 </div>
 <nav class="menu" id="menu"></nav>
 <div class="side-foot">
  <div class="row"><span>وضعیت</span><b id="sfState">—</b></div>
  <div class="row"><span>سرور</span><b id="sfRole">—</b></div>
  <div class="row"><span>نسخه</span><b class="num" id="sfVer">—</b></div>
 </div>
</aside>
<div class="main">
 <header class="top">
  <div class="mobrand"><div class="logo"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2l8.5 5v10L12 22l-8.5-5V7z"/><path d="M8 12h8M13 9l3 3-3 3"/></svg></div></div>
  <div style="min-width:0;flex:1"><h1 class="ptitle" id="pTitle">داشبورد</h1><div class="psub" id="pSub"></div></div>
  <div class="tools">
   <span class="pill"><span class="dot" id="hdDot"></span><span id="hdTxt">…</span></span>
   <button class="icon" id="thBtn" title="تغییر تم" aria-label="تغییر تم"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg></button>
   <button class="icon" onclick="logout()" title="خروج" aria-label="خروج"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg></button>
  </div>
 </header>

 <!-- ===================== DASHBOARD ===================== -->
 <section class="page" id="p-dash">
  <div class="card hero glowtop">
   <div class="orbw"><div class="orb" id="orb"></div>
    <div><div class="htitle" id="hTitle">در حال بارگذاری…</div><div class="hsub" id="hSub"></div><div class="chips" id="hChips"></div></div></div>
   <div class="kpis">
    <div class="kpi"><div class="l">پینگ</div><div class="v num" id="kPing">—</div></div>
    <div class="kpi"><div class="l">مدت اتصال</div><div class="v num" id="kUp">—</div></div>
    <div class="kpi"><div class="l">کاربران فعال</div><div class="v num" id="kConn">—</div></div>
    <div class="kpi"><div class="l">ری‌استارت</div><div class="v num" id="kRs">—</div></div>
    <div class="kpi"><div class="l">کل قطعی</div><div class="v num" id="kDown">—</div></div>
   </div>
  </div>
  <div class="grid4" id="gauges"></div>
  <div class="card">
   <div class="ch"><h2>ترافیک زنده سرور</h2><div class="legend"><span><i style="background:var(--dl)"></i>دریافت</span><span><i style="background:var(--ul)"></i>ارسال</span><span class="live">LIVE</span></div></div>
   <div class="cbox"><canvas id="cBw"></canvas><div class="tip" id="tip"></div></div>
  </div>
  <div class="grid2">
   <div class="card"><div class="ch"><h2>پینگ تا سرور مقابل</h2><span class="mu small num" id="pingAvg"></span></div><div class="cbox"><canvas id="cLat"></canvas></div></div>
   <div class="card"><div class="ch"><h2>آخرین رویدادها</h2><a href="#logs" onclick="setTimeout(()=>logTab('ev'),50)" class="mu small">همه ←</a></div><ul class="tl" id="dEv"></ul></div>
  </div>
 </section>

 <!-- ===================== TRAFFIC ===================== -->
 <section class="page" id="p-traffic">
  <div class="grid4">
   <div class="card stat"><div class="ic"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M12 4v13M6 11l6 6 6-6M5 20h14"/></svg></div><div class="l">دانلود کاربران امروز</div><div class="v num gt" id="tTodayD">—</div><div class="s" id="tTodayU"></div></div>
   <div class="card stat"><div class="ic"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><rect x="3" y="5" width="18" height="16" rx="3"/><path d="M3 10h18M8 3v4M16 3v4"/></svg></div><div class="l">۷ روز اخیر</div><div class="v num" id="tWeek">—</div><div class="s" id="tWeekS"></div></div>
   <div class="card stat"><div class="ic"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M3 3v18h18M7 15l4-4 3 3 5-6"/></svg></div><div class="l">کل مصرف</div><div class="v num" id="tTotal">—</div><div class="s" id="tSince"></div></div>
   <div class="card stat"><div class="ic"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6 6 0 0 1 3.5 6"/></svg></div><div class="l">کاربران فعال الان</div><div class="v num" id="tConns">—</div><div class="s" id="tPorts"></div></div>
  </div>
  <div class="card">
   <div class="ch"><h2>مصرف ۱۴ روز اخیر</h2><div class="legend"><span><i style="background:var(--dl)"></i>دانلود کاربران</span><span><i style="background:var(--ul)"></i>آپلود کاربران</span></div></div>
   <div class="cbox"><canvas id="cDays"></canvas><div class="tip" id="tip2"></div></div>
  </div>
  <div class="card">
   <div class="ch"><h2>مصرف هر پورت (اینباند)</h2><button class="small danger" onclick="resetTraffic()">صفر کردن آمار</button></div>
   <div class="tw"><table class="tbl"><thead><tr><th>پورت</th><th>کاربران فعال</th><th>امروز ↓</th><th>امروز ↑</th><th>۷ روز</th><th>کل</th><th>سهم مصرف</th></tr></thead><tbody id="tRows"></tbody></table></div>
  </div>
  <div class="note"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" style="flex:none;color:var(--g2)"><circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16.5v.5"/></svg>
   <div id="tNote">این اعداد <b>ترافیک واقعی کاربران</b> روی هر پورت است؛ همان عددی که پنل x-ui نشان می‌دهد. سربار خود تانل روی دانلودهای بزرگ حدود <b>۰.۱۵٪</b> است و تانل مصرف جداگانه‌ای ندارد. توجه: چون سرور ایران واسطه است، شرکت سرور ممکن است ورود و خروج را جدا حساب کند.</div></div>
 </section>

 <!-- ===================== TUNNEL ===================== -->
 <section class="page" id="p-tunnel">
  <div id="tunNew" hidden>
   <div class="card glowtop">
    <div class="ch"><h2>ساخت تانل جدید</h2><span class="mu small">اول روی سرور ایران بسازید، بعد کد را روی سرور خارج وارد کنید</span></div>
    <div class="roles">
     <div class="rolecard" data-r="iran" onclick="pickRole('iran')"><div class="ri"><svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/></svg></div><h3>سرور ایران</h3><p>کاربران به این سرور وصل می‌شوند</p></div>
     <div class="rolecard" data-r="kharej" onclick="pickRole('kharej')"><div class="ri"><svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/></svg></div><h3>سرور خارج</h3><p>با کد اتصال به سرور ایران وصل می‌شود</p></div>
    </div>
   </div>
   <div class="card" id="fIran" hidden>
    <div class="ch"><h2>تنظیمات سرور ایران</h2></div>
    <div class="mgrid">
     <div class="mbox"><div class="lbl">روش تانل</div><div class="seg" id="wMethod"><button data-v="tls" class="on">TLS</button><button data-v="wss">WSS</button><button data-v="quic">QUIC</button><button data-v="kcp">KCP</button></div><div class="mh" id="wMethodH">TLS: رمزنگاری کامل و سریع‌ترین گزینه (پیشنهادی)</div></div>
     <div class="mbox"><div class="lbl">حالت سرعت</div><div class="seg" id="wMode"><button data-v="medium">Medium</button><button data-v="turbo" class="on">Turbo</button><button data-v="advanced">Advanced</button></div><div class="mh">Advanced برای سرورهای ۲ هسته به بالا</div></div>
     <div class="mbox"><div class="lbl">پورت تانل</div><input class="inp num" id="wTport" value="443" inputmode="numeric"><div class="mh">۴۴۳ طبیعی‌ترین پورت است</div></div>
     <div class="mbox"><div class="lbl">پورت‌های سرویس (با کاما)</div><input class="inp num" id="wPorts" placeholder="2022,2053"><div class="mh">پورت اینباندهای x-ui روی سرور خارج</div></div>
     <div class="mbox"><div class="lbl">دامنه پوششی (SNI)</div><input class="inp num" id="wSni" value="www.speedtest.net"></div>
     <div class="mbox"><div class="lbl">UDP</div><label class="switch"><input type="checkbox" id="wUdp"><span></span>انتقال UDP هم انجام شود</label><div class="mh">فقط برای Hysteria / TUIC / WireGuard</div></div>
    </div>
    <div class="row" style="margin-top:16px"><button class="gold" onclick="setupIran()">ساخت تانل</button></div>
   </div>
   <div class="card" id="fKharej" hidden>
    <div class="ch"><h2>اتصال سرور خارج</h2></div>
    <div class="mgrid">
     <div class="mbox"><div class="lbl">IP سرور ایران</div><input class="inp num" id="kIp" placeholder="1.2.3.4"></div>
     <div class="mbox"><div class="lbl">حالت سرعت</div><div class="seg" id="kMode"><button data-v="medium">Medium</button><button data-v="turbo" class="on">Turbo</button><button data-v="advanced">Advanced</button></div></div>
     <div class="mbox full"><div class="lbl">کد اتصال (از پنل سرور ایران)</div><textarea class="inp num" id="kCode" rows="4"></textarea></div>
    </div>
    <div class="row" style="margin-top:16px"><button class="gold" onclick="setupKharej()">اتصال</button></div>
   </div>
  </div>

  <div id="tunHave" hidden>
   <div class="card glowtop">
    <div class="ch"><h2>مشخصات تانل</h2><span class="chip hl" id="tRole"></span></div>
    <dl class="info" id="tInfo"></dl>
   </div>
   <div class="card">
    <div class="ch"><h2>ویرایش تانل</h2></div>
    <div class="mgrid">
     <div class="mbox"><div class="mt">کنترل تانل</div>
      <div class="row"><button onclick="act('restart',[],'تانل ری‌استارت شود؟')">⟳ ری‌استارت</button><button onclick="act('stop',[],'تانل متوقف شود؟ همه کاربران قطع می‌شوند.')">■ توقف</button><button class="gold" onclick="act('start',[])">▶ شروع</button></div>
      <div class="mh">توقف موقت است و با «شروع» دوباره وصل می‌شود.</div></div>
     <div class="mbox"><div class="mt">حالت سرعت</div>
      <div class="seg" id="segMode"><button data-v="medium">Medium</button><button data-v="turbo">Turbo</button><button data-v="advanced">Advanced</button></div>
      <div class="mh">روی سرور دیگر هم همین حالت را انتخاب کنید.</div></div>
     <div class="mbox"><div class="mt">پورت‌های تانل</div>
      <div class="plist" id="pList"></div>
      <div class="row"><input id="pIn" class="inp num" inputmode="numeric" placeholder="مثلاً 2053"><button class="gold" onclick="addPort()">+ افزودن</button></div>
      <div class="mh">پورت را روی <b>هر دو سرور</b> اضافه یا حذف کنید.</div></div>
     <div class="mbox kh-only"><div class="mt">روش تانل</div>
      <div class="seg" id="segMethod"><button data-v="tls">TLS · سریع</button><button data-v="wss">WSS</button></div>
      <div class="mh">سرور ایران هر دو را می‌پذیرد.</div></div>
     <div class="mbox kh-only wide"><div class="mt">اتصال مجدد با کد جدید</div>
      <input id="rcIp" class="inp num" placeholder="IP سرور ایران">
      <textarea id="rcCode" class="inp num" rows="3" placeholder="کد اتصال از سرور ایران"></textarea>
      <div class="row"><button class="gold" onclick="reconnect()">اتصال</button></div></div>
     <div class="mbox ir-only wide"><div class="mt">کد اتصال (برای سرور خارج)</div>
      <textarea id="codeBox" class="inp num" rows="3" readonly></textarea>
      <div class="row"><button class="gold" onclick="copyCode()">کپی کد</button></div>
      <div class="mh">این کد مثل رمز تانل است؛ جای عمومی نفرستید.</div></div>
    </div>
    <pre class="console" id="mOut" hidden style="margin-top:16px"></pre>
   </div>
   <div class="card" style="border-color:rgba(248,113,113,.3)">
    <div class="ch"><h2 style="color:var(--bad)">حذف تانل</h2></div>
    <div class="row" style="justify-content:space-between"><span class="mu small">تانل و تنظیماتش از این سرور حذف می‌شود؛ پنل و آمار مصرف باقی می‌ماند.</span><button class="danger" onclick="removeTunnel()">حذف تانل</button></div>
   </div>
  </div>

  <div class="card" id="jobCard" hidden>
   <div class="ch"><h2 id="jobTitle">در حال اجرا…</h2><span class="pill"><span class="dot idle" id="jobDot"></span><span id="jobState">در حال اجرا</span></span></div>
   <pre class="console" id="jobLog"></pre>
   <div class="row" id="jobDone" hidden style="margin-top:14px"><button class="gold" onclick="jobClose()">بستن</button><button id="jobCopy" onclick="copyJobCode()" hidden>کپی کد اتصال</button></div>
  </div>
 </section>

 <!-- ===================== LOGS ===================== -->
 <section class="page" id="p-logs">
  <div class="card">
   <div class="ch"><div class="tabs" id="logTabs"><button data-t="tun" class="on">لاگ تانل</button><button data-t="ev">رویدادهای اتصال</button><button data-t="au">فعالیت پنل</button></div></div>
   <div id="lgTun">
    <div class="row" style="margin-bottom:12px">
     <div class="seg" id="lvl" style="min-width:230px"><button data-v="all" class="on">همه</button><button data-v="warn">هشدارها</button><button data-v="err">خطاها</button></div>
     <input class="inp" id="lgQ" placeholder="جستجو در لاگ…" style="max-width:260px">
     <select class="inp" id="lgN" style="max-width:110px"><option>100</option><option selected>300</option><option>1000</option></select>
     <label class="switch"><input type="checkbox" id="lgAuto" checked><span></span>بروزرسانی خودکار</label>
     <button onclick="loadLogs()">⟳</button><button onclick="dlLogs()">دانلود</button>
    </div>
    <pre class="console" id="lgBox" style="max-height:560px;min-height:300px"></pre>
   </div>
   <div id="lgEv" hidden><ul class="tl" id="evList" style="max-height:600px"></ul></div>
   <div id="lgAu" hidden><div class="tw"><table class="tbl"><thead><tr><th>زمان</th><th>عملیات</th><th>نتیجه</th><th>IP</th><th>جزئیات</th></tr></thead><tbody id="auRows"></tbody></table></div></div>
  </div>
 </section>

 <!-- ===================== SETTINGS ===================== -->
 <section class="page" id="p-settings">
  <div class="grid2">
   <div class="card"><div class="ch"><h2>تم پنل</h2></div>
    <div class="themes">
     <div class="tcard" data-th="dark" onclick="setTheme('dark')"><div class="tprev d"><u></u><i></i></div><b>طلایی مشکی</b><div class="mh">Black Gold</div></div>
     <div class="tcard" data-th="light" onclick="setTheme('light')"><div class="tprev l"><u></u><i></i></div><b>طلایی سفید</b><div class="mh">White Gold</div></div>
    </div></div>
   <div class="card"><div class="ch"><h2>تغییر رمز پنل</h2></div>
    <div class="mbox" style="background:none;border:0;padding:0">
     <input id="pwOld" type="password" class="inp" placeholder="رمز فعلی" autocomplete="current-password">
     <input id="pwNew" type="password" class="inp" placeholder="رمز جدید (حداقل ۸ کاراکتر)" autocomplete="new-password">
     <div class="row"><button class="gold" onclick="changePw()">ذخیره رمز</button></div></div></div>
  </div>
  <div class="grid2">
   <div class="card"><div class="ch"><h2>اطلاعات پنل</h2></div><dl class="info" id="sInfo"></dl></div>
   <div class="card"><div class="ch"><h2>آپدیت</h2></div>
    <p class="mu small" style="margin-top:0">آخرین نسخه اسکریپت و پنل از گیت‌هاب دریافت می‌شود. تانل قطع نمی‌شود؛ فقط پنل چند ثانیه ری‌استارت می‌شود.</p>
    <div class="row"><button class="gold" onclick="runUpdate()">آپدیت اسکریپت و پنل</button><button class="danger" onclick="logout()">خروج از پنل</button></div></div>
  </div>
 </section>
 <div class="mu small" style="text-align:center;margin-top:26px;direction:ltr;letter-spacing:1.5px">OVER-TUN · OVERAL-TEAM</div>
</div>
</div>
<nav class="bnav" id="bnav"></nav>
<div class="toast" id="toast"></div>
<script>
const $=id=>document.getElementById(id),root=document.documentElement;
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const css=v=>getComputedStyle(root).getPropertyValue(v).trim();
let th=null;try{th=localStorage.getItem('ot-theme')}catch(e){}
root.dataset.theme=th||'dark';
function setTheme(t){root.dataset.theme=t;try{localStorage.setItem('ot-theme',t)}catch(e){}document.querySelectorAll('.tcard').forEach(c=>c.classList.toggle('on',c.dataset.th==t));redraw();drawDays()}
$('thBtn').onclick=()=>setTheme(root.dataset.theme=='dark'?'light':'dark');

/* ---------- navigation ---------- */
const I={dash:'<path d="M3 13h8V3H3zM13 21h8V11h-8zM3 21h8v-6H3zM13 3v6h8V3z"/>',traffic:'<path d="M3 3v18h18M7 15l4-4 3 3 5-6"/>',
 tunnel:'<path d="M12 2l8.5 5v10L12 22l-8.5-5V7z"/><path d="M8 12h8M13 9l3 3-3 3"/>',logs:'<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 13h8M8 17h5"/>',
 settings:'<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>'};
const PAGES=[['dash','داشبورد','وضعیت لحظه‌ای تانل و سرور'],['traffic','مصرف پورت‌ها','ترافیک واقعی هر اینباند'],['tunnel','تانل','ساخت و ویرایش تانل'],['logs','لاگ‌ها','لاگ تانل، رویدادها و فعالیت پنل'],['settings','تنظیمات','تم، رمز و آپدیت']];
const ico=k=>`<svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${I[k]}</svg>`;
$('menu').innerHTML=PAGES.map(([k,t])=>`<a href="#${k}" data-p="${k}">${ico(k)}<span>${t}</span></a>`).join('');
$('bnav').innerHTML=PAGES.map(([k,t])=>`<a href="#${k}" data-p="${k}">${ico(k)}<span>${t}</span></a>`).join('');
let PAGE='dash';
function route(){const h=(location.hash||'#dash').slice(1);PAGE=PAGES.some(p=>p[0]==h)?h:'dash';
 document.querySelectorAll('.page').forEach(p=>p.classList.toggle('on',p.id=='p-'+PAGE));
 document.querySelectorAll('[data-p]').forEach(a=>a.classList.toggle('on',a.dataset.p==PAGE));
 const pg=PAGES.find(p=>p[0]==PAGE);$('pTitle').textContent=pg[1];$('pSub').textContent=pg[2];
 if(PAGE=='traffic')loadTraffic();if(PAGE=='tunnel'){loadCfg();pollJob()}if(PAGE=='logs')loadLogs();if(PAGE=='settings'){loadCfg();setTheme(root.dataset.theme)}
 if(PAGE=='dash')setTimeout(redraw,30);window.scrollTo({top:0})}
addEventListener('hashchange',route);

/* ---------- format ---------- */
function bits(v){const u=['bps','Kbps','Mbps','Gbps'];let i=0;v=Math.max(0,v||0);while(v>=1000&&i<3){v/=1000;i++}return[v,u[i]]}
const nfix=v=>v.toFixed(v<10?2:v<100?1:0);
const bitsStr=v=>{const[n,u]=bits(v);return(u=='bps'?n.toFixed(0):nfix(n))+' '+u};
const fB=v=>{const u=['B','KB','MB','GB','TB'];let i=0;v=v||0;while(v>=1024&&i<4){v/=1024;i++}return(i?v.toFixed(v<10?2:1):v.toFixed(0))+' '+u[i]};
const fd=s=>{s=Math.floor(s);const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60),x=s%60;return d?d+'d '+h+'h':h?h+'h '+m+'m':m?m+'m '+x+'s':x+'s'};
const ago=t=>{const s=Math.max(0,Date.now()/1000-t);return s<60?'همین الان':s<3600?Math.floor(s/60)+' دقیقه پیش':s<86400?Math.floor(s/3600)+' ساعت پیش':Math.floor(s/86400)+' روز پیش'};
const tfa=t=>new Date(t*1000).toLocaleString('fa-IR',{dateStyle:'short',timeStyle:'short'});
const MODEN={medium:'Medium',turbo:'Turbo ⚡',advanced:'Advanced 🚀'};
function toast(m){const t=$('toast');t.textContent=m;t.classList.add('show');clearTimeout(t._h);t._h=setTimeout(()=>t.classList.remove('show'),2600)}

/* ---------- gauges ---------- */
const C=2*Math.PI*50,A=C*.75;
const GA=[['cpu','پردازنده (CPU)'],['ram','حافظه (RAM)'],['dl','دریافت'],['ul','ارسال']];
$('gauges').innerHTML=GA.map(([k,t])=>`<div class="card gauge"><div class="gw"><svg class="g" viewBox="0 0 120 120"><defs><linearGradient id="gg${k}" x1="0" y1="1" x2="1" y2="0"><stop offset="0" style="stop-color:var(--g3)"/><stop offset=".55" style="stop-color:var(--g2)"/><stop offset="1" style="stop-color:var(--g1)"/></linearGradient></defs>
<circle class="trk" cx="60" cy="60" r="50" stroke-dasharray="${A} ${C}" transform="rotate(135 60 60)"/>
<circle class="val" id="${k}A" cx="60" cy="60" r="50" stroke="url(#gg${k})" stroke-dasharray="${A} ${C}" stroke-dashoffset="${A}" transform="rotate(135 60 60)"/></svg>
<div class="gc"><div class="gv num gt" id="${k}V">0</div><div class="gu num" id="${k}U">&nbsp;</div></div></div><div class="gl">${t}</div><div class="gs" id="${k}S">&nbsp;</div></div>`).join('');
const clamp=p=>Math.max(0,Math.min(1,p||0));
function arc(k,p,warn){const e=$(k+'A');e.style.strokeDashoffset=A*(1-clamp(p));e.style.stroke=warn?(p>.85?css('--bad'):css('--warn')):`url(#gg${k})`}
const cur={},raf={};
function tween(k,to,fn){const from=cur[k]??to,t0=performance.now();cancelAnimationFrame(raf[k]);
 const st=n=>{const p=Math.min((n-t0)/800,1),v=from+(to-from)*(1-Math.pow(1-p,3));cur[k]=v;fn(v);if(p<1)raf[k]=requestAnimationFrame(st)};raf[k]=requestAnimationFrame(st)}

/* ---------- charts ---------- */
function niceMax(v){if(!(v>0))return 1;const e=Math.pow(10,Math.floor(Math.log10(v))),m=v/e;return(m<=1?1:m<=2?2:m<=2.5?2.5:m<=5?5:10)*e}
function prep(cv){const dpr=window.devicePixelRatio||1,w=cv.clientWidth,h=cv.clientHeight;if(cv.width!=Math.round(w*dpr)||cv.height!=Math.round(h*dpr)){cv.width=Math.round(w*dpr);cv.height=Math.round(h*dpr)}const c=cv.getContext('2d');c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,w,h);return[c,w,h]}
function grid(c,w,h,L,T,ph,mx,fmt){const g=css('--bd'),mu=css('--mu');c.font='11px system-ui,sans-serif';c.textBaseline='middle';c.textAlign='right';
 for(let i=0;i<=4;i++){const y=T+ph-ph*i/4;c.strokeStyle=g;c.lineWidth=1;c.setLineDash(i?[3,6]:[]);c.beginPath();c.moveTo(L,y);c.lineTo(w-6,y);c.stroke();c.setLineDash([]);c.fillStyle=mu;c.fillText(fmt(mx*i/4),L-10,y)}}
function area(cv,series,colors,fmtY,hi){
 const[c,w,h]=prep(cv),L=70,T=12,B=8,pw=w-L-6,ph=h-T-B;
 let mx=0;series.forEach(s=>s.forEach(v=>{if(v!=null&&v>mx)mx=v}));mx=niceMax(mx*1.12);
 grid(c,w,h,L,T,ph,mx,fmtY);
 const n=Math.max(2,...series.map(s=>s.length)),X=i=>L+pw*(i/(n-1)),Y=v=>T+ph-ph*v/mx;
 series.forEach((s,k)=>{const col=colors[k],segs=[];let sg=[];const off=n-s.length;
  s.forEach((v,i)=>{if(v==null){if(sg.length)segs.push(sg);sg=[]}else sg.push([X(i+off),Y(v)])});if(sg.length)segs.push(sg);
  segs.forEach(sg=>{const p=new Path2D();p.moveTo(sg[0][0],sg[0][1]);
   for(let i=1;i<sg.length;i++){const[x0,y0]=sg[i-1],[x1,y1]=sg[i],m=(x0+x1)/2;p.bezierCurveTo(m,y0,m,y1,x1,y1)}
   const f=new Path2D(p);f.lineTo(sg[sg.length-1][0],T+ph);f.lineTo(sg[0][0],T+ph);f.closePath();
   const gr=c.createLinearGradient(0,T,0,T+ph);gr.addColorStop(0,col+'55');gr.addColorStop(1,col+'00');c.fillStyle=gr;c.fill(f);
   c.save();c.shadowColor=col;c.shadowBlur=10;c.strokeStyle=col;c.lineWidth=2.3;c.lineJoin='round';c.stroke(p);c.restore()});
  const lv=s[s.length-1];if(lv!=null&&hi==null){c.save();c.shadowColor=col;c.shadowBlur=14;c.fillStyle=col;c.beginPath();c.arc(X(n-1),Y(lv),4,0,7);c.fill();c.restore()}});
 if(series.every(s=>!s.some(v=>v!=null))){c.textAlign='center';c.fillStyle=css('--mu');c.font='13px Tahoma,system-ui';c.fillText('داده‌ای برای نمایش نیست',L+pw/2,T+ph/2)}
 if(hi!=null){const x=X(hi);c.strokeStyle=css('--g2');c.setLineDash([4,4]);c.beginPath();c.moveTo(x,T);c.lineTo(x,T+ph);c.stroke();c.setLineDash([]);
  series.forEach((s,k)=>{const v=s[hi-(n-s.length)];if(v==null)return;c.fillStyle=css('--bg');c.strokeStyle=colors[k];c.lineWidth=2.5;c.beginPath();c.arc(x,Y(v),5,0,7);c.fill();c.stroke()})}
 return{X,n,L,pw}}

/* ---------- live stats ---------- */
let HIST=[],LAT=[],LAST=0,ST=null,hover=null,geo=null;
async function getJSON(u){const r=await fetch(u,{cache:'no-store'});if(r.status==401){location.href='login';throw 0}return r.json()}
async function post(u,b){const r=await fetch(u,{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify(b||{})});if(r.status==401){location.href='login';throw 0}return r.json()}
function drawBw(){geo=area($('cBw'),[HIST.map(x=>x[1]),HIST.map(x=>x[2])],[css('--dl'),css('--ul')],bitsStr,hover)}
function drawLat(){area($('cLat'),[LAT.map(x=>x[1])],[css('--g2')],v=>v.toFixed(v<10?1:0)+' ms',null)}
function redraw(){if(PAGE=='dash'){drawBw();drawLat()}}
const cBw=$('cBw');
function onMove(e){if(!geo||!HIST.length)return;const r=cBw.getBoundingClientRect(),cx=(e.touches?e.touches[0].clientX:e.clientX)-r.left;
 hover=Math.max(0,Math.min(geo.n-1,Math.round((cx-geo.L)/geo.pw*(geo.n-1))));drawBw();const p=HIST[hover-(geo.n-HIST.length)];if(!p)return;const tip=$('tip');
 tip.innerHTML=`<b>${new Date(p[0]*1000).toLocaleTimeString('fa-IR')}</b><br><span style="color:var(--dl)">●</span> دریافت: <span class="num">${bitsStr(p[1])}</span><br><span style="color:var(--ul)">●</span> ارسال: <span class="num">${bitsStr(p[2])}</span>`;
 tip.style.opacity=1;tip.style.left=Math.min(Math.max(geo.X(hover)-tip.offsetWidth/2,0),cBw.clientWidth-tip.offsetWidth)+'px'}
function onLeave(){hover=null;$('tip').style.opacity=0;drawBw()}
cBw.addEventListener('mousemove',onMove);cBw.addEventListener('mouseleave',onLeave);cBw.addEventListener('touchstart',onMove,{passive:true});cBw.addEventListener('touchmove',onMove,{passive:true});cBw.addEventListener('touchend',()=>setTimeout(onLeave,1500));
if(window.ResizeObserver)new ResizeObserver(()=>{redraw();drawDays()}).observe(document.querySelector('.main'));
const EVN={up:['تانل وصل شد','var(--ok)'],down:['تانل قطع شد','var(--bad)'],start:['پایش شروع شد','var(--g2)']};
function evHtml(list){return list.length?list.map(([t,k])=>{const e=EVN[k]||[k,'var(--mu)'];return`<li><span class="ev"><i style="background:${e[1]};box-shadow:0 0 8px ${e[1]}"></i>${e[0]}</span><span class="mu small">${ago(t)} · ${tfa(t)}</span></li>`}).join(''):'<li class="empty">رویدادی ثبت نشده</li>'}
function state(d){if(!d.installed)return['idle','تانل نصب نشده','از بخش «تانل» بسازید'];if(d.up)return['ok','تانل متصل و پایدار است','وصل از '+new Date(Date.now()-d.up_for*1000).toLocaleString('fa-IR')];
 return['bad',d.active?'تانل قطع است — در حال اتصال مجدد…':'سرویس تانل خاموش است','']}
function render(d){
 ST=d;const[cls,title,sub]=state(d);
 $('hdDot').className='dot '+cls;$('hdTxt').textContent=cls=='ok'?'متصل':cls=='idle'?'نصب نشده':'قطع';
 $('sfState').textContent=$('hdTxt').textContent;$('sfRole').textContent=d.role=='iran'?'ایران':d.role=='kharej'?'خارج':'—';$('sfVer').textContent=d.version;
 if(PAGE!='dash')return;
 $('orb').className='orb '+cls;$('hTitle').textContent=title;$('hSub').textContent=sub;
 $('hChips').innerHTML=[d.role?[d.role=='iran'?'سرور ایران':'سرور خارج',1]:null,d.mode&&d.installed?[MODEN[d.mode]||d.mode,1]:null,d.transport?[d.transport.toUpperCase(),0]:null,d.tport?['Tunnel :'+d.tport,0]:null,d.peer?['⇄ '+d.peer,0]:null,[d.iface,0]].filter(Boolean).map(([x,g])=>`<span class="chip${g?' hl':''}"><bdi>${esc(x)}</bdi></span>`).join('');
 const lv=LAT.length?LAT[LAT.length-1][1]:null;const pe=$('kPing');pe.textContent=lv==null?'—':lv.toFixed(lv<10?1:0)+' ms';pe.style.color=lv==null?'':lv>150?'var(--warn)':'var(--ok)';
 $('kUp').textContent=d.up?fd(d.up_for):'—';$('kConn').textContent=Object.values(d.ports).reduce((a,b)=>a+b,0);$('kRs').textContent=d.restarts;$('kDown').textContent=fd(d.total_down);
 tween('cpu',d.cpu,v=>$('cpuV').textContent=v.toFixed(0));$('cpuU').textContent='%';arc('cpu',d.cpu/100,d.cpu>60);$('cpuS').innerHTML=`${d.cores} هسته · Load <span class="num">${d.load[0]}</span>`;
 const rp=d.mem_total?d.mem_used/d.mem_total*100:0;tween('ram',rp,v=>$('ramV').textContent=v.toFixed(0));$('ramU').textContent='%';arc('ram',rp/100,rp>60);$('ramS').innerHTML=`<span class="num">${fB(d.mem_used)} / ${fB(d.mem_total)}</span>`;
 const last=HIST[HIST.length-1]||[0,0,0];let pk=[0,0];HIST.forEach(x=>{pk[0]=Math.max(pk[0],x[1]);pk[1]=Math.max(pk[1],x[2])});
 const scale=d.link_mbps>0?d.link_mbps*1e6:Math.max(niceMax(Math.max(...pk)*1.1),10e6);
 [['dl',1,0],['ul',2,1]].forEach(([k,i,j])=>{tween(k,last[i],v=>{const[n,u]=bits(v);$(k+'V').textContent=u=='bps'?n.toFixed(0):nfix(n);$(k+'U').textContent=u});arc(k,last[i]/scale,false);
  $(k+'S').innerHTML=(d.link_mbps>0?'ظرفیت ':'پیک ۲.۵ دقیقه: ')+`<span class="num">${bitsStr(d.link_mbps>0?scale:pk[j])}</span>`});
 $('dEv').innerHTML=evHtml(d.events.slice(0,8));
 const lv2=LAT.map(x=>x[1]).filter(v=>v!=null);$('pingAvg').textContent=lv2.length?'avg '+(lv2.reduce((a,b)=>a+b,0)/lv2.length).toFixed(1)+' ms':'';
 if(hover==null)drawBw();drawLat()}
async function tick(){
 try{const d=await getJSON('api/stats?since='+LAST);HIST=HIST.concat(d.hist).slice(-150);LAT=LAT.concat(d.lat).slice(-100);
  if(d.hist.length)LAST=d.hist[d.hist.length-1][0];render(d)}
 catch(e){if(e!==0){$('hdDot').className='dot bad';$('hdTxt').textContent='پنل در دسترس نیست'}}
 setTimeout(tick,PAGE=='dash'?1000:3000)}

/* ---------- traffic ---------- */
let TR=null,dayGeo=null;
async function loadTraffic(){try{TR=await getJSON('api/traffic')}catch(e){return}
 const rows=TR.rows,sum=(f,i)=>rows.reduce((a,r)=>a+r[f][i],0);
 $('tTodayD').textContent=fB(sum('today',1));$('tTodayU').innerHTML='آپلود: <span class="num">'+fB(sum('today',0))+'</span>';
 $('tWeek').textContent=fB(sum('week',0)+sum('week',1));$('tWeekS').innerHTML='↓ <span class="num">'+fB(sum('week',1))+'</span> · ↑ <span class="num">'+fB(sum('week',0))+'</span>';
 $('tTotal').textContent=fB(sum('total',0)+sum('total',1));$('tSince').textContent=TR.since?'از '+new Date(TR.since*1000).toLocaleDateString('fa-IR'):'';
 $('tConns').textContent=rows.reduce((a,r)=>a+(r.conns||0),0);$('tPorts').textContent=rows.filter(r=>r.active).length+' پورت فعال';
 const tot=Math.max(1,sum('total',0)+sum('total',1));
 $('tRows').innerHTML=rows.length?rows.map(r=>{const t=r.total[0]+r.total[1];return`<tr><td><span class="pbadge${r.active?'':' off'} num"><i></i>${r.port}</span></td><td class="num">${r.conns||0}</td><td class="num">${fB(r.today[1])}</td><td class="num">${fB(r.today[0])}</td><td class="num">${fB(r.week[0]+r.week[1])}</td><td class="num"><b>${fB(t)}</b></td><td><div class="share"><b style="width:${(t/tot*100).toFixed(1)}%"></b></div></td></tr>`}).join(''):'<tr><td colspan="7" class="empty">هنوز ترافیکی ثبت نشده</td></tr>';
 if(TR.role=='kharej'){$('tNote').innerHTML='آمار دقیق مصرف هر پورت روی <b>پنل سرور ایران</b> ثبت می‌شود (همان‌جا که کاربران وصل می‌شوند). اینجا فقط کاربران فعال نمایش داده می‌شوند.'}
 drawDays()}
function drawDays(){if(!TR||PAGE!='traffic')return;const cv=$('cDays'),[c,w,h]=prep(cv),L=70,T=12,B=26,pw=w-L-6,ph=h-T-B,d=TR.days;
 let mx=0;d.forEach(x=>mx=Math.max(mx,x[1]+x[2]));mx=niceMax(mx*1.12||1);grid(c,w,h,L,T,ph,mx,v=>fB(v));
 const bw=pw/d.length,g1=css('--dl'),g2=css('--ul'),mu=css('--mu');dayGeo={L,bw,n:d.length};
 d.forEach((x,i)=>{const bx=L+i*bw+bw*.2,ww=bw*.6,hd=ph*x[2]/mx,hu=ph*x[1]/mx;
  c.save();c.shadowColor=g1;c.shadowBlur=x[2]?10:0;const gr=c.createLinearGradient(0,T+ph-hd,0,T+ph);gr.addColorStop(0,g1);gr.addColorStop(1,g1+'88');c.fillStyle=gr;
  c.beginPath();c.roundRect?c.roundRect(bx,T+ph-hd,ww,hd,[5,5,0,0]):c.rect(bx,T+ph-hd,ww,hd);c.fill();c.restore();
  c.fillStyle=g2;c.beginPath();c.roundRect?c.roundRect(bx,T+ph-hd-hu,ww,hu,[5,5,0,0]):c.rect(bx,T+ph-hd-hu,ww,hu);c.fill();
  if(i%2==(d.length-1)%2){c.fillStyle=mu;c.font='10px system-ui';c.textAlign='center';c.textBaseline='top';c.fillText(x[0].slice(5),bx+ww/2,T+ph+8)}})}
$('cDays').addEventListener('mousemove',e=>{if(!dayGeo||!TR)return;const r=e.target.getBoundingClientRect(),i=Math.floor((e.clientX-r.left-dayGeo.L)/dayGeo.bw);const x=TR.days[i],tip=$('tip2');
 if(!x){tip.style.opacity=0;return}tip.innerHTML=`<b class="num">${x[0]}</b><br><span style="color:var(--dl)">●</span> دانلود: <span class="num">${fB(x[2])}</span><br><span style="color:var(--ul)">●</span> آپلود: <span class="num">${fB(x[1])}</span>`;
 tip.style.opacity=1;tip.style.left=Math.min(Math.max(dayGeo.L+i*dayGeo.bw-tip.offsetWidth/2,0),e.target.clientWidth-tip.offsetWidth)+'px'});
$('cDays').addEventListener('mouseleave',()=>$('tip2').style.opacity=0);
async function resetTraffic(){if(!confirm('همه آمار مصرف پورت‌ها صفر شود؟'))return;try{const d=await post('api/traffic/reset');toast(d.output);loadTraffic()}catch(e){}}

/* ---------- tunnel ---------- */
let CFG=null,ROLEPICK='';
function segBind(id,cb){document.querySelectorAll('#'+id+' button').forEach(b=>b.onclick=()=>{if(cb&&cb(b.dataset.v)===false)return;document.querySelectorAll('#'+id+' button').forEach(x=>x.classList.toggle('on',x==b))})}
const segVal=id=>(document.querySelector('#'+id+' button.on')||{}).dataset?.v;
const MH={tls:'TLS: رمزنگاری کامل و سریع‌ترین گزینه (پیشنهادی)',wss:'WSS: شبیه HTTPS معمولی؛ اگر TLS اختلال داشت',quic:'QUIC: روی UDP، مناسب خطوط پرنوسان (UDP باید باز باشد)',kcp:'KCP: برای خطوط خیلی بد؛ ~۱۵٪ ترافیک بیشتر'};
segBind('wMethod',v=>{$('wMethodH').textContent=MH[v]});segBind('wMode');segBind('kMode');
segBind('segMode',v=>{if(CFG&&v!=CFG.mode)act('mode',[v],'حالت سرعت '+MODEN[v]+' شود؟ تانل حدود ۱ ثانیه قطع و وصل می‌شود.');return false});
segBind('segMethod',v=>{if(CFG&&v!=CFG.transport)act('method',[v],'روش تانل '+v.toUpperCase()+' شود؟');return false});
function pickRole(r){ROLEPICK=r;document.querySelectorAll('.rolecard').forEach(c=>c.classList.toggle('on',c.dataset.r==r));$('fIran').hidden=r!='iran';$('fKharej').hidden=r!='kharej';(r=='iran'?$('fIran'):$('fKharej')).scrollIntoView({behavior:'smooth',block:'start'})}
async function loadCfg(){try{CFG=await getJSON('api/config')}catch(e){return}const c=CFG;
 $('tunNew').hidden=c.installed;$('tunHave').hidden=!c.installed;
 document.body.classList.toggle('r-iran',c.role=='iran');document.body.classList.toggle('r-kharej',c.role=='kharej');
 document.querySelectorAll('.ir-only').forEach(e=>e.style.display=c.role=='iran'?'':'none');document.querySelectorAll('.kh-only').forEach(e=>e.style.display=c.role=='kharej'?'':'none');
 $('sInfo').innerHTML=`<dt>کاربر</dt><dd>${esc(c.user)}</dd><dt>پورت پنل</dt><dd class="num">${c.panel_port}</dd><dt>نسخه</dt><dd class="num">${c.version}</dd><dt>تانل</dt><dd>${c.installed?(c.role=='iran'?'سرور ایران':'سرور خارج'):'نصب نشده'}</dd>`;
 if(!c.installed)return;
 $('tRole').textContent=c.role=='iran'?'سرور ایران':'سرور خارج';
 $('tInfo').innerHTML=`<dt>روش</dt><dd>${c.transport.toUpperCase()}</dd><dt>پورت تانل</dt><dd class="num">${c.tport}</dd><dt>حالت سرعت</dt><dd>${MODEN[c.mode]||c.mode}</dd><dt>پورت‌ها</dt><dd class="num">${c.ports.join(' , ')||'—'}</dd>${c.sni?`<dt>SNI</dt><dd class="num">${esc(c.sni)}</dd>`:''}${c.peer?`<dt>سرور ایران</dt><dd class="num">${esc(c.peer)}</dd>`:''}<dt>UDP</dt><dd>${c.udp?'فعال':'غیرفعال'}</dd>`;
 document.querySelectorAll('#segMode button').forEach(b=>b.classList.toggle('on',b.dataset.v==c.mode));
 document.querySelectorAll('#segMethod button').forEach(b=>b.classList.toggle('on',b.dataset.v==c.transport));
 const ps=c.pstatus||{};$('pList').innerHTML=c.ports.length?c.ports.map(p=>`<span class="pchip num${ps[p]?' perr':''}" title="${ps[p]?esc(ps[p]=='port not allowed'?'این پورت روی سرور ایران اضافه نشده':ps[p]):'فعال'}">${p}<button title="حذف" onclick="delPort(${p})">✕</button></span>`).join(''):'<span class="mh">پورتی تعریف نشده</span>';
 if(c.role=='iran')$('codeBox').value=c.code||'';if(c.role=='kharej'&&!$('rcIp').value)$('rcIp').value=c.peer||''}
function showOut(t,ok){const o=$('mOut');o.hidden=false;o.innerHTML=`<span class="${ok?'lo':'le'}">${esc(t)}</span>`}
async function act(action,args,ask){if(ask&&!confirm(ask))return false;document.body.classList.add('busy');showOut('در حال اجرا…',true);let ok=false;
 try{const d=await post('api/manage',{action,args});ok=d.ok;showOut(d.output,d.ok);toast(d.ok?'انجام شد ✅':'انجام نشد ❌')}catch(e){if(e!==0)toast('خطا در ارتباط با پنل')}
 document.body.classList.remove('busy');loadCfg();return ok}
async function addPort(){const v=$('pIn').value.trim();if(!/^\d{1,5}$/.test(v)){toast('پورت نامعتبر است');return}if(await act('port-add',[v],'پورت '+v+' اضافه شود؟'))$('pIn').value=''}
$('pIn').addEventListener('keydown',e=>{if(e.key=='Enter')addPort()});
function delPort(p){act('port-del',[String(p)],'پورت '+p+' حذف شود؟ کاربرانی که از این پورت استفاده می‌کنند قطع می‌شوند.')}
async function reconnect(){const ip=$('rcIp').value.trim(),code=$('rcCode').value.replace(/\s+/g,'');if(!ip||!code){toast('IP و کد اتصال را وارد کنید');return}if(await act('reconnect',[ip,code],'تانل با این کد دوباره وصل شود؟'))$('rcCode').value=''}
function copyText(t){const done=()=>toast('کپی شد ✅');if(navigator.clipboard&&window.isSecureContext)navigator.clipboard.writeText(t).then(done,()=>fallback());else fallback();
 function fallback(){const a=document.createElement('textarea');a.value=t;document.body.appendChild(a);a.select();document.execCommand('copy');a.remove();done()}}
function copyCode(){copyText($('codeBox').value)}
async function removeTunnel(){if(!confirm('تانل از این سرور حذف شود؟ همه کاربران قطع می‌شوند.'))return;if(!confirm('مطمئن هستید؟ این کار قابل بازگشت نیست.'))return;if(await act('remove-tunnel',[]))setTimeout(loadCfg,800)}
/* jobs */
let JOBT=null,JOBCODE='';
async function startJob(action,args,ask){if(ask&&!confirm(ask))return;try{const d=await post('api/job',{action,args});if(!d.ok){toast(d.output);return}$('jobCard').hidden=false;$('jobCard').scrollIntoView({behavior:'smooth'});pollJob()}catch(e){}}
function setupIran(){const ports=$('wPorts').value.replace(/\s+/g,''),tp=$('wTport').value.trim(),sni=$('wSni').value.trim()||'www.speedtest.net';
 if(!/^\d{1,5}(,\d{1,5})*$/.test(ports)){toast('پورت‌های سرویس را درست وارد کنید');return}if(!/^\d{1,5}$/.test(tp)){toast('پورت تانل نامعتبر است');return}
 startJob('setup-iran',[segVal('wMethod'),tp,sni,ports,$('wUdp').checked?'y':'n',segVal('wMode')],'تانل سرور ایران ساخته شود؟')}
function setupKharej(){const ip=$('kIp').value.trim(),code=$('kCode').value.replace(/\s+/g,'');if(!ip||code.length<20){toast('IP و کد اتصال را وارد کنید');return}
 startJob('setup-kharej',[ip,code,segVal('kMode')],'سرور خارج به تانل وصل شود؟')}
function runUpdate(){startJob('update',[],'اسکریپت و پنل آپدیت شود؟');location.hash='#tunnel'}
function colorLog(t){return esc(t).split('\n').map(l=>/ERROR|\[E\]|failed|error/i.test(l)?`<span class="le">${l}</span>`:/WARN|Warning|\[W\]/.test(l)?`<span class="lw">${l}</span>`:/OK:|success|connected|ready|established/i.test(l)?`<span class="lo">${l}</span>`:l).join('\n')}
async function pollJob(){clearTimeout(JOBT);let j;try{j=await getJSON('api/job')}catch(e){return}
 if(!j.action){return}const card=$('jobCard');if(!j.running&&card.hidden&&Date.now()/1000-j.start>600)return;
 card.hidden=false;$('jobTitle').textContent=j.label||'عملیات';$('jobLog').innerHTML=colorLog(j.log||'…');$('jobLog').scrollTop=1e9;
 const okk=j.code===0;$('jobDot').className='dot '+(j.running?'idle':okk?'ok':'bad');$('jobState').textContent=j.running?'در حال اجرا':okk?'انجام شد':'خطا';
 $('jobDone').hidden=j.running;const m=(j.log||'').match(/copy ALL of it to the Kharej server:\s*\n\s*([A-Za-z0-9+/=]{40,})/);JOBCODE=m?m[1]:'';$('jobCopy').hidden=!JOBCODE;
 if(j.running)JOBT=setTimeout(pollJob,1500);else{loadCfg();if(j.action=='update'&&okk)setTimeout(()=>location.reload(),4000)}}
function copyJobCode(){copyText(JOBCODE)}
function jobClose(){$('jobCard').hidden=true}

/* ---------- logs ---------- */
let LOGTXT='',LOGT=null,LT='tun';
function logTab(t){LT=t;document.querySelectorAll('#logTabs button').forEach(b=>b.classList.toggle('on',b.dataset.t==t));$('lgTun').hidden=t!='tun';$('lgEv').hidden=t!='ev';$('lgAu').hidden=t!='au';loadLogs()}
document.querySelectorAll('#logTabs button').forEach(b=>b.onclick=()=>logTab(b.dataset.t));
segBind('lvl',()=>{setTimeout(showLogs,0)});$('lgQ').addEventListener('input',showLogs);$('lgN').onchange=loadLogs;
const AUN={'login':'ورود به پنل','logout':'خروج','restart':'ری‌استارت تانل','stop':'توقف تانل','start':'شروع تانل','mode':'تغییر حالت سرعت','port-add':'افزودن پورت','port-del':'حذف پورت','method':'تغییر روش','reconnect':'اتصال مجدد','remove-tunnel':'حذف تانل','password change':'تغییر رمز','traffic reset':'صفر کردن آمار','setup-iran (start)':'ساخت تانل ایران','setup-kharej (start)':'اتصال سرور خارج','update (start)':'آپدیت'};
async function loadLogs(){clearTimeout(LOGT);if(PAGE!='logs')return;
 try{if(LT=='tun'){const d=await getJSON('api/logs?n='+$('lgN').value);LOGTXT=d.logs||'';showLogs()}
  else if(LT=='ev'){$('evList').innerHTML=evHtml(await getJSON('api/events'))}
  else{const a=await getJSON('api/audit');$('auRows').innerHTML=a.length?a.map(([t,ip,ac,ok,dt])=>{const k=ac.split(' ')[0],nm=AUN[ac]||AUN[k]||ac;return`<tr><td class="small">${tfa(t)}</td><td><b>${esc(nm)}</b> <span class="mu num small">${esc(ac.slice(k.length))}</span></td><td>${ok?'<span style="color:var(--ok)">موفق</span>':'<span style="color:var(--bad)">ناموفق</span>'}</td><td class="num small">${esc(ip)}</td><td class="mu small num" style="max-width:280px;overflow:hidden;text-overflow:ellipsis">${esc(dt)}</td></tr>`}).join(''):'<tr><td colspan="5" class="empty">فعالیتی ثبت نشده</td></tr>'}}catch(e){}
 if(LT=='tun'&&$('lgAuto').checked)LOGT=setTimeout(loadLogs,5000)}
$('lgAuto').onchange=loadLogs;
function showLogs(){const lv=segVal('lvl'),q=$('lgQ').value.trim().toLowerCase();
 let lines=LOGTXT.split('\n').filter(Boolean);if(lv=='err')lines=lines.filter(l=>/\[E\]|ERROR|error|fail/i.test(l));if(lv=='warn')lines=lines.filter(l=>/\[W\]|\[E\]|WARN|ERROR|error|fail/i.test(l));
 if(q)lines=lines.filter(l=>l.toLowerCase().includes(q));const b=$('lgBox');const atEnd=b.scrollTop+b.clientHeight>=b.scrollHeight-30;
 b.innerHTML=lines.length?colorLog(lines.join('\n')):'<span class="lw">موردی یافت نشد</span>';if(atEnd)b.scrollTop=1e9}
function dlLogs(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([LOGTXT],{type:'text/plain'}));a.download='overtun-'+new Date().toISOString().slice(0,10)+'.log';a.click()}

/* ---------- settings ---------- */
async function changePw(){const o=$('pwOld').value,n=$('pwNew').value;if(n.length<8){toast('رمز جدید حداقل ۸ کاراکتر');return}
 try{const d=await post('api/password',{old:o,new:n});toast(d.output);if(d.ok){$('pwOld').value='';$('pwNew').value=''}}catch(e){}}
async function logout(){try{await post('api/logout')}catch(e){}location.href='login'}

route();tick();loadCfg();pollJob();setInterval(()=>{if(PAGE=='traffic')loadTraffic()},15000);
</script></body></html>'''

SESSION_TTL = 12 * 3600
SESS, FAILS = {}, {}

class H(BaseHTTPRequestHandler):
    server_version = 'nginx'
    sys_version = ''
    def log_message(self, *a): pass
    def _send(self, code, body, ctype, headers=()):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        for k, v in headers: self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)
    def _json(self, code, obj, headers=()):
        self._send(code, json.dumps(obj, separators=(',', ':')), 'application/json', headers)
    def _ip(self):
        return self.client_address[0]
    def _token(self):
        try:
            c = SimpleCookie(self.headers.get('Cookie', ''))
            return c['ot'].value if 'ot' in c else ''
        except Exception:
            return ''
    def _authed(self):
        t, now = self._token(), time.time()
        if not t: return False
        with LOCK:
            exp = SESS.get(t)
            if exp and exp > now:
                SESS[t] = now + SESSION_TTL; return True
            SESS.pop(t, None)
        return False
    def _body(self):
        try:
            n = int(self.headers.get('Content-Length') or 0)
            return json.loads(self.rfile.read(n) or b'{}') if 0 < n <= 30000 else {}
        except Exception:
            return {}
    def do_GET(self):
        u = urlparse(self.path); p = u.path; q = parse_qs(u.query)
        if p == '/login': return self._send(200, LOGIN_HTML, 'text/html; charset=utf-8')
        if not self._authed():
            if p.startswith('/api/'): return self._json(401, {'error': 'auth'})
            return self._send(302, b'', 'text/plain', [('Location', 'login')])
        if p == '/': return self._send(200, HTML, 'text/html; charset=utf-8')
        if p == '/api/stats':
            try: since = float(q.get('since', ['0'])[0])
            except ValueError: since = 0
            return self._json(200, stats(since))
        if p == '/api/config': return self._json(200, config_info())
        if p == '/api/traffic': return self._json(200, traffic_info())
        if p == '/api/job': return self._json(200, job_status())
        if p == '/api/events':
            with LOCK: return self._json(200, list(EVENTS))
        if p == '/api/audit':
            with LOCK: return self._json(200, list(AUDIT))
        if p == '/api/logs':
            try: n = max(20, min(2000, int(q.get('n', ['300'])[0])))
            except ValueError: n = 300
            out = sh(['journalctl', '-u', 'overtun', '-n', str(n), '--no-pager', '-o', 'short-iso'], 8)
            out = '\n'.join(l for l in out.splitlines() if '/api/status' not in l and 'admin_api' not in l)
            return self._json(200, {'logs': out})
        self._send(404, 'not found', 'text/plain')
    def do_HEAD(self):
        self._send(200, b'', 'text/html; charset=utf-8')
    def do_POST(self):
        global PWHASH
        p = urlparse(self.path).path; ip = self._ip()
        if self.headers.get('X-Req') != '1': return self._send(403, 'forbidden', 'text/plain')
        if p == '/api/login':
            now, d = time.time(), self._body()
            with LOCK:
                cnt, first = FAILS.get(ip, (0, now))
                if now - first > 600: cnt, first = 0, now
                if cnt >= 5: return self._json(429, {'error': 'locked', 'wait': int(600 - (now - first))})
            if hmac.compare_digest(str(d.get('user', '')), USER) and check_pw(str(d.get('pass', ''))):
                t = secrets.token_urlsafe(32)
                with LOCK:
                    FAILS.pop(ip, None)
                    for k in [k for k, v in SESS.items() if v < now]: SESS.pop(k, None)
                    SESS[t] = now + SESSION_TTL
                audit(ip, 'login', True)
                return self._json(200, {'ok': True}, [('Set-Cookie', f'ot={t}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}')])
            with LOCK: FAILS[ip] = (cnt + 1, first)
            audit(ip, 'login', False)
            time.sleep(0.7)
            return self._json(401, {'error': 'bad', 'left': max(0, 4 - cnt)})
        if not self._authed(): return self._json(401, {'error': 'auth'})
        if p == '/api/logout':
            with LOCK: SESS.pop(self._token(), None)
            audit(ip, 'logout', True)
            return self._json(200, {'ok': True}, [('Set-Cookie', 'ot=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict')])
        if p == '/api/manage':
            d = self._body(); a = str(d.get('action', ''))
            ok, out = manage(a, d.get('args') or [])
            shown = [x for x in (d.get('args') or []) if len(str(x)) < 40]
            audit(ip, a + (' ' + ' '.join(map(str, shown)) if shown else ''), ok, out.splitlines()[-1] if out else '')
            _envc[0] = 0
            return self._json(200, {'ok': ok, 'output': out})
        if p == '/api/job':
            d = self._body(); a = str(d.get('action', ''))
            if a not in JOB_RX: return self._json(200, {'ok': False, 'output': 'unknown action'})
            args = clean_args(a, d.get('args') or [], JOB_RX)
            if args is None: return self._json(200, {'ok': False, 'output': 'ورودی نامعتبر است'})
            ok, out = start_job([a] + args, JOB_LABEL[a])
            audit(ip, a + ' (start)', ok, out)
            return self._json(200, {'ok': ok, 'output': out})
        if p == '/api/traffic/reset':
            with LOCK:
                LEDGER['ports'] = {}; LEDGER['since'] = int(time.time()); save_json(F_TRAFFIC, LEDGER)
            audit(ip, 'traffic reset', True)
            return self._json(200, {'ok': True, 'output': 'آمار مصرف صفر شد'})
        if p == '/api/password':
            d = self._body()
            if not check_pw(str(d.get('old', ''))):
                audit(ip, 'password change', False)
                return self._json(200, {'ok': False, 'output': 'رمز فعلی اشتباه است'})
            new = str(d.get('new', ''))
            if len(new) < 8: return self._json(200, {'ok': False, 'output': 'رمز جدید باید حداقل ۸ کاراکتر باشد'})
            PWHASH = make_hash(new); save_web('WEB_HASH', PWHASH)
            with LOCK:
                keep = self._token()
                for k in [k for k in SESS if k != keep]: SESS.pop(k, None)
            audit(ip, 'password change', True)
            return self._json(200, {'ok': True, 'output': 'رمز پنل تغییر کرد'})
        self._send(404, 'not found', 'text/plain')

if __name__ == '__main__':
    for fn in (sampler, pinger, ledger_loop):
        threading.Thread(target=fn, daemon=True).start()
    srv = ThreadingHTTPServer(('0.0.0.0', LISTEN), H)
    srv.daemon_threads = True
    srv.serve_forever()
PYEOF
  chmod +x /usr/local/bin/overtun-web.py
  cat > /etc/systemd/system/overtun-web.service <<'EOF'
[Unit]
Description=Over-Tun Web Panel
After=network-online.target
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
}

remove_web() {
  systemctl disable --now overtun-web 2>/dev/null
  rm -f /etc/systemd/system/overtun-web.service /usr/local/bin/overtun-web.py $CONF_DIR/web.conf
  systemctl daemon-reload
  echo -e "${GRN}Web panel removed.${NC}"
}

# bring older installs up to date (idempotent): lower keepalive traffic on idle pool connections
migrate_conf() {
  [[ -f $FRP_CONF ]] || return 0
  local ch=0
  if grep -q '^transport.dialServerKeepalive = 20$' $FRP_CONF; then sed -i 's/^transport.dialServerKeepalive = 20$/transport.dialServerKeepalive = 300/' $FRP_CONF; ch=1; fi
  if grep -q '^transport.tcpKeepalive = 20$' $FRP_CONF; then sed -i '/^transport.tcpKeepalive = 20$/d' $FRP_CONF; ch=1; fi
  [[ $ch == 1 ]] && systemctl restart $SVC_NAME && echo "OK: tunnel settings optimized (less idle traffic)"
  return 0
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
    echo -e "${GRN}Script updated.${NC}"
    $CMD migrate                                                    # apply new tunnel optimizations to this server
    [[ -f $CONF_DIR/web.conf ]] && $CMD panel-refresh               # update the web panel too (keeps password/data)
    echo -e "${GRN}Done. Run: over-tun${NC}"
  else
    rm -f $CMD.tmp; echo -e "${RED}Download failed (GitHub may be blocked on this server).${NC}"; return 1
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
  local a=$1; shift
  case $a in      # commands that do not need an installed tunnel
    setup-iran)   do_setup_iran "$@"; return $? ;;
    setup-kharej) do_setup_kharej "$@"; return $? ;;
    update)       update_script; return $? ;;
    panel-refresh) [[ -f $CONF_DIR/web.conf ]] || cli_fail "web panel is not installed"; write_panel; echo "OK: panel refreshed"; return 0 ;;
    migrate)      migrate_conf; return 0 ;;
    help|-h|--help) echo "usage: over-tun [restart|stop|start|mode M|port-add P|port-del P|method wss|tls|reconnect IP CODE|code|setup-iran ...|setup-kharej IP CODE MODE|remove-tunnel|update]"; return 0 ;;
  esac
  [[ -f $CONF ]] || cli_fail "tunnel is not installed"
  . $CONF
  case $a in
    remove-tunnel) remove_tunnel ;;
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
  local GOLD='\033[38;5;178m' DIM='\033[2m' st="not installed"
  if [[ -f $CONF ]]; then
    . $CONF
    st="$ROLE | $TRANSPORT :$TPORT | ports $PORTS | $(cat $MODE_FILE 2>/dev/null) | $(systemctl is-active $SVC_NAME 2>/dev/null)"
  fi
  echo -e "${GOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GOLD}║        Over-Tun  -  Overal-Team          ║${NC}"
  echo -e "${GOLD}║     Iran <-> Kharej  secure tunnel       ║${NC}"
  echo -e "${GOLD}╚══════════════════════════════════════════╝${NC}"
  echo -e "${DIM} status: $st${NC}"
  echo -e "${DIM} open this menu anytime: over-tun${NC}"
  echo
  echo "1) Install on IRAN server"
  echo "2) Install on KHAREJ server"
  echo "3) Status / logs"
  echo "4) Restart tunnel"
  echo "5) Show connection code (Iran)"
  echo "6) Install / reset WEB panel"
  echo "7) Remove WEB panel"
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
