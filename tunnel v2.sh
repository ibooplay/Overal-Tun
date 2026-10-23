#!/usr/bin/env bash
# =====================================================================
#  Iran <-> Kharej reverse tunnel (rathole) + Web monitor panel
#  Iran   = server (users connect here)
#  Kharej = client (connects to Iran, auto-reconnects in ~1s)
#  Transports: WSS (WebSocket+TLS, looks like HTTPS) | Noise | TCP
# =====================================================================

VER="v0.5.0"
REPO_RAW="https://raw.githubusercontent.com/ibooplay/Overal-Tun/main/tunnel.sh"
CMD=/usr/local/bin/over-tun
BIN=/usr/local/bin/rathole
CONF_DIR=/etc/rathole
CONF=$CONF_DIR/config.toml
SVC=/etc/systemd/system/rathole.service

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'

get_arch() {
  case "$(uname -m)" in
    x86_64)        echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    armv7l)        echo "armv7-unknown-linux-musleabihf" ;;
    *)             echo "" ;;
  esac
}

install_deps() {
  if command -v apt >/dev/null; then
    apt update -y >/dev/null 2>&1; apt install -y unzip curl iproute2 openssl python3 >/dev/null 2>&1
  elif command -v yum >/dev/null; then
    yum install -y unzip curl iproute openssl python3 >/dev/null 2>&1
  fi
}

install_binary() {
  [[ -x $BIN ]] && { echo -e "${GRN}rathole already installed${NC}"; return; }
  ARCH=$(get_arch)
  [[ -z $ARCH ]] && { echo -e "${RED}Unsupported CPU arch${NC}"; exit 1; }
  URL="https://github.com/rathole-org/rathole/releases/download/$VER/rathole-$ARCH.zip"
  echo -e "${YEL}Downloading rathole...${NC}"
  if [[ -f /root/rathole.zip ]]; then
    echo "Using local /root/rathole.zip"
  elif ! curl -fL --connect-timeout 15 -o /root/rathole.zip "$URL"; then
    echo -e "${RED}Download failed (GitHub may be blocked).${NC}"
    echo "Download manually: $URL"
    echo "Upload it to /root/rathole.zip and run this script again."
    exit 1
  fi
  rm -rf /tmp/rathole
  unzip -o /root/rathole.zip -d /tmp/rathole >/dev/null && \
    install -m 755 /tmp/rathole/rathole $BIN && rm -rf /tmp/rathole
  [[ -x $BIN ]] || { echo -e "${RED}Install failed${NC}"; exit 1; }
  echo -e "${GRN}rathole installed${NC}"
}

MODE_FILE=$CONF_DIR/mode
DROPIN_DIR=/etc/systemd/system/rathole.service.d

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

# apply_profile <medium|turbo|advanced> : kernel network tuning + process priority
apply_profile() {
  local mode=${1:-turbo} buf lowat backlog somax slow cpuq nice weight
  case $mode in
    medium)   buf=8388608;  lowat=131072; backlog=16384;  somax=8192;  slow=1; cpuq="CPUQuota=80%"; nice=0;   weight=100 ;;
    advanced) buf=134217728; lowat=131072; backlog=250000; somax=65535; slow=0; cpuq="";             nice=-10; weight=1000 ;;
    *)        mode=turbo; buf=33554432; lowat=16384; backlog=65536; somax=32768; slow=0; cpuq=""; nice=-5; weight=400 ;;
  esac
  echo -e "${YEL}Applying speed mode: $mode ...${NC}"
  modprobe tcp_bbr 2>/dev/null
  cat > /etc/sysctl.d/99-tunnel.conf <<EOF
# rathole tunnel - speed mode: $mode
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

  # NIC tuning (Advanced: big TX queue + spread packet processing over all CPU cores)
  cat > /usr/local/bin/rathole-nic.sh <<'EOF'
#!/bin/bash
IF=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ -z "$IF" ] && exit 0
N=$(nproc); [ "$N" -gt 31 ] && N=31
if [ "$1" = advanced ]; then
  ip link set dev "$IF" txqueuelen 10000 2>/dev/null
  # bigger initial congestion window: full speed reached much faster on the 80ms+ Iran<->Kharej path
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
  chmod +x /usr/local/bin/rathole-nic.sh

  mkdir -p $DROPIN_DIR $CONF_DIR
  cat > $DROPIN_DIR/mode.conf <<EOF
