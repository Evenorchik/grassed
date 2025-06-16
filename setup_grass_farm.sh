#!/usr/bin/env bash
set -euo pipefail
###################################################################
#  Grass farm autodeploy — Ubuntu 24.04 LTS + redsocks (FINAL-2)  #
###################################################################

source /etc/os-release
[ "$VERSION_ID" = "24.04" ] || { echo "❌ Need Ubuntu 24.04 LTS"; exit 1; }

NUM_NODES=1                 # 1–25
VNC_PASS="graspas"          # первые 8 симв.
GRASS_DEB="https://raw.githubusercontent.com/Evenorchik/grassed/main/Grass_5.3.1_amd64.deb"

# ─── 0. Очистка старых юнитов ─────────────────────────────────────
for i in $(seq 1 26); do
  systemctl stop    redsocks@$i grass@$i x11vnc@$i xvfb@$i grass-login@$i 2>/dev/null || true
  systemctl disable redsocks@$i grass@$i x11vnc@$i xvfb@$i grass-login@$i 2>/dev/null || true
done
rm -f /etc/systemd/system/multi-user.target.wants/{redsocks,grass,x11vnc,xvfb,grass-login}@*.service
systemctl reset-failed redsocks@* grass@* x11vnc@* xvfb@* grass-login@* 2>/dev/null || true
systemctl daemon-reload

# ─── 1. Пакеты ────────────────────────────────────────────────────
apt-get update -y
apt-get install -y xvfb x11vnc xdotool dbus-x11 wget redsocks iptables
systemctl disable --now redsocks.service 2>/dev/null || true
modprobe iptable_nat 2>/dev/null || true

if ! dpkg-query -W -f='${Status}' grass 2>/dev/null | grep -q ok; then
  wget -qO /tmp/grass.deb "$GRASS_DEB"
  apt-get install -y /tmp/grass.deb
fi

# ─── 2. Каталоги / данные ────────────────────────────────────────
mkdir -p /etc/grass/{proxies,vnc,redsocks}

cat > /etc/grass/accounts.list <<'ACC'
nikkijoon1@gmail.com	4]>jfs974NXjzDJ
ACC

cat > /etc/grass/proxies.list <<'PROXY'
res.proxy-seller.com:10000@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10000@22a737eb645bba34:RNW78Fm5
res.proxy-seller.com:10001@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10002@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10003@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10004@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10005@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10006@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10007@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10008@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10009@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10010@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10011@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10012@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10013@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10014@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10015@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10016@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10017@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10018@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10019@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10020@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10021@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10022@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10023@7c93fcd2c7d23ed4:RNW78Fm5
res.proxy-seller.com:10024@7c93fcd2c7d23ed4:RNW78Fm5
PROXY

# ─── 3. Helper-скрипты ────────────────────────────────────────────
cat >/usr/local/bin/gen_proxy_env.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
idx=$1
line=$(sed -n "${idx}p" /etc/grass/proxies.list)
[ -z "$line" ] && { echo "proxy line $idx empty" >&2; exit 1; }
url="socks5://$line"
printf 'ALL_PROXY=%s\nhttp_proxy=%s\nhttps_proxy=%s\n' "$url" "$url" "$url" > /etc/grass/proxies/${idx}.env
chmod 644 /etc/grass/proxies/${idx}.env
EOF
chmod 755 /usr/local/bin/gen_proxy_env.sh

