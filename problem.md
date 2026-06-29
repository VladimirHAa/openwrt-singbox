# Диагностика роутера OpenWrt — 2026-06-30

## Инцидент
Интернет отвалился для всех LAN-устройств (server1C, HA и т.д.). Роутер пинговался, DNS резолвился, но трафик наружу не шёл.

## Корневая причина
**Файл `/etc/firewall.dns-mark` содержал невалидный синтаксис nftables**, из-за которого firewall4 полностью отказывался загружать правила.

### Цепочка событий
1. `firewall.dns-mark` содержал `add rule inet fw4 mangle_output ...` (standalone-синтаксис)
2. firewall4 вставляет файл **внутрь** таблицы `inet fw4 {}` через `option path`
3. Внутри таблицы `add rule` — невалиден (ожидается bare chain/rule без `add`)
4. nftables падает с `syntax error, unexpected add`
5. **Весь firewall не загружается** → нет NAT (masquerade), нет FORWARDING
6. Роутер сам пингует 8.8.8.8 (трафик не проходит через firewall), но LAN-устройства не могут достучаться
7. В логах: `The rendered ruleset contains errors, not doing firewall restart`

## Что сломалось

| Компонент | Состояние | Влияние |
|---|---|---|
| firewall4 (nftables) | Не загружался | Нет NAT → нет интернета для LAN |
| sing-box | Работал, но tun0 не виден | VPN-трафик не маршрутизировался |
| DNS | Резолвился через dnsmasq | DNS-запросы проходили, но без firewall |
| WAN interface | DHCP, IP 100.65.98.193/14 | Работал (телефонный тетеринг) |

## Найденные уязвимости (аудит)

### КРИТИЧНЫЕ

#### 1. `/etc/firewall.dns-mark` — невалидный синтаксис **[ИСПРАВЛЕНО]**
- **Проблема**: `add rule inet fw4 mangle_output ...` — standalone-синтаксис, невалиден внутри firewall4 include
- **Влияние**: Полный отказ firewall → нет NAT → нет интернета
- **Фикс**: Заменён на bare chain syntax:
  ```
  chain mangle_output {
      type route hook output priority mangle ;
      udp dport 53 meta mark set 0x1
      tcp dport 53 meta mark set 0x1
  }
  ```
- **Воспроизведение**: Любое изменение firewall.dns-mark с невалидным синтаксисом

#### 2. `option family 'any'` в include секции firewall **[ИСПРАВЛЕНО]**
- **Проблема**: fw4 не поддерживает `option family` в секции `config include`
- **Влияние**: Предупреждение при загрузке, потенциально — блокировка в будущих версиях
- **Фикс**: Удалена строка `option family 'any'`

#### 3. sing-box падает при restart firewall **[НЕ ИСПРАВЛЕНО — следствие]**
- **Проблема**: `/etc/init.d/firewall restart` убивает tun0 → sing-box теряет интерфейс
- **Влияние**: После любого firewall restart VPN-трафик не работает до перезапуска sing-box
- **Решение**: В healthcheck-скрипте добавлен `sleep 5` + проверка после firewall restart

### СРЕДНИЕ

#### 4. Нет watchdog для sing-box
- **Проблема**: sing-box упал → VPN мёртв, но没有人 знает
- **Влияние**: Тихая потеря VPN без уведомления
- **Решение**: Добавлен healthcheck каждые 5 минут

#### 5. DNS-утечки через dnsmasq
- **Проблема**: dnsmasq настроен с `noresolv '1'` и `list server '8.8.8.8'` — DNS идёт напрямую в 8.8.8.8, минуя sing-box
- **Влияние**: DNS-запросы не проходят через VPN
- **Решение**: Перенаправить DNS через sing-box (redirect port 53 → 172.16.250.1:53) или настроить dnsmasq → sing-box

#### 6. sing-box legacy outbounds deprecated
- **Проблема**: `WARN legacy special outbounds is deprecated in sing-box 1.11.0 and will be removed in sing-box 1.13.0`
- **Влияние**: При обновлении sing-box до 1.13+ конфиг сломается
- **Решение**: Мигрировать на rule-actions синтаксис

### НИЗКИЕ

#### 7. `/etc/firewall/` директория не существует
- **Проблема**: KB ссылается на `/etc/firewall/tproxy.rules` и `/etc/firewall/ip-rules`, но их нет
- **Влияние**: tproxy-правила не загружаются (но сейчас используется TUN-режим, не tproxy)
- **Решение**: Убрать ссылки из KB или создать пустые файлы

