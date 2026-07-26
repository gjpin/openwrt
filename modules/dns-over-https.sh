#!/bin/sh

# https-dns-proxy package installation and transaction callbacks.

dns_over_https_preflight() {
    DNS_REBIND_DOMAIN=${DNS_REBIND_DOMAIN:-}
    [ -n "$DNS_REBIND_DOMAIN" ] || {
        export DNS_REBIND_DOMAIN
        return 0
    }

    DNS_REBIND_DOMAIN=$(
        # The public contract is deliberately ASCII-only; explicit alphabets
        # also work with BusyBox tr implementations lacking class expansion.
        # shellcheck disable=SC2018,SC2019
        printf '%s' "$DNS_REBIND_DOMAIN" |
            tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
    )
    domain_length=${#DNS_REBIND_DOMAIN}
    [ "$domain_length" -le 253 ] ||
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
    export DNS_REBIND_DOMAIN
}

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
    if [ -n "${DNS_REBIND_DOMAIN:-}" ]; then
        uci -q -c "$candidate_dir" del_list \
            "dhcp.dnsmasq.rebind_domain=$DNS_REBIND_DOMAIN" 2>/dev/null || :
        uci -q -c "$candidate_dir" add_list \
            "dhcp.dnsmasq.rebind_domain=$DNS_REBIND_DOMAIN" ||
            die 'failed to add DNS_REBIND_DOMAIN to the dnsmasq candidate'
        uci -q -c "$candidate_dir" commit dhcp ||
            die 'failed to serialize dhcp candidate'
    fi
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
    [ "$(uci_get "$candidate_dir" dhcp.dnsmasq.cachesize)" = 8192 ] || die 'dnsmasq cache must contain 8192 entries'
    [ "$(uci_get "$candidate_dir" dhcp.dnsmasq.rebind_protection)" = 1 ] ||
        die 'dnsmasq rebind protection must remain enabled'
    if [ -n "${DNS_REBIND_DOMAIN:-}" ]; then
        rebind_domains=$(uci_get "$candidate_dir" dhcp.dnsmasq.rebind_domain || :)
        rebind_domain_count=$(
            printf '%s\n' "$rebind_domains" |
                awk -v expected="$DNS_REBIND_DOMAIN" '
                    {
                        for (field = 1; field <= NF; field++)
                            if ($field == expected)
                                count++
                    }
                    END { print count + 0 }
                '
        )
        [ "$rebind_domain_count" = 1 ] ||
            die 'DNS_REBIND_DOMAIN must appear exactly once in the dnsmasq candidate'
    fi
    actual_forwards=$(uci_get "$candidate_dir" dhcp.dnsmasq.server) || die 'dnsmasq candidate lacks upstream servers'
    [ " $actual_forwards" = "$expected_forwards" ] ||
        die 'dnsmasq upstreams do not match the four https-dns-proxy instances'
}