[Service]
Nice=$nice
CPUWeight=$weight
$cpuq
ExecStartPre=-/usr/local/bin/rathole-nic.sh $mode
EOF
  echo "$mode" > $MODE_FILE
  systemctl daemon-reload
  echo "Mode: $mode | congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

change_mode() {
  [[ -f $CONF ]] || { echo -e "${RED}Install the tunnel first (option 1 or 2)${NC}"; return; }
  choose_mode; apply_profile "$MODE"
  systemctl restart rathole
  echo -e "${GRN}Speed mode changed to $MODE (tunnel reconnected).${NC}"
  echo "Tip: set the same mode on the other server too."
}

write_service() {
  cat > $SVC <<EOF
[Unit]
Description=Rathole Tunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$BIN $CONF
Restart=always
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable rathole >/dev/null 2>&1
  systemctl restart rathole
}

# Watchdog (Kharej): restarts the tunnel if there is no connection to Iran
write_watchdog() {
  local port=$1
  cat > /usr/local/bin/rathole-watchdog.sh <<EOF
#!/bin/bash
if [ -z "\$(ss -Htn state established '( dport = :$port )')" ]; then
  sleep 10
  if [ -z "\$(ss -Htn state established '( dport = :$port )')" ]; then
    logger "rathole-watchdog: tunnel down, restarting"
    systemctl restart rathole
  fi
fi
EOF
  chmod +x /usr/local/bin/rathole-watchdog.sh
  cat > /etc/systemd/system/rathole-watchdog.service <<'EOF'
[Unit]
Description=Rathole watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rathole-watchdog.sh
EOF
  cat > /etc/systemd/system/rathole-watchdog.timer <<'EOF'
[Unit]
Description=Run rathole watchdog every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now rathole-watchdog.timer >/dev/null 2>&1
}

choose_transport() {
  echo -e "\n${CYN}Tunnel method:${NC}"
  echo "  1) WSS   - WebSocket + TLS, looks like normal HTTPS  (best against filtering) [recommended]"
  echo "  2) Noise - fully encrypted, random-looking, very fast"
  echo "  3) TCP   - fastest, but no encryption / camouflage"
  read -rp "Choose [1]: " t
  case ${t:-1} in
    2) TRANSPORT=noise ;;
    3) TRANSPORT=tcp ;;
    *) TRANSPORT=wss ;;
  esac
}

port_in_use() { [[ -n $(ss -Hltn "( sport = :$1 )" 2>/dev/null) ]]; }