#### 8. hotplug `/etc/hotplug.d/iface/30-vpnroute` не существует
- **Проблема**: VPN-маршруты не восстанавливаются при переподключении интерфейсов
- **Влияние**: После переподключения WAN VPN-маршруты могут пропасть
- **Решение**: Создать hotplug-скрипт или полагаться на init.d sing-box

#### 9. sing-box `workdir` = `/tmp`
- **Проблема**: `/tmp` — tmpfs, может быть очищен
- **Влияние**: Минимальное (sing-box stateless), но логи и临时 файлы теряются

#### 10. Overlay 17% использован
- **Проблема**: 12.9MB из 78.6MB
- **Влияние**: Пока нормально, но мониторить

## Исправления, выполненные

| Действие | Файл | Описание |
|---|---|---|
| Исправлен синтаксис | `/etc/firewall.dns-mark` | Bare chain syntax вместо `add rule` |
| Удалена unsupported опция | `/etc/config/firewall` | `option family 'any'` из include |
| Создан healthcheck | `/usr/local/bin/router-healthcheck.sh` | Cron каждые 5 мин |
| Настроен cron | `/etc/crontabs/root` | `*/5 * * * * /usr/local/bin/router-healthcheck.sh` |

## Healthcheck проверяет
1. Firewall (nftables ruleset загружен)
2. sing-box процесс запущен
3. tun0 интерфейс существует
4. VPN-маршрут в таблице vpn
5. Internet доступен (ping 8.8.8.8)
6. DNS резолвит
7. Disk space overlay < 85%
8. Memory > 10MB свободно

## Текущее состояние (после фиксов)
- **Firewall**: Загружен, 0 warnings
- **Internet**: Работает (ping 8.8.8.8, google.com)
- **sing-box**: Запущен, tun0 UP
- **WAN**: 100.65.98.193/14 (DHCP, телефонный тетеринг)
- **Cron healthcheck**: Активен, каждые 5 минут

## Рекомендации
1. **Создать бэкап** `/etc/config/firewall` и `/etc/firewall.dns-mark` на server1C
2. **Настроить DNS через sing-box** — убрать DNS-утечки
3. **Мигрировать sing-box** на актуальный синтаксис (до 1.13.0)
4. **Настроить мониторинг** healthcheck лога (rsyslog → server1C или Telegram-уведомление)
5. **Добавить fail2ban** или ограничение SSH (dropbear PasswordAuth включён)

---

# Конфиги роутера (с sanitizied ключами)

## `/etc/config/firewall`

