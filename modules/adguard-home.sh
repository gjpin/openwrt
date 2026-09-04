#!/bin/sh

# AdGuard Home package installation and transaction callbacks.

adguard_home_inputs_preflight() {
    ADGUARD_USERNAME=${ADGUARD_USERNAME:-}
    ADGUARD_PASSWORD_HASH=${ADGUARD_PASSWORD_HASH:-}
    DNS_REBIND_DOMAIN=${DNS_REBIND_DOMAIN:-}
    VPN_ADDR=${VPN_ADDR:-}

    [ -n "$ADGUARD_USERNAME" ] || die 'required variable is empty: ADGUARD_USERNAME'
    [ "${#ADGUARD_USERNAME}" -le 64 ] || die 'ADGUARD_USERNAME must not exceed 64 characters'
    case $ADGUARD_USERNAME in
        [A-Za-z0-9]*) ;;
        *) die 'ADGUARD_USERNAME must begin with a letter or digit' ;;
    esac
    case $ADGUARD_USERNAME in
        *[!A-Za-z0-9_.-]*)
            die 'ADGUARD_USERNAME may contain only letters, digits, dot, underscore, and hyphen'
            ;;
    esac

    [ -n "$ADGUARD_PASSWORD_HASH" ] || die 'required variable is empty: ADGUARD_PASSWORD_HASH'
    [ "${#ADGUARD_PASSWORD_HASH}" -eq 60 ] ||
        die 'ADGUARD_PASSWORD_HASH must be a 60-character bcrypt hash'
    case $ADGUARD_PASSWORD_HASH in
        \$2a\$* | \$2b\$* | \$2y\$*) ;;
        *) die 'ADGUARD_PASSWORD_HASH must use the bcrypt 2a, 2b, or 2y format' ;;
    esac
    case $ADGUARD_PASSWORD_HASH in
        *[!A-Za-z0-9./\$]*) die 'ADGUARD_PASSWORD_HASH contains an invalid bcrypt character' ;;
    esac
    adguard_bcrypt_cost=$(printf '%s' "$ADGUARD_PASSWORD_HASH" | cut -c5-6)
    case $adguard_bcrypt_cost in
        '' | *[!0-9]*) die 'ADGUARD_PASSWORD_HASH has an invalid bcrypt cost' ;;
    esac
    [ "$adguard_bcrypt_cost" -ge 4 ] 2>/dev/null &&
        [ "$adguard_bcrypt_cost" -le 31 ] 2>/dev/null ||
        die 'ADGUARD_PASSWORD_HASH bcrypt cost must be from 04 through 31'

    case $VPN_ADDR in
        *.*.*.*/*) : ;;
        *) die 'VPN_ADDR must be an IPv4 CIDR address for the AdGuard Home listener' ;;
    esac
    case $VPN_ADDR in
        *[!0-9./]* | */*/*) die 'VPN_ADDR must contain one IPv4 address and prefix length' ;;
    esac
    ADGUARD_WIREGUARD_BIND_HOST=${VPN_ADDR%/*}
    wireguard_prefix=${VPN_ADDR##*/}
    case $wireguard_prefix in
        '' | *[!0-9]*) die 'VPN_ADDR prefix must be an integer from 0 through 32' ;;
    esac
    [ "$wireguard_prefix" -le 32 ] 2>/dev/null ||
        die 'VPN_ADDR prefix must be an integer from 0 through 32'
    old_ifs=$IFS
    IFS=.
    # Intentional field splitting validates the four IPv4 octets.
    # shellcheck disable=SC2086
    set -- $ADGUARD_WIREGUARD_BIND_HOST
    IFS=$old_ifs
    [ "$#" -eq 4 ] || die 'VPN_ADDR must contain exactly four IPv4 octets'
    for wireguard_octet in "$@"; do
        case $wireguard_octet in
            '' | *[!0-9]*) die 'VPN_ADDR contains an invalid IPv4 octet' ;;
        esac
        [ "$wireguard_octet" -le 255 ] 2>/dev/null ||
            die 'VPN_ADDR contains an IPv4 octet greater than 255'
    done

    [ -n "$DNS_REBIND_DOMAIN" ] || {
        export ADGUARD_USERNAME ADGUARD_PASSWORD_HASH DNS_REBIND_DOMAIN ADGUARD_WIREGUARD_BIND_HOST
        return 0
    }
    DNS_REBIND_DOMAIN=$(
        # shellcheck disable=SC2018,SC2019
        printf '%s' "$DNS_REBIND_DOMAIN" |
            tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
    )
    [ "${#DNS_REBIND_DOMAIN}" -le 253 ] ||
        die 'DNS_REBIND_DOMAIN must not exceed 253 characters'
    case $DNS_REBIND_DOMAIN in
        *.*) ;;
        *) die 'DNS_REBIND_DOMAIN must contain at least two DNS labels' ;;
    esac
    case $DNS_REBIND_DOMAIN in
        *[!a-z0-9.-]* | .* | *. | *..*)
            die 'DNS_REBIND_DOMAIN must be one ASCII apex domain using valid DNS labels'
            ;;
    esac
    remaining_labels=$DNS_REBIND_DOMAIN
    while :; do
        case $remaining_labels in
            *.*)
                domain_label=${remaining_labels%%.*}
                remaining_labels=${remaining_labels#*.}
                ;;
            *)
                domain_label=$remaining_labels
                remaining_labels=
                ;;
        esac
        [ "${#domain_label}" -le 63 ] ||
            die 'DNS_REBIND_DOMAIN labels must not exceed 63 characters'
        case $domain_label in
            [a-z0-9] | [a-z0-9]*[a-z0-9]) ;;
            *) die 'DNS_REBIND_DOMAIN labels must start and end with a letter or digit' ;;
        esac
        [ -n "$remaining_labels" ] || break
    done
    export ADGUARD_USERNAME ADGUARD_PASSWORD_HASH DNS_REBIND_DOMAIN ADGUARD_WIREGUARD_BIND_HOST
}

