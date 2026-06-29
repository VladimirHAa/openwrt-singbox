# openwrt-singbox

Настройка sing-box (VLESS+REALITY) на OpenWrt 23.05 через TUN интерфейс.

## Состав

| Файл | Назначение |
|------|-----------|
| `configs/sing-box` | UCI конфиг sing-box |
| `templates/sing-box-config.json` | Основной конфиг (с плейсхолдерами) |
| `configs/firewall` | Правила firewall (зона tun + маркировка) |
| `configs/network` | Правило маршрутизации (lookup vpn) |
| `configs/rt_tables` | Таблица маршрутизации vpn |
| `scripts/30-vpnroute` | Hotplug скрипт для маршрута |
| `scripts/sing-box.init` | init.d скрипт (добавлен route после старта) |
| `setup.sh` | Скрипт автоматической настройки |

## Схема

```
LAN (192.168.1.0/24)
  │
  ├─ firewall rule: mark 0x1
  │
  ├─ ip rule: fwmark 0x1 → table vpn
  │
  ├─ ip route: default dev tun0 (table vpn)
  │
  └─ sing-box TUN (172.16.250.1/30)
       │
       └─ VLESS+REALITY → VPS
```

## Установка

### 1. Установить sing-box

```bash
opkg update && opkg install sing-box
```

### 2. Скопировать конфиги

```bash
cp configs/sing-box /etc/config/sing-box
cp templates/sing-box-config.json /etc/config/sing-box-config.json
# заменить плейсхолдеры __VPS_IP__, __UUID__ и т.д.
```

### 3. Настроить firewall

```bash
# зона tun
uci add firewall zone
uci set firewall.@zone[-1].name='tun'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci set firewall.@zone[-1].device='tun0'
uci set firewall.@zone[-1].family='ipv4'

# forwarding lan->tun
uci add firewall forwarding
uci set firewall.@forwarding[-1].name='lan-tun'
uci set firewall.@forwarding[-1].dest='tun'
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].family='ipv4'

# маркировка LAN трафика
uci add firewall rule
uci set firewall.@rule[-1].name='All lan through tun'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='*'
uci set firewall.@rule[-1].proto='all'
uci set firewall.@rule[-1].set_mark='0x1'
uci set firewall.@rule[-1].target='MARK'
uci set firewall.@rule[-1].family='ipv4'

uci commit firewall
service firewall restart
```

### 4. Настроить маршрутизацию

```bash
echo '99 vpn' >> /etc/iproute2/rt_tables

# добавить в /etc/config/network:
# config rule
#   option priority '100'
#   option lookup 'vpn'
#   option mark '0x1'

uci add network rule
uci set network.@rule[-1].priority='100'
uci set network.@rule[-1].lookup='vpn'
uci set network.@rule[-1].mark='0x1'
uci commit network

# hotplug скрипт
mkdir -p /etc/hotplug.d/iface
cp scripts/30-vpnroute /etc/hotplug.d/iface/30-vpnroute
chmod +x /etc/hotplug.d/iface/30-vpnroute

service network restart
```

### 5. init.d скрипт (фикс для переживания ребута)

Стандартный init.d скрипт не добавляет маршрут в таблицу vpn после старта tun0.
Заменить на исправленный:

```bash
cp scripts/sing-box.init /etc/init.d/sing-box
chmod +x /etc/init.d/sing-box
```

### 6. Запустить

```bash
service sing-box enable
service sing-box start
```

### 7. Проверка

```bash
curl --interface tun0 ifconfig.me   # должен показать IP VPS
curl -s -o /dev/null -w '%{http_code}' https://www.youtube.com  # 200
```