```
config defaults
	option syn_flood '1'
	option input 'REJECT'
	option output 'ACCEPT'
	option forward 'REJECT'

config zone
	option name 'lan'
	list network 'lan'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'

config zone
	option name 'wan'
	list network 'wan'
	list network 'wan6'
	option input 'REJECT'
	option output 'ACCEPT'
	option forward 'REJECT'
	option masq '1'
	option mtu_fix '1'

config forwarding
	option src 'lan'
	option dest 'wan'

config rule
	option name 'Allow-DHCP-Renew'
	option src 'wan'
	option proto 'udp'
	option dest_port '68'
	option target 'ACCEPT'
	option family 'ipv4'

config rule
	option name 'Allow-Ping'
	option src 'wan'
	option proto 'icmp'
	option icmp_type 'echo-request'
	option family 'ipv4'
	option target 'ACCEPT'

config rule
	option name 'Allow-IGMP'
	option src 'wan'
	option proto 'igmp'
	option family 'ipv4'
	option target 'ACCEPT'

config rule
	option name 'Allow-DHCPv6'
	option src 'wan'
	option proto 'udp'
	option dest_port '546'
	option family 'ipv6'
	option target 'ACCEPT'

config rule
	option name 'Allow-MLD'
	option src 'wan'
	option proto 'icmp'
	option src_ip 'fe80::/10'
	list icmp_type '130/0'
	list icmp_type '131/0'
	list icmp_type '132/0'
	list icmp_type '143/0'
	option family 'ipv6'
	option target 'ACCEPT'

config rule
	option name 'Allow-ICMPv6-Input'
	option src 'wan'
	option proto 'icmp'
	list icmp_type 'echo-request'
	list icmp_type 'echo-reply'
	list icmp_type 'destination-unreachable'
	list icmp_type 'packet-too-big'
	list icmp_type 'time-exceeded'
	list icmp_type 'bad-header'
	list icmp_type 'unknown-header-type'
	list icmp_type 'router-solicitation'
	list icmp_type 'neighbour-solicitation'
	list icmp_type 'router-advertisement'
	list icmp_type 'neighbour-advertisement'
	option limit '1000/sec'
	option family 'ipv6'
	option target 'ACCEPT'

config rule
	option name 'Allow-ICMPv6-Forward'
	option src 'wan'
	option dest '*'
	option proto 'icmp'
	list icmp_type 'echo-request'
	list icmp_type 'echo-reply'
	list icmp_type 'destination-unreachable'
	list icmp_type 'packet-too-big'
	list icmp_type 'time-exceeded'
	list icmp_type 'bad-header'
	list icmp_type 'unknown-header-type'
	option limit '1000/sec'
	option family 'ipv6'
	option target 'ACCEPT'

config rule
	option name 'Allow-IPSec-ESP'
	option src 'wan'
	option dest 'lan'
	option proto 'esp'
	option target 'ACCEPT'

config rule
	option name 'Allow-ISAKMP'
	option src 'wan'
	option dest 'lan'
	option dest_port '500'
	option proto 'udp'
	option target 'ACCEPT'

config zone
	option name 'tun'
	option forward 'ACCEPT'
	option output 'ACCEPT'
	option input 'ACCEPT'
	option masq '1'
	option mtu_fix '1'
	option device 'tun0'
	option family 'ipv4'

config forwarding
	option name 'lan-tun'
	option dest 'tun'
	option src 'lan'
	option family 'ipv4'

config rule
	option name 'All lan through tun'
	option src 'lan'
	option dest '*'
	option proto 'all'
	option set_mark '0x1'
	option target 'MARK'
	option family 'ipv4'

config include
	option path '/etc/firewall.dns-mark'
	option type 'nftables'
```

## `/etc/firewall.dns-mark`

```
chain mangle_output {
    type route hook output priority mangle ;
    udp dport 53 meta mark set 0x1
    tcp dport 53 meta mark set 0x1
}
```

## `/etc/config/network`

```
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix '<ULA_PREFIX>'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'lan1'
	list ports 'lan2'
	list ports 'lan3'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.1.1'
	option netmask '255.255.255.0'
	option ip6assign '60'

config device
	option name 'wan'
	option macaddr '<WAN_MAC>'

config interface 'wan'
	option device 'wan'
	option proto 'dhcp'
	option peerdns '0'

config interface 'wan6'
	option device 'wan'
	option proto 'dhcpv6'

config rule
	option priority '100'
	option lookup 'vpn'
	option mark '0x1'
```

## `/etc/iproute2/rt_tables`

```
#
# reserved values
#
128	prelocal
255	local
254	main
253	default
0	unspec
#
# local
#
99 vpn
```

## `/etc/config/sing-box` (UCI)

```
config sing-box 'main'
	option enabled '1'
	option user 'root'
	option conffile '/etc/config/sing-box-config.json'
	option workdir '/tmp'
```

## `/etc/config/sing-box-config.json`

```json
{
  "log": {
    "level": "warn"
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "tls://8.8.8.8",
        "detour": "proxy"
      },
      {
        "tag": "dns-direct",
        "address": "tls://1.1.1.1",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "domain_suffix": [".ru", ".su"],
        "server": "dns-direct"
      },
      {
        "domain_suffix": ["protonam.com"],
        "server": "dns-direct"
      }
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "domain_strategy": "ipv4_only",
      "address": ["172.16.250.1/30"],
      "auto_route": false,
      "strict_route": false,
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-vdska",
      "server": "31.77.77.47",
      "server_port": 9444,
      "password": "<HY2_PASSWORD>",
      "tls": {
        "enabled": true,
        "insecure": true,
        "server_name": "www.oracle.com"
      }
    },
    {
      "type": "vless",
      "tag": "nj-vless",
      "server": "46.8.233.202",
      "server_port": 9443,
      "uuid": "<UUID_NJ_VLESS>",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.oracle.com",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "<REALITY_PUBLIC_KEY>",
          "short_id": "<SHORT_ID>"
        }
      }
    },
    {
      "type": "urltest",
      "tag": "proxy",
      "outbounds": ["hy2-vdska", "nj-vless"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 100,
      "interrupt_exist_connections": false
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_cidr": ["46.8.233.202/32"],
        "outbound": "direct"
      },
      {
        "ip_cidr": ["31.77.77.47/32"],
        "outbound": "direct"
      },
      {
        "ip_cidr": ["94.126.153.10/32"],
        "outbound": "direct"
      },
      {
        "domain_suffix": ["protonam.com"],
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "domain_suffix": [".ru", ".su"],
        "outbound": "direct"
      },
      {
        "protocol": "dns",
        "outbound": "dns-out"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
```

