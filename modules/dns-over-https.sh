#!/bin/sh

# https-dns-proxy package installation and transaction callbacks.

dns_over_https_install() {
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        attempt=$((attempt + 1))
        apk add https-dns-proxy luci-app-https-dns-proxy && break
        [ "$attempt" -lt 5 ] || die 'failed to install https-dns-proxy packages'
        sleep $((attempt * 2))
    done
    https_dns_proxy_init=${ROUTER_CONFIG_HTTPS_DNS_PROXY_INIT:-/etc/init.d/https-dns-proxy}
    "$https_dns_proxy_init" enable
}

dns_over_https_stage() {
    candidate_dir=$1
    overlay_file=$2
    # The package ships two anonymous providers. Start from an empty candidate
    # so neither package defaults nor previously configured instances survive.
    : >"$candidate_dir/https-dns-proxy"
    apply_overlay "$candidate_dir" "$overlay_file"
}

dns_over_https_validate() {
    candidate_dir=$1
    [ "$(uci_get "$candidate_dir" https-dns-proxy.config)" = main ] ||
        die 'https-dns-proxy candidate lacks its named main section'
    [ "$(uci_get "$candidate_dir" https-dns-proxy.config.dnsmasq_config_update)" = - ] ||
        die 'https-dns-proxy must not update dnsmasq outside the transaction'
    [ "$(uci_get "$candidate_dir" https-dns-proxy.config.force_dns)" = 0 ] ||
        die 'https-dns-proxy must not update firewall redirects outside the transaction'
    [ "$(uci_get "$candidate_dir" https-dns-proxy.config.notrack_dns)" = 0 ] ||
        die 'https-dns-proxy must not update firewall tracking outside the transaction'

    proxy_sections=$(uci -q -c "$candidate_dir" show https-dns-proxy |
        sed -n "s/^https-dns-proxy\.\([^=]*\)=https-dns-proxy$/\1/p" |
        sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ "$proxy_sections" = 'cloudflare_security control_d_ads_tracking mullvad_base quad9' ] ||
        die 'https-dns-proxy candidate must contain exactly the four named providers'

    bootstrap='9.9.9.11,1.1.1.1,8.8.8.8'
    expected_forwards=
    for provider_spec in \
        'quad9|https://dns.quad9.net/dns-query|5053' \
        'cloudflare_security|https://security.cloudflare-dns.com/dns-query|5054' \
        'control_d_ads_tracking|https://freedns.controld.com/p2|5055' \
        'mullvad_base|https://base.dns.mullvad.net/dns-query|5056'; do
        provider=${provider_spec%%|*}
        provider_rest=${provider_spec#*|}
        resolver_url=${provider_rest%|*}
        listen_port=${provider_spec##*|}
        [ "$(uci_get "$candidate_dir" "https-dns-proxy.$provider.resolver_url")" = "$resolver_url" ] ||
            die "unexpected https-dns-proxy URL for $provider"
        [ "$(uci_get "$candidate_dir" "https-dns-proxy.$provider.listen_port")" = "$listen_port" ] ||
            die "unexpected https-dns-proxy port for $provider"
        [ "$(uci_get "$candidate_dir" "https-dns-proxy.$provider.bootstrap_dns")" = "$bootstrap" ] ||
            die "unexpected https-dns-proxy bootstrap DNS for $provider"
        expected_forwards="$expected_forwards 127.0.0.1#$listen_port"
    done
    [ "$(uci_get "$candidate_dir" dhcp.dnsmasq.noresolv)" = 1 ] || die 'dnsmasq must ignore resolv.conf'
    [ "$(uci_get "$candidate_dir" dhcp.dnsmasq.cachesize)" = 4096 ] || die 'dnsmasq cache must contain 4096 entries'
    actual_forwards=$(uci_get "$candidate_dir" dhcp.dnsmasq.server) || die 'dnsmasq candidate lacks upstream servers'
    [ " $actual_forwards" = "$expected_forwards" ] ||
        die 'dnsmasq upstreams do not match the four https-dns-proxy instances'
}