adguard_home_install() {
    adguard_init=${ROUTER_CONFIG_ADGUARDHOME_INIT:-/etc/init.d/adguardhome}
    adguard_was_enabled=0
    if [ -x "$adguard_init" ] && "$adguard_init" enabled >/dev/null 2>&1; then
        adguard_was_enabled=1
    fi
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        attempt=$((attempt + 1))
        apk add adguardhome luci-app-adguardhome && break
        [ "$attempt" -lt 5 ] || die 'failed to install AdGuard Home packages'
        sleep $((attempt * 2))
    done
    [ "$adguard_was_enabled" = 0 ] || return 0
    "$adguard_init" stop >/dev/null 2>&1 || :
    "$adguard_init" disable || die 'failed to keep AdGuard Home disabled before confirmation'
}

adguard_home_render_config() {
    output_file=$1
    awk -v username="$ADGUARD_USERNAME" \
        -v password_hash="$ADGUARD_PASSWORD_HASH" \
        -v rebind_domain="$DNS_REBIND_DOMAIN" \
        -v wireguard_bind_host="$ADGUARD_WIREGUARD_BIND_HOST" '
        $0 == "@ADGUARD_USER@" {
            print "- name: \047" username "\047"
            print "  password: \047" password_hash "\047"
            next
        }
        $0 == "@USER_RULES@" {
            print "user_rules:"
            print "- \047@@||steamconnecttest.com^\047"
            print "- \047@@||ipv6check-udp.steamserver.net^\047"
            print "- \047@@||ipv6check-http.steamserver.net^\047"
            print "- \047@@||suggestqueries*.youtube.com^\047"
            print "- \047@@||suggestqueries.google.com^\047"
            print "- \047@@||clients1.google.com^\047"
            print "- \047@@||clients2.google.com^\047"
            print "- \047@@||clients3.google.com^\047"
            print "- \047@@||clients.l.google.com^\047"
            print "- \047@@||script.google.com^\047"
            print "- \047@@||script.googleusercontent.com^\047"
            print "- \047@@||doc-*-docstext.googleusercontent.com^\047"
            if (rebind_domain != "") {
                print "- \047@@||" rebind_domain "^\047"
            }
            next
        }
        $0 == "@WIREGUARD_BIND_HOST@" {
            print "  - " wireguard_bind_host
            next
        }
        { print }
    ' >"$output_file" <<'EOF'
http:
  address: 192.168.8.1:3000
  session_ttl: 720h
  pprof:
    enabled: false
    port: 6060
  doh:
    insecure_enabled: false
    routes:
    - GET /dns-query
    - POST /dns-query
    - GET /dns-query/{ClientID}
    - POST /dns-query/{ClientID}
users:
@ADGUARD_USER@
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: en
theme: auto
dns:
  bind_hosts:
  - 127.0.0.1
@WIREGUARD_BIND_HOST@
  - 192.168.8.1
  - 192.168.9.1
  - 192.168.10.1
  - 192.168.11.1
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
  - '[/lan/]127.0.0.1:54'
  - https://dns.quad9.net/dns-query
  - https://security.cloudflare-dns.com/dns-query
  - https://freedns.controld.com/p2
  upstream_dns_file: ""
  bootstrap_dns:
  - 9.9.9.11:53
  - 1.1.1.1:53
  - 8.8.8.8:53
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts: []
  trusted_proxies: []
  cache_enabled: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  cache_optimistic_answer_ttl: 30s
  cache_optimistic_max_age: 12h
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    enabled: false
    use_custom: false
    custom_ip: ""
  max_goroutines: 300
  handle_ddr: true
  upstream_timeout: 10s
  private_networks:
  - 127.0.0.0/8
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16
  use_private_ptr_resolvers: true
  local_ptr_upstreams:
  - 127.0.0.1:54
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
  pending_requests:
    enabled: true
filtering:
  protection_enabled: true
  filtering_enabled: true
  filters_update_interval: 24
  blocking_mode: nxdomain
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_response_ttl: 10
  parental_enabled: false
  safebrowsing_enabled: false
  rewrites_enabled: true
  rewrites: []
  safe_fs_patterns: []
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
filters:
- enabled: true
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
  name: AdGuard DNS filter
  id: 1
- enabled: true
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
  name: AdAway Default Blocklist
  id: 2
- enabled: true
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_71.txt
  name: HaGeZi DNS Rebind Protection
  id: 3
- enabled: true
  url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt
  name: HaGeZi - Multi PRO
  id: 4
- enabled: true
  url: https://big.oisd.nl
  name: OISD
  id: 5
- enabled: true
  url: https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
  name: Steven Black
  id: 6
- enabled: true
  url: 'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext'
  name: Peter Lowe
  id: 7
- enabled: true
  url: https://raw.githubusercontent.com/nextdns/native-tracking-domains/refs/heads/main/domains/windows
  name: NextDNS - Windows
  id: 8
- enabled: true
  url: https://raw.githubusercontent.com/nextdns/native-tracking-domains/refs/heads/main/domains/samsung
  name: NextDNS - Samsung
  id: 9
- enabled: true
  url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.samsung.txt
  name: HaGeZi - Samsung native tracking
  id: 10
- enabled: true
  url: https://raw.githubusercontent.com/nextdns/native-tracking-domains/refs/heads/main/domains/apple
  name: NextDNS - Apple
  id: 11
- enabled: true
  url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/doh-vpn-proxy-bypass.txt
  name: HaGeZi - Prevent DNS bypass
  id: 12
- enabled: true
  url: https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV-AGH.txt
  name: Smart TV
  id: 13
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.lgwebos.txt
  name: HaGeZi - LG webOS
  id: 14
- enabled: true
  url: https://perflyst.github.io/PiHoleBlocklist/SmartTV.txt
  name: Smart TV blocklist
  id: 15
- enabled: true
  url: https://blocklistproject.github.io/Lists/smart-tv.txt
  name: Block List Project - Smart TV
  id: 16
- enabled: true
  url: https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/android-tracking.txt
  name: Perflyst - Android tracking
  id: 17
- enabled: true
  url: https://divested.dev/blocklists/LG.txt
  name: Divested - LG
  id: 18
- enabled: true
  url: https://divested.dev/blocklists/Mobile.txt
  name: Divested - Mobile
  id: 19
- enabled: true
  url: https://repository.gameindustry.eu/raw/gaminghosts
  name: GameIndustry - Gaming hosts
  id: 20
- enabled: true
  url: https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_disguised_trackers_justdomains.txt
  name: AdGuard CNAME trackers
  id: 21
- enabled: true
  url: https://hole.cert.pl/domains/v2/domains.txt
  name: CERT Polska
  id: 22
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.apple.txt
  name: HaGeZi - Apple native tracking
  id: 23
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.winoffice.txt
  name: HaGeZi - Windows/Office native tracking
  id: 24
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.tiktok.txt
  name: HaGeZi - TikTok native tracking
  id: 25
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.medium.txt
  name: HaGeZi - Threat Intelligence Feeds
  id: 26
whitelist_filters: []
@USER_RULES@
clients:
  persistent: []
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 0
  port_dns_over_tls: 0
  port_dns_over_quic: 0
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  enabled: true
  file_enabled: true
  interval: 7d
  size_memory: 5000
  ignored: []
  ignored_enabled: false
statistics:
  enabled: true
  interval: 7d
  ignored: []
  ignored_enabled: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 34
log:
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: true
  local_time: false
  verbose: false
EOF
}