## `/etc/config/dhcp`

```
config dnsmasq
	option domainneeded '1'
	option boguspriv '1'
	option filterwin2k '0'
	option localise_queries '1'
	option rebind_protection '1'
	option rebind_localhost '1'
	option local '/lan/'
	option domain 'lan'
	option expandhosts '1'
	option nonegcache '0'
	option cachesize '1000'
	option authoritative '1'
	option readethers '1'
	option leasefile '/tmp/dhcp.leases'
	option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option nonwildcard '1'
	option localservice '1'
	option ednspacket_max '1232'
	option filter_aaaa '1'
	option filter_a '0'
	option confdir '/tmp/dnsmasq.d'
	option noresolv '1'
	list server '8.8.8.8'
	list server '1.1.1.1'

config dhcp 'lan'
	option interface 'lan'
	option start '100'
	option limit '150'
	option leasetime '12h'
	option dhcpv4 'server'
	option dhcpv6 'server'
	option ra 'server'
	option ra_slaac '1'
	list ra_flags 'managed-config'
	list ra_flags 'other-config'

config dhcp 'wan'
	option interface 'wan'
	option ignore '1'

config odhcpd 'odhcpd'
	option maindhcp '0'
	option leasefile '/tmp/hosts/odhcpd'
	option leasetrigger '/usr/sbin/odhcpd-update'
	option loglevel '4'
```

## `/etc/config/dropbear`

```
config dropbear
	option PasswordAuth 'on'
	option Port '22'
	option Interface 'lan'
```

## `/etc/config/ruantiblock`

```
config main 'config'
	option proxy_mode '1'
	option proxy_local_clients '1'
	option enable_logging '1'
	option update_at_startup '1'
	option nftset_clear_sets '1'
	option allowed_hosts_mode '0'
	option enable_fproxy '0'
	option if_vpn 'tun0'
	option vpn_route_check '0'
	option tor_trans_port '9040'
	option onion_dns_addr '127.0.0.1#9053'
	option t_proxy_port_tcp '1100'
	option t_proxy_port_udp '1100'
	option t_proxy_allow_udp '0'
	option bypass_mode '0'
	option enable_bllist_proxy '0'
	option enable_tmp_downloads '0'
	option add_user_entries '0'
	option bllist_min_entries '3000'
	option bllist_ip_limit '0'
	option bllist_summarize_ip '1'
	option bllist_summarize_cidr '1'
	option bllist_ip_filter '0'
	option bllist_ip_filter_type '0'
	option bllist_sd_limit '16'
	option bllist_fqdn_filter '1'
	option bllist_fqdn_filter_type '0'
	option bllist_enable_idn '0'
	option bllist_alt_nslookup '0'
	option bllist_alt_dns_addr '8.8.8.8'
	option bllist_module '/usr/libexec/ruantiblock/ruab_parser.lua'
```

## `/etc/rc.local`

```
exit 0
```

## `/etc/crontabs/root`

```
*/5 * * * * /usr/local/bin/router-healthcheck.sh
```

## `/usr/local/bin/router-healthcheck.sh`