ask_ports() {
  local tport=$1
  read -rp "Service ports to forward (comma separated, e.g. 8443,2096): " PORTS_IN
  PORTS_IN=$(echo "$PORTS_IN" | tr -d ' ')
  [[ $PORTS_IN =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo -e "${RED}Invalid port list${NC}"; return 1; }
  for p in ${PORTS_IN//,/ }; do
    [[ $p == "$tport" ]] && { echo -e "${RED}Port $p is the tunnel port. Pick a different service port.${NC}"; return 1; }
    port_in_use "$p" && { echo -e "${RED}Port $p is already in use on this server.${NC}"; return 1; }
  done
  read -rp "Also forward UDP on these ports? [y/N]: " u
  [[ $u =~ ^[Yy]$ ]] && UDP=y || UDP=n
}

tcp_block() {
  printf '\n[%s.transport.tcp]\nnodelay = true\nkeepalive_secs = 20\nkeepalive_interval = 8\n' "$1"
}

# gen_iran_config <transport> <tunnel_port> <token> <ports_csv> <udp y/n> <sni>
# Writes $CONF + keys/certs and $CONF_DIR/code.txt (connection code for Kharej)
gen_iran_config() {
  local tr=$1 tport=$2 token=$3 ports=$4 udp=$5 sni=$6
  local priv="" pub="" ca="" pfxpass=""
  mkdir -p $CONF_DIR; chmod 700 $CONF_DIR

  if [[ $tr == noise ]]; then
    local keys; keys=$($BIN --genkey) || return 1
    priv=$(echo "$keys" | sed -n '2p'); pub=$(echo "$keys" | sed -n '5p')
    [[ -z $priv || -z $pub ]] && { echo -e "${RED}Key generation failed${NC}"; return 1; }
  elif [[ $tr == wss ]]; then
    local d=$CONF_DIR/tls; rm -rf "$d"; mkdir -p "$d"
    pfxpass=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$d/ca.key" -out "$d/ca.pem" -days 3650 -subj "/CN=Root CA" >/dev/null 2>&1 &&
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$d/srv.key" -out "$d/srv.csr" -subj "/CN=$sni" >/dev/null 2>&1 &&
    printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$sni" > "$d/ext.cnf" &&
    openssl x509 -req -in "$d/srv.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial \
      -out "$d/srv.pem" -days 3650 -extfile "$d/ext.cnf" >/dev/null 2>&1 &&
    openssl pkcs12 -export -out $CONF_DIR/identity.pfx -inkey "$d/srv.key" -in "$d/srv.pem" \
      -certfile "$d/ca.pem" -passout "pass:$pfxpass" >/dev/null 2>&1 ||
      { echo -e "${RED}TLS certificate generation failed${NC}"; return 1; }
    ca=$(base64 -w0 "$d/ca.pem")
  fi

  {
    printf '[server]\nbind_addr = "0.0.0.0:%s"\ndefault_token = "%s"\nheartbeat_interval = 10\n\n' "$tport" "$token"
    case $tr in
      tcp)   printf '[server.transport]\ntype = "tcp"\n' ;;
      noise) printf '[server.transport]\ntype = "noise"\n\n[server.transport.noise]\nlocal_private_key = "%s"\n' "$priv" ;;
      wss)   printf '[server.transport]\ntype = "websocket"\n\n[server.transport.tls]\npkcs12 = "%s"\npkcs12_password = "%s"\n\n[server.transport.websocket]\ntls = true\n' \
               "$CONF_DIR/identity.pfx" "$pfxpass" ;;
    esac
    tcp_block server
    for p in ${ports//,/ }; do
      printf '\n[server.services.t%s]\ntype = "tcp"\nbind_addr = "0.0.0.0:%s"\nnodelay = true\n' "$p" "$p"
      [[ $udp == y ]] && printf '\n[server.services.u%s]\ntype = "udp"\nbind_addr = "0.0.0.0:%s"\n' "$p" "$p"
    done
  } > $CONF
  chmod 600 $CONF

  printf 'V=1\nTRANSPORT=%s\nTPORT=%s\nTOKEN=%s\nPORTS=%s\nUDP=%s\nSNI=%s\nPUB=%s\nCA=%s\n' \
    "$tr" "$tport" "$token" "$ports" "$udp" "$sni" "$pub" "$ca" | base64 -w0 > $CONF_DIR/code.txt
}

# gen_kharej_config <iran_ip> <connection_code>
gen_kharej_config() {
  local ip=$1 dec
  dec=$(echo "$2" | tr -d ' \r\n' | base64 -d 2>/dev/null)
  getv() { echo "$dec" | grep -m1 "^$1=" | cut -d= -f2-; }
  local tr tport token ports udp sni pub ca
  tr=$(getv TRANSPORT); tport=$(getv TPORT); token=$(getv TOKEN); ports=$(getv PORTS)
  udp=$(getv UDP); sni=$(getv SNI); pub=$(getv PUB); ca=$(getv CA)
  [[ -z $tr || -z $tport || -z $token || -z $ports ]] && { echo -e "${RED}Invalid connection code${NC}"; return 1; }
  mkdir -p $CONF_DIR; chmod 700 $CONF_DIR

  local host=$ip; [[ $ip == *:* ]] && host="[$ip]"
  {
    printf '[client]\nremote_addr = "%s:%s"\ndefault_token = "%s"\nretry_interval = 1\nheartbeat_timeout = 25\n\n' "$host" "$tport" "$token"
    case $tr in
      tcp)   printf '[client.transport]\ntype = "tcp"\n' ;;
      noise) printf '[client.transport]\ntype = "noise"\n\n[client.transport.noise]\nremote_public_key = "%s"\n' "$pub" ;;
      wss)   echo "$ca" | base64 -d > $CONF_DIR/ca.pem
             printf '[client.transport]\ntype = "websocket"\n\n[client.transport.tls]\ntrusted_root = "%s"\nhostname = "%s"\n\n[client.transport.websocket]\ntls = true\n' \
               "$CONF_DIR/ca.pem" "$sni" ;;
    esac
    tcp_block client
    for p in ${ports//,/ }; do
      printf '\n[client.services.t%s]\ntype = "tcp"\nlocal_addr = "127.0.0.1:%s"\nnodelay = true\n' "$p" "$p"
      [[ $udp == y ]] && printf '\n[client.services.u%s]\ntype = "udp"\nlocal_addr = "127.0.0.1:%s"\n' "$p" "$p"
    done
  } > $CONF
  chmod 600 $CONF
  KH_TPORT=$tport; KH_PORTS=$ports; KH_TR=$tr
}