cat >/usr/local/bin/gen_redsocks_conf.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
idx=$1
line=$(sed -n "${idx}p" /etc/grass/proxies.list)
[ -z "$line" ] && { echo "no proxy for $idx" >&2; exit 1; }
hostport=${line%@*}; loginpass=${line#*@}
host=${hostport%%:*}; port=${hostport##*:}
user=${loginpass%%:*}; pass=${loginpass##*:}
cat >/etc/grass/redsocks/${idx}.conf <<CONF
base {
  daemon = off;
  log_debug = off;
  log_info  = off;
  redirector = iptables;
  user  = nobody;
  group = nogroup;
}
redsocks {
  local_ip   = 127.0.0.1;
  local_port = $((10000 + idx));
  ip         = $host;
  port       = $port;
  type       = socks5;
  login      = "$user";
  password   = "$pass";
}
CONF
EOF
chmod 755 /usr/local/bin/gen_redsocks_conf.sh

cat >/usr/local/bin/redsocks_setup.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
idx=$1; action=$2
chain="GRASS${idx}_OUT"; rport=$((10000 + idx))
if [ "$action" = start ]; then
  iptables -t nat -N "$chain" 2>/dev/null || true
  iptables -t nat -F "$chain"
  iptables -t nat -A "$chain" -p tcp -j REDIRECT --to-ports "$rport"
  iptables -t nat -C OUTPUT -m owner --uid-owner "grass$idx" -p tcp -j "$chain" 2>/dev/null || \
    iptables -t nat -A OUTPUT -m owner --uid-owner "grass$idx" -p tcp -j "$chain"
else
  iptables -t nat -D OUTPUT -m owner --uid-owner "grass$idx" -p tcp -j "$chain" 2>/dev/null || true
  iptables -t nat -F "$chain" 2>/dev/null || true
fi
EOF
chmod 755 /usr/local/bin/redsocks_setup.sh

cat >/usr/local/bin/grass_x11vnc.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
inst=$1; port=$((5900 + inst))
exec /usr/bin/x11vnc -display ":$inst" -rfbport "$port" \
     -rfbauth /etc/grass/vnc/passwd"$inst" -forever -shared
EOF
chmod 755 /usr/local/bin/grass_x11vnc.sh

# ─── 4. Users / конфиги / VNC ─────────────────────────────────────
for i in $(seq 1 "$NUM_NODES"); do
  id -u grass"$i" &>/dev/null || useradd -m -s /usr/sbin/nologin grass"$i"
  /usr/local/bin/gen_proxy_env.sh "$i"
  /usr/local/bin/gen_redsocks_conf.sh "$i"
  pw="/etc/grass/vnc/passwd$i"
  [ -f "$pw" ] || x11vnc -storepasswd "$VNC_PASS" "$pw"
  chown grass"$i":grass"$i" "$pw" && chmod 600 "$pw"
done

# ─── 5. systemd шаблоны ────────────────────────────────────────────
cat >/etc/systemd/system/redsocks@.service <<'EOF'
[Unit]
Description=redsocks proxy for Grass %i
After=network.target
[Service]
ExecStartPre=/usr/local/bin/redsocks_setup.sh %i start
ExecStartPre=/usr/bin/env redsocks -t -c /etc/grass/redsocks/%i.conf
ExecStopPost=/usr/local/bin/redsocks_setup.sh %i stop
ExecStart=/usr/bin/env redsocks -c /etc/grass/redsocks/%i.conf
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/xvfb@.service <<'EOF'
[Unit]
Description=Xvfb for Grass %i
After=network.target
[Service]
User=grass%i
ExecStart=/usr/bin/Xvfb :%i -screen 0 1280x720x24
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/grass@.service <<'EOF'
[Unit]
Description=Grass GUI %i
After=xvfb@%i.service redsocks@%i.service
Wants=xvfb@%i.service redsocks@%i.service
[Service]
User=grass%i
Environment=DISPLAY=:%i
ExecStart=/usr/bin/grass -gui
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/x11vnc@.service <<'EOF'
[Unit]
Description=x11vnc for Grass %i
After=xvfb@%i.service
Wants=xvfb@%i.service
[Service]
User=grass%i
ExecStart=/usr/local/bin/grass_x11vnc.sh %i
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# ─── 6. Enable + start ────────────────────────────────────────────
systemctl daemon-reload
for i in $(seq 1 "$NUM_NODES"); do
  systemctl enable redsocks@$i xvfb@$i grass@$i x11vnc@$i
  systemctl start  redsocks@$i xvfb@$i grass@$i x11vnc@$i
done

echo -e "\n✅ Ферма запущена: $NUM_NODES нод(ы)."
echo   "   systemctl list-units --type=service | grep -E '(redsocks@|grass@|x11vnc@)'"
echo   "   После проверки GUI можно включить автокликер:"
echo   "   systemctl enable --now grass-login@1"