```sh
#!/bin/sh
LOG="/tmp/router-healthcheck.log"
TIMESTAMP=$(date 2>/dev/null || echo "unknown")

# 1. Check firewall (nftables ruleset loaded)
if ! nft list ruleset 2>/dev/null | grep -q "chain forward"; then
    echo "$TIMESTAMP: FAIL - firewall not loaded, restarting" >> "$LOG"
    /etc/init.d/firewall restart 2>&1 >> "$LOG"
    sleep 5
fi

# 2. Check sing-box process
if ! pgrep -x sing-box > /dev/null 2>&1; then
    echo "$TIMESTAMP: FAIL - sing-box not running, restarting" >> "$LOG"
    /etc/init.d/sing-box restart 2>&1 >> "$LOG"
    sleep 3
fi

# 3. Check tun0 interface
if ! ip link show tun0 > /dev/null 2>&1; then
    echo "$TIMESTAMP: FAIL - tun0 not present, restarting sing-box" >> "$LOG"
    /etc/init.d/sing-box restart 2>&1 >> "$LOG"
    sleep 3
fi

# 4. Check VPN route in table vpn
if ! ip route show table vpn 2>/dev/null | grep -q tun0; then
    echo "$TIMESTAMP: WARN - VPN route missing, adding" >> "$LOG"
    ip route replace table vpn default dev tun0
fi

# 5. Check internet via WAN (ping through router itself)
if ! ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
    echo "$TIMESTAMP: WARN - WAN internet unreachable" >> "$LOG"
fi

# 6. Check DNS resolution
if ! nslookup google.com > /dev/null 2>&1; then
    echo "$TIMESTAMP: WARN - DNS not resolving" >> "$LOG"
fi

# 7. Check disk space (overlay)
OVERLAY_USED=$(df /overlay 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
if [ -n "$OVERLAY_USED" ] && [ "$OVERLAY_USED" -gt 85 ] 2>/dev/null; then
    echo "$TIMESTAMP: WARN - overlay disk usage ${OVERLAY_USED}%" >> "$LOG"
fi

# 8. Check memory
MEM_FREE=$(free 2>/dev/null | awk '/Mem:/ {print $4}')
if [ -n "$MEM_FREE" ] && [ "$MEM_FREE" -lt 10000 ] 2>/dev/null; then
    echo "$TIMESTAMP: WARN - low memory: ${MEM_FREE}KB free" >> "$LOG"
fi

# Trim log to last 500 lines
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 500 ]; then
    tail -250 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
```

## Routing: ip rules и VPN table

```
ip rule list:
0:    from all lookup local
100:  from all fwmark 0x1 lookup vpn
32766: from all lookup main
32767: from all lookup default

ip route show table vpn:
default dev tun0 scope link
```

## Системная информация

```
OpenWrt 23.05.5 r24106-10cc5fcd00
Target: mediatek/mt7622 (aarch64_cortex-a53)
Kernel: Linux OpenWrt 5.15.167 #0 SMP Mon Sep 23 12:34:46 2024 aarch64

sing-box: 1.11.15 (go1.21.13 linux/arm64)
Tags: with_clash_api,with_ech,with_gvisor,with_quic,with_reality_server,with_utls,with_wireguard

Overlay: 12.9MB / 78.6MB (17%)
RAM: 245360KB total, ~97000KB free
Uptime: varies (перезагружался сегодня)
```

### Ключевые пакеты
- firewall4 2023-09-01
- sing-box 1.11.15-1 (opkg, with_hysteria)
- dnsmasq-full 2.90-2
- dropbear 2022.82-6
- nftables-json 1.0.8-1
- iptables-nft 1.8.8-2
- ruantiblock 1.6.0-1 (disabled)
- banip 1.0.0-8
- adblock 4.2.2-6
- https-dns-proxy 2023.12.26-1
- miniupnpd-nftables 2.3.3-2

## Полный nftables ruleset (после фиксов)

```
table inet fw4 {
    ct helper amanda { type "amanda" protocol udp; l3proto inet; }
    ct helper RAS { type "RAS" protocol udp; l3proto inet; }
    ct helper Q.931 { type "Q.931" protocol tcp; l3proto inet; }
    ct helper irc { type "irc" protocol tcp; l3proto ip; }
    ct helper pptp { type "pptp" protocol tcp; l3proto ip; }
    ct helper sip { type "sip" protocol udp; l3proto inet; }
    ct helper snmp { type "snmp" protocol udp; l3proto ip; }
    ct helper tftp { type "tftp" protocol udp; l3proto inet; }

    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state established,related accept
        tcp flags syn / fin,syn,rst,ack jump syn_flood
        iifname "br-lan" jump input_lan
        iifname "wan" jump input_wan
        meta nfproto ipv4 iifname "tun0" jump input_tun
        jump handle_reject
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        iifname "br-lan" jump forward_lan
        iifname "wan" jump forward_wan
        meta nfproto ipv4 iifname "tun0" jump forward_tun
        jump upnp_forward
        jump handle_reject
    }

    chain output {
        type filter hook output priority filter; policy accept;
        oifname "lo" accept
        ct state established,related accept
        oifname "br-lan" jump output_lan
        oifname "wan" jump output_wan
        meta nfproto ipv4 oifname "tun0" jump output_tun
    }

    chain prerouting {
        type filter hook prerouting priority filter; policy accept;
        iifname "br-lan" jump helper_lan
    }

    chain forward_lan {
        jump accept_to_wan
        meta nfproto ipv4 jump accept_to_tun
        jump accept_to_lan
    }

    chain srcnat_wan {
        meta nfproto ipv4 masquerade
    }

    chain srcnat_tun {
        meta nfproto ipv4 masquerade
    }

    chain mangle_prerouting {
        type filter hook prerouting priority mangle; policy accept;
        meta nfproto ipv4 iifname "br-lan" meta mark set 0x00000001
    }

    chain mangle_output {
        type route hook output priority mangle; policy accept;
        udp dport 53 meta mark set 0x00000001
        tcp dport 53 meta mark set 0x00000001
    }
}
```

