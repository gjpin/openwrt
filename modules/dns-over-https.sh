#!/bin/sh

# Internal module sourced by setup.sh. DNSCrypt Proxy remains the DoH provider.

dns_over_https_run() {
    dnscrypt_source=$1/configs/dnscrypt/dnscrypt-proxy.toml
    dnscrypt_candidate=/tmp/dnscrypt-proxy.toml.setup.$$
    dnscrypt_config_file=${DNSCRYPT_CONFIG_FILE:-/etc/dnscrypt-proxy2/dnscrypt-proxy.toml}
    apk add dnscrypt-proxy2
    cp "$dnscrypt_source" "$dnscrypt_candidate"
    chmod 600 "$dnscrypt_candidate"
    dnscrypt-proxy -check -config "$dnscrypt_candidate"

    service dnsmasq stop
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci set dhcp.@dnsmasq[0].cachesize='0'
    uci -q delete dhcp.@dnsmasq[0].server
    # dnsmasq spells an explicit upstream port with '#'; this is the same
    # 127.0.0.53:53 endpoint used by DNSCrypt Proxy's listen_addresses.
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.53#53'
    uci commit dhcp

    dnscrypt_installed=${dnscrypt_config_file}.setup.$$
    cp "$dnscrypt_candidate" "$dnscrypt_installed"
    chmod 600 "$dnscrypt_installed"
    mv -f "$dnscrypt_installed" "$dnscrypt_config_file"
    rm -f "$dnscrypt_candidate"

    uci -q delete system.ntp.server
    uci add_list system.ntp.server='194.177.4.1'
    uci add_list system.ntp.server='213.222.217.11'
    uci add_list system.ntp.server='80.50.102.114'
    uci add_list system.ntp.server='193.219.28.60'
    uci commit system

    uci set network.wan.peerdns='0'
    uci set network.wan6.peerdns='0'
    uci commit network

    uci -q delete firewall.divert_dns_53 2>/dev/null || :
    uci set firewall.divert_dns_53='redirect'
    uci set firewall.divert_dns_53.name='Divert-DNS, port 53'
    uci set firewall.divert_dns_53.src='wan'
    uci set firewall.divert_dns_53.dest='lan'
    uci set firewall.divert_dns_53.src_dport='53'
    uci set firewall.divert_dns_53.dest_port='53'
    uci set firewall.divert_dns_53.target='DNAT'
    uci -q delete firewall.reject_dot_853 2>/dev/null || :
    uci set firewall.reject_dot_853='rule'
    uci set firewall.reject_dot_853.name='Reject-DoT, port 853'
    uci set firewall.reject_dot_853.src='lan'
    uci set firewall.reject_dot_853.dest='wan'
    uci set firewall.reject_dot_853.dest_port='853'
    uci set firewall.reject_dot_853.proto='tcp'
    uci set firewall.reject_dot_853.target='REJECT'
    uci -q delete firewall.divert_dns_5353 2>/dev/null || :
    uci set firewall.divert_dns_5353='redirect'
    uci set firewall.divert_dns_5353.name='Divert-DNS, port 5353'
    uci set firewall.divert_dns_5353.src='lan'
    uci set firewall.divert_dns_5353.dest='lan'
    uci set firewall.divert_dns_5353.src_dport='5353'
    uci set firewall.divert_dns_5353.dest_port='53'
    uci set firewall.divert_dns_5353.target='DNAT'
    uci commit firewall

    service dnscrypt-proxy restart
    service dnsmasq start
    service firewall reload
}