show_code() {
  [[ -f $CONF_DIR/code.txt ]] || { echo -e "${RED}No connection code (run on the Iran server after install)${NC}"; return; }
  echo -e "\n${CYN}Connection code - copy ALL of it to the Kharej server:${NC}\n"
  cat $CONF_DIR/code.txt; echo -e "\n"
}

setup_iran() {
  install_deps; install_binary; choose_mode; apply_profile "$MODE"
  systemctl stop rathole 2>/dev/null
  choose_transport
  local def=2333; [[ $TRANSPORT == wss ]] && def=443
  read -rp "Tunnel port [$def]: " TPORT; TPORT=${TPORT:-$def}
  port_in_use "$TPORT" && { echo -e "${RED}Port $TPORT is already in use.${NC}"; return; }
  SNI=""
  if [[ $TRANSPORT == wss ]]; then
    read -rp "TLS domain / SNI [www.speedtest.net]: " SNI; SNI=${SNI:-www.speedtest.net}
  fi
  ask_ports "$TPORT" || return
  TOKEN=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
  gen_iran_config "$TRANSPORT" "$TPORT" "$TOKEN" "$PORTS_IN" "$UDP" "$SNI" || return
  write_service
  sleep 1
  if systemctl is-active --quiet rathole; then
    echo -e "\n${GRN}Iran server ready  (method: $TRANSPORT, tunnel port: $TPORT, ports: $PORTS_IN)${NC}"
  else
    echo -e "${RED}Tunnel failed to start:${NC}"; journalctl -u rathole -n 15 --no-pager; return
  fi
  show_code
}