### Анализ nftables ruleset

**Маршрутизация трафика:**
1. `mangle_prerouting`: весь IPv4 трафик с br-lan помечается mark 0x1
2. `ip rule` (priority 100): mark 0x1 → table vpn → default dev tun0
3. **Все LAN-устройства** отправляют весь IPv4 трафик через sing-box TUN

**DNS:**
1. `mangle_output`: DNS (udp/tcp 53) с роутера помечается mark 0x1 → VPN
2. dnsmasq → 8.8.8.8 напрямую (без VPN) — DNS-утечка

**NAT:**
- `srcnat_wan`: masquerade для wan (но LAN-трафик идёт через tun)
- `srcnat_tun`: masquerade для tun

**Потенциальные проблемы:**
- Два forwarding пути: lan→wan И lan→tun. Трафик с mark 0x1 идёт через tun, но если sing-box упал — трафик идёт через wan (fallback)
- dnsmasq не перенаправлен через sing-box

## `/etc/init.d/sing-box` (init script)

```sh
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99

script=$(readlink "$initscript")
NAME="$(basename ${script:-$initscript})"
PROG="/usr/bin/sing-box"

start_service() {
    config_load "$NAME"

    local enabled user group conffile workdir ifaces
    config_get_bool enabled "main" "enabled" "0"
    [ "$enabled" -eq "1" ] || return 0

    config_get user "main" "user" "root"
    config_get conffile "main" "conffile"
    config_get ifaces "main" "ifaces"
    config_get workdir "main" "workdir" "/usr/share/sing-box"

    mkdir -p "$workdir"
    local group="$(id -ng $user)"
    chown $user:$group "$workdir"

    procd_open_instance "$NAME.main"
    procd_set_param command "$PROG" run -c "$conffile" -D "$workdir"

    procd_set_param user "$user"
    procd_set_param file "$conffile"
    [ -z "$ifaces" ] || procd_set_param netdev $ifaces
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn

    # Wait for tun0 and add route to table vpn (background)
    ( for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -e /sys/class/net/tun0 ] && break
        sleep 1
    done; ip route replace table vpn default dev tun0 ) &
    procd_close_instance
}

service_triggers() {
    local ifaces
    config_load "$NAME"
    config_get ifaces "main" "ifaces"
    procd_open_trigger
    for iface in $ifaces; do
        procd_add_interface_trigger "interface.*.up" $iface /etc/init.d/$NAME restart
    done
    procd_close_trigger
    procd_add_reload_trigger "$NAME"
}
```

### Замечания по init script
- `procd_set_param respawn` — sing-box автоматически перезапускается при падении
- VPN route добавляется background-процессом с wait до 10 секунд
- `ifaces` пуст → триггер на изменение интерфейсов не активен

## OpenWrt installed services (enabled/disabled)

| Сервис | Состояние | Примечание |
|---|---|---|
| sing-box | enabled | VPN proxy |
| firewall | enabled | nftables (firewall4) |
| dnsmasq | enabled | DNS + DHCP |
| dropbear | enabled | SSH (PasswordAuth on) |
| cron | enabled | Healthcheck |
| ruantiblock | disabled | Антиблокировка |
| adblock | installed | Блокировка рекламы |
| banip | installed | Ban IP ranges |
| miniupnpd | enabled | UPnP |
| https-dns-proxy | installed | DoH proxy |
| nextdns | installed | NextDNS |
| collectd | enabled | Мониторинг |
| sqm | installed | SQM QoS |
| watchcat | installed | Watchdog |
| ddns | installed | Dynamic DNS |
| openvpn | installed | OpenVPN |
| ttyd | installed | Web terminal |
