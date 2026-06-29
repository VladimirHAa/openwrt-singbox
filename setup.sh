#!/bin/sh
# setup.sh — автоматическая настройка sing-box TUN на OpenWrt
# Запускать на роутере: ssh root@192.168.1.1 'sh -s' < setup.sh

set -e

echo "=== openwrt-singbox setup ==="

# 1. init.d + config
echo "[1/6] init.d и конфиги..."
# improved init.d with route fix
if [ -f /etc/init.d/sing-box ]; then
  cp /etc/init.d/sing-box /etc/init.d/sing-box.bak 2>/dev/null || true
fi
# copy the fixed init script (will be provided separately)
# manual step: copy scripts/sing-box.init to /etc/init.d/sing-box

if [ ! -f /etc/config/sing-box-config.json ]; then
  echo "ERROR: /etc/config/sing-box-config.json не найден!"
  echo "Скопируй templates/sing-box-config.json, замени плейсхолдеры и запусти заново."
  exit 1
fi

# 2. zone tun
echo "[2/6] Настройка firewall..."
if ! uci show firewall.tun >/dev/null 2>&1; then
  uci add firewall zone
  uci set firewall.@zone[-1].name='tun'
  uci set firewall.@zone[-1].forward='ACCEPT'
  uci set firewall.@zone[-1].output='ACCEPT'
  uci set firewall.@zone[-1].input='ACCEPT'
  uci set firewall.@zone[-1].masq='1'
  uci set firewall.@zone[-1].mtu_fix='1'
  uci set firewall.@zone[-1].device='tun0'
  uci set firewall.@zone[-1].family='ipv4'
fi

# 3. forwarding lan->tun
if ! uci show firewall.lan-tun >/dev/null 2>&1; then
  uci add firewall forwarding
  uci set firewall.@forwarding[-1].name='lan-tun'
  uci set firewall.@forwarding[-1].dest='tun'
  uci set firewall.@forwarding[-1].src='lan'
  uci set firewall.@forwarding[-1].family='ipv4'
fi

# 4. mark rule
if ! uci show firewall.All_lan_through_tun >/dev/null 2>&1; then
  uci add firewall rule
  uci set firewall.@rule[-1].name='All lan through tun'
  uci set firewall.@rule[-1].src='lan'
  uci set firewall.@rule[-1].dest='*'
  uci set firewall.@rule[-1].proto='all'
  uci set firewall.@rule[-1].set_mark='0x1'
  uci set firewall.@rule[-1].target='MARK'
  uci set firewall.@rule[-1].family='ipv4'
fi


# 4.1. dns mark for router-originated traffic
if [ ! -f /etc/firewall.dns-mark ]; then
  cat > /etc/firewall.dns-mark << 'EOF'
#!/usr/sbin/nft -f
add rule inet fw4 mangle_output udp dport 53 meta mark set 0x1
add rule inet fw4 mangle_output tcp dport 53 meta mark set 0x1
EOF
  chmod +x /etc/firewall.dns-mark
fi

if ! uci show firewall | grep -q firewall.dns-mark; then
  uci add firewall include
  uci set firewall.@include[-1].path=/etc/firewall.dns-mark
  uci set firewall.@include[-1].family=any
  uci set firewall.@include[-1].type=nftables
fi
uci commit firewall
service firewall restart

# 5. routing
echo "[3/6] Настройка маршрутизации..."
if ! grep -q '99 vpn' /etc/iproute2/rt_tables 2>/dev/null; then
  echo '99 vpn' >> /etc/iproute2/rt_tables
fi

if ! uci show network.@rule[-1] 2>/dev/null | grep -q lookup.*vpn; then
  uci add network rule
  uci set network.@rule[-1].priority='100'
  uci set network.@rule[-1].lookup='vpn'
  uci set network.@rule[-1].mark='0x1'
  uci commit network
fi

# 6. hotplug
echo "[4/6] Hotplug script..."
mkdir -p /etc/hotplug.d/iface
if [ ! -f /etc/hotplug.d/iface/30-vpnroute ]; then
  cat > /etc/hotplug.d/iface/30-vpnroute << 'EOF'
#!/bin/sh
sleep 5
ip route add table vpn default dev tun0
EOF
  chmod +x /etc/hotplug.d/iface/30-vpnroute
fi

# 7. restart
echo "[5/6] Перезапуск сети..."
service network restart
sleep 3

# 8. start sing-box
echo "[6/6] Запуск sing-box..."
service sing-box enable 2>/dev/null || true
service sing-box stop 2>/dev/null || true
service sing-box start

echo ""
echo "=== Готово. Проверка: ==="
sleep 2
curl --interface tun0 -s ifconfig.me && echo ""
curl -s -o /dev/null -w "YouTube: %{http_code}\n" https://www.youtube.com