setup_kharej() {
  install_deps; install_binary; choose_mode; apply_profile "$MODE"
  systemctl stop rathole 2>/dev/null
  read -rp "Iran server IP: " IRIP
  read -rp "Connection code (from Iran server): " CODE
  gen_kharej_config "$IRIP" "$CODE" || return
  write_service
  write_watchdog "$KH_TPORT"
  for p in ${KH_PORTS//,/ }; do
    port_in_use "$p" || echo -e "${YEL}Warning: nothing is listening on port $p on this server yet (start your service, e.g. Xray, on it).${NC}"
  done
  echo -e "${YEL}Connecting...${NC}"; sleep 4
  if journalctl -u rathole -n 30 --no-pager | grep -q "Control channel established"; then
    echo -e "${GRN}Tunnel connected to $IRIP:$KH_TPORT  (method: $KH_TR)${NC}"
  else
    echo -e "${YEL}Not connected yet. Check logs with option 3.${NC}"
  fi
}

status() {
  systemctl --no-pager status rathole | head -n 5
  echo "--- last logs ---"
  journalctl -u rathole -n 20 --no-pager
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
  printf 'WEB_PORT=%s\nWEB_USER=%s\nWEB_PASS=%s\nLINK_MBPS=%s\n' "$WP" "$WU" "$WPASS" "$LINK" > $CONF_DIR/web.conf
  chmod 600 $CONF_DIR/web.conf

  cat > /usr/local/bin/rathole-web.py <<'PYEOF'
#!/usr/bin/env python3
# Web monitor for rathole tunnel - no external dependencies
import json, os, re, socket, subprocess, threading, time, base64
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from collections import deque

CONF_DIR = '/etc/rathole'

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

CFG_TEXT = open(CONF_DIR + '/config.toml').read()
ROLE = 'iran' if '[server]' in CFG_TEXT else 'kharej'
PEER = ''
if ROLE == 'iran':
    m = re.search(r'bind_addr\s*=\s*"[^"]*:(\d+)"', CFG_TEXT)
    TPORT = int(m.group(1)) if m else 2333
else:
    m = re.search(r'remote_addr\s*=\s*"\[?([^"\]]+)\]?:(\d+)"', CFG_TEXT)
    PEER, TPORT = (m.group(1), int(m.group(2))) if m else ('', 2333)
PORTS = sorted({int(p) for p in re.findall(r'services\.[tu](\d+)\]', CFG_TEXT)})

def cur_mode():
    try:
        return open(CONF_DIR + '/mode').read().strip() or 'turbo'
    except OSError:
        return 'turbo'
m = re.search(r'\.transport\]\s*\ntype\s*=\s*"(\w+)"', CFG_TEXT)
TRANSPORT = m.group(1) if m else 'tcp'
if TRANSPORT == 'websocket':
    TRANSPORT = 'wss' if re.search(r'websocket\]\s*\ntls\s*=\s*true', CFG_TEXT) else 'ws'

WEB = load_kv(CONF_DIR + '/web.conf')
LISTEN = int(WEB.get('WEB_PORT', '9090'))
try:
    LINK_MBPS = int(WEB.get('LINK_MBPS', '0') or 0)
except ValueError:
    LINK_MBPS = 0
AUTH = 'Basic ' + base64.b64encode(f"{WEB.get('WEB_USER','admin')}:{WEB.get('WEB_PASS','admin')}".encode()).decode()

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
    return sh(['systemctl', 'is-active', 'rathole']).strip() == 'active'

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
        up = S['active'] and len(tun) > 0
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
        restarts = int(sh(['systemctl', 'show', 'rathole', '-p', 'NRestarts', '--value']).strip() or 0)
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
  <button class="danger" id="rsBtn" onclick="restart()">⟳ <span class="hide-sm">ری‌استارت تانل</span></button>
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
 try{const r=await fetch('api/stats',{cache:'no-store'});if(!r.ok)throw 0;render(await r.json())}
 catch(e){setStatus(false,'ارتباط با پنل برقرار نیست','بررسی اتصال اینترنت یا سرویس پنل')}
 setTimeout(tick,1000)}
async function logs(){try{const d=await(await fetch('api/logs',{cache:'no-store'})).json();
 const el=$('lg');el.innerHTML=esc(d.logs||'-').split('\n').map(l=>/ERROR/.test(l)?`<span class="le">${l}</span>`:/WARN/.test(l)?`<span class="lw">${l}</span>`:/established/.test(l)?`<span class="lo">${l}</span>`:l).join('\n');el.scrollTop=1e9}catch(e){}}
function toast(m){const t=$('toast');t.textContent=m;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),2500)}
async function restart(){if(!confirm('تانل ری‌استارت شود؟'))return;const b=$('rsBtn');b.disabled=true;
 try{const r=await fetch('api/restart',{method:'POST',headers:{'X-Req':'1'}});toast(r.ok?'تانل در حال ری‌استارت است…':'خطا در ری‌استارت')}catch(e){toast('خطا در ری‌استارت')}
 setTimeout(()=>{b.disabled=false;logs()},2500)}
