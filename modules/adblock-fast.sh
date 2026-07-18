#!/bin/sh

# Internal module sourced by setup.sh.

adblock_fast_run() {
    apk add adblock-fast luci-app-adblock-fast

    uci set adblock-fast.config.enabled='1'
    uci set adblock-fast.config.dns='dnsmasq.servers'
    uci set adblock-fast.config.force_dns='1'
    uci -q delete adblock-fast.config.force_dns_interface 2>/dev/null || :
    uci add_list adblock-fast.config.force_dns_interface='pixelmain'
    uci add_list adblock-fast.config.force_dns_interface='pixelsecondary'
    uci add_list adblock-fast.config.force_dns_interface='pixelguest'
    uci add_list adblock-fast.config.force_dns_interface='pixeliot'
    uci -q delete adblock-fast.config.force_dns_port 2>/dev/null || :
    uci add_list adblock-fast.config.force_dns_port='53'
    uci add_list adblock-fast.config.force_dns_port='853'
    uci set adblock-fast.config.download_allow_insecure='0'
    uci set adblock-fast.config.allow_non_ascii='0'

    uci -q delete adblock-fast.adguard_general 2>/dev/null || :
    uci set adblock-fast.adguard_general='file_url'
    uci set adblock-fast.adguard_general.name='AdGuard general'
    uci set adblock-fast.adguard_general.url='https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt'
    uci set adblock-fast.adguard_general.action='block'
    uci set adblock-fast.adguard_general.enabled='1'

    uci -q delete adblock-fast.hagezi_pro 2>/dev/null || :
    uci set adblock-fast.hagezi_pro='file_url'
    uci set adblock-fast.hagezi_pro.name='Hagezi Pro'
    uci set adblock-fast.hagezi_pro.url='https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro-onlydomains.txt'
    uci set adblock-fast.hagezi_pro.action='block'
    uci set adblock-fast.hagezi_pro.enabled='1'

    uci -q delete adblock-fast.adguard_cname_trackers 2>/dev/null || :
    uci set adblock-fast.adguard_cname_trackers='file_url'
    uci set adblock-fast.adguard_cname_trackers.name='AdGuard CNAME trackers'
    uci set adblock-fast.adguard_cname_trackers.url='https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_disguised_trackers_justdomains.txt'
    uci set adblock-fast.adguard_cname_trackers.action='block'
    uci set adblock-fast.adguard_cname_trackers.enabled='1'

    uci -q delete adblock-fast.cert_polska 2>/dev/null || :
    uci set adblock-fast.cert_polska='file_url'
    uci set adblock-fast.cert_polska.name='CERT Polska'
    uci set adblock-fast.cert_polska.url='https://hole.cert.pl/domains/v2/domains.txt'
    uci set adblock-fast.cert_polska.action='block'
    uci set adblock-fast.cert_polska.enabled='1'

    uci commit adblock-fast
    service adblock-fast enable
    service adblock-fast restart
}