adguard_home_stage() {
    candidate_dir=$1
    overlay_file=$2
    apply_overlay "$candidate_dir" "$overlay_file"
    adguard_home_render_config "$candidate_dir/adguardhome.yaml"
    chmod 600 "$candidate_dir/adguardhome.yaml"
}

adguard_home_validate() {
    candidate_dir=$1
    config_file=$candidate_dir/adguardhome.yaml
    [ -s "$config_file" ] || die 'AdGuard Home candidate configuration is empty'
    # shellcheck disable=SC2016
    grep -F '${' "$config_file" >/dev/null 2>&1 &&
        die 'unresolved placeholder in AdGuard Home candidate configuration'
    [ "$(uci_get "$candidate_dir" adguardhome.config)" = adguardhome ] ||
        die 'AdGuard Home UCI candidate lacks its named config section'
    [ "$(uci_get "$candidate_dir" adguardhome.config.config_file)" = /etc/adguardhome/adguardhome.yaml ] ||
        die 'AdGuard Home UCI candidate has an unexpected configuration path'
    [ "$(uci_get "$candidate_dir" adguardhome.config.work_dir)" = /opt/adguardhome ] ||
        die 'AdGuard Home UCI candidate has an unexpected work directory'
    [ "$(uci_get "$candidate_dir" dhcp.dnsmasq.port)" = 54 ] ||
        die 'dnsmasq must listen on port 54'
    [ "$(uci_get "$candidate_dir" dhcp.dnsmasq.noresolv)" = 1 ] ||
        die 'dnsmasq must ignore resolv.conf'
    [ "$(uci_get "$candidate_dir" dhcp.dnsmasq.cachesize)" = 0 ] ||
        die 'dnsmasq cache must be disabled behind AdGuard Home'
    ! uci_get "$candidate_dir" dhcp.dnsmasq.server >/dev/null 2>&1 ||
        die 'dnsmasq must not retain public upstream resolvers'
    for dhcp_section in pixel pixelguest pixeliot pixelthings; do
        gateway=$(uci_get "$candidate_dir" "network.$dhcp_section.ipaddr") ||
            die "missing gateway for $dhcp_section DHCP DNS advertisement"
        dhcp_options=$(uci_get "$candidate_dir" "dhcp.$dhcp_section.dhcp_option") ||
            die "missing DHCP DNS advertisement for $dhcp_section"
        [ "$dhcp_options" = "6,$gateway" ] ||
            die "unexpected DHCP DNS advertisement for $dhcp_section"
    done
    grep -Fxc '  name: AdAway Default Blocklist' "$config_file" >/dev/null ||
        die 'AdAway Default Blocklist is missing from AdGuard Home'
    [ "$(grep -Fxc -- '- enabled: true' "$config_file")" = 26 ] ||
        die 'AdGuard Home must contain exactly 26 enabled filters'
    [ "$(grep -Fxc "  - $ADGUARD_WIREGUARD_BIND_HOST" "$config_file")" = 1 ] ||
        die 'AdGuard Home must bind DNS to the WireGuard server address'
    grep -Fqx '  blocking_mode: nxdomain' "$config_file" ||
        die 'AdGuard Home must return NXDOMAIN for blocked responses'
    [ "$(grep -Fxc '  interval: 7d' "$config_file")" = 2 ] ||
        die 'AdGuard Home query log and statistics retention must both be seven days'
    adguard_binary=${ADGUARDHOME_BIN:-/usr/bin/AdGuardHome}
    "$adguard_binary" --check-config --config "$config_file" --no-check-update >/dev/null 2>&1 ||
        die 'AdGuard Home rejected the candidate configuration'
}