tick();logs();setInterval(logs,15000);
</script></body></html>'''

class H(BaseHTTPRequestHandler):
    server_version = 'nginx'
    sys_version = ''
    def log_message(self, *a):
        pass
    def _auth(self):
        if self.headers.get('Authorization') == AUTH:
            return True
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Restricted"')
        self.end_headers()
        return False
    def _send(self, code, body, ctype):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if not self._auth(): return
        if self.path == '/':
            self._send(200, HTML, 'text/html; charset=utf-8')
        elif self.path == '/api/stats':
            self._send(200, json.dumps(stats()), 'application/json')
        elif self.path == '/api/logs':
            out = sh(['journalctl', '-u', 'rathole', '-n', '40', '--no-pager', '-o', 'short-iso'])
            self._send(200, json.dumps({'logs': out}), 'application/json')
        else:
            self._send(404, 'not found', 'text/plain')
    def do_POST(self):
        if not self._auth(): return
        if self.path == '/api/restart' and self.headers.get('X-Req') == '1':
            subprocess.Popen(['systemctl', 'restart', 'rathole'])
            self._send(200, '{"ok":true}', 'application/json')
        else:
            self._send(403, 'forbidden', 'text/plain')

if __name__ == '__main__':
    threading.Thread(target=sampler, daemon=True).start()
    threading.Thread(target=pinger, daemon=True).start()
    srv = ThreadingHTTPServer(('0.0.0.0', LISTEN), H)
    srv.daemon_threads = True
    srv.serve_forever()
PYEOF
  chmod +x /usr/local/bin/rathole-web.py

  cat > /etc/systemd/system/rathole-web.service <<'EOF'
[Unit]
Description=Rathole Web Monitor
After=network-online.target rathole.service
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/env python3 /usr/local/bin/rathole-web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable rathole-web >/dev/null 2>&1
  systemctl restart rathole-web
  sleep 2
  if systemctl is-active --quiet rathole-web; then
    IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GRN}Web monitor is running${NC}"
    echo -e "URL:      ${YEL}http://$IP:$WP${NC}"
    echo -e "Username: ${YEL}$WU${NC}"
    echo -e "Password: ${YEL}$WPASS${NC}"
  else
    echo -e "${RED}Web monitor failed to start:${NC}"
    journalctl -u rathole-web -n 15 --no-pager
  fi
}

remove_web() {
  systemctl disable --now rathole-web 2>/dev/null
  rm -f /etc/systemd/system/rathole-web.service /usr/local/bin/rathole-web.py $CONF_DIR/web.conf
  systemctl daemon-reload
  echo -e "${GRN}Web monitor removed.${NC}"
}

uninstall() {
  remove_web >/dev/null 2>&1
  systemctl disable --now rathole rathole-watchdog.timer 2>/dev/null
  rm -f $SVC /etc/systemd/system/rathole-watchdog.* /usr/local/bin/rathole-watchdog.sh
  /usr/local/bin/rathole-nic.sh medium >/dev/null 2>&1
  rm -rf $CONF_DIR $BIN /etc/sysctl.d/99-tunnel.conf $DROPIN_DIR /usr/local/bin/rathole-nic.sh $CMD /usr/local/bin/Over-Tun
  systemctl daemon-reload
  echo -e "${GRN}Removed.${NC}"
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
    [[ -f /usr/local/bin/rathole-web.py ]] && echo "Tip: run option 6 again to update the web panel too."
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
    local peer
    peer=$(grep -oP 'remote_addr = "\[?\K[^"\]]+(?=\]?:\d+")' $CONF 2>/dev/null)
    [[ -z $peer ]] && peer=$(ss -Htn state established "( sport = :$(grep -oP 'bind_addr = "[^"]*:\K\d+' $CONF | head -1) )" | awk '{print $4}' | sed -E 's/:[0-9]+$//;s/^\[|\]$//g;s/^::ffff://' | head -1)
    [[ -n $peer ]] && { echo "Ping to other server ($peer):"; ping -c 10 -i 0.3 -q "$peer" | tail -2; }
  fi
  echo "Tunnel speed can never be higher than the SLOWER of the two servers."
}

main() {
  [[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root${NC}"; exit 1; }
  install_cmd
  clear
  echo "=================================="
  echo "     Iran <-> Kharej  Tunnel"
  echo "  open this menu anytime: over-tun"
  echo "=================================="
  echo "1) Install on IRAN server"
  echo "2) Install on KHAREJ server"
  echo "3) Status / logs"
  echo "4) Restart tunnel"
  echo "5) Show connection code (Iran)"
  echo "6) Install WEB monitor panel"
  echo "7) Remove WEB monitor panel"
  echo "8) Uninstall everything"
  echo "9) Change speed mode (Medium / Turbo / Advanced)"
  echo "10) Speed test (this server)"
  echo "11) Update script"
  read -rp "Choose: " c
  case $c in
    1) setup_iran ;;
    2) setup_kharej ;;
    3) status ;;
    4) systemctl restart rathole && echo "Restarted" ;;
    5) show_code ;;
    6) install_web ;;
    7) remove_web ;;
    8) uninstall ;;
    9) change_mode ;;
    10) speed_test ;;
    11) update_script ;;
    *) echo "Invalid" ;;
  esac
}

(return 0 2>/dev/null) || main "$@"
