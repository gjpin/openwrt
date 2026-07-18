#!/bin/sh

# Internal module sourced by setup.sh.

wireguard_run() {
    apk add wireguard-tools luci-proto-wireguard

    uci -q delete "network.$VPN_IF" 2>/dev/null || :
    uci set "network.$VPN_IF=interface"
    uci set "network.$VPN_IF.proto=wireguard"
    uci set "network.$VPN_IF.private_key=$VPN_KEY"
    uci set "network.$VPN_IF.listen_port=$VPN_PORT"
    uci add_list "network.$VPN_IF.addresses=$VPN_ADDR"
    uci add_list "network.$VPN_IF.addresses=$VPN_ADDR6"
    uci -q delete network.wgclient 2>/dev/null || :
    uci set "network.wgclient=wireguard_$VPN_IF"
    uci set "network.wgclient.public_key=$VPN_PUB"
    uci set "network.wgclient.preshared_key=$VPN_PSK"
    uci add_list "network.wgclient.allowed_ips=${VPN_ADDR%.*}.2/32"
    uci add_list "network.wgclient.allowed_ips=${VPN_ADDR6%:*}:2/128"
    uci commit network

    uci del_list "firewall.pixelmain.network=$VPN_IF" 2>/dev/null || :
    uci add_list "firewall.pixelmain.network=$VPN_IF"
    uci -q delete firewall.allow_wireguard 2>/dev/null || :
    uci set firewall.allow_wireguard='rule'
    uci set firewall.allow_wireguard.name='Allow-WireGuard'
    uci set firewall.allow_wireguard.src='wan'
    uci set "firewall.allow_wireguard.dest_port=$VPN_PORT"
    uci set firewall.allow_wireguard.proto='udp'
    uci set firewall.allow_wireguard.target='ACCEPT'
    uci commit firewall

    service network restart
    service firewall restart
}
