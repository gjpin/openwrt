#!/bin/sh

# DNSCrypt package installation and transaction callbacks.

dns_over_https_install() {
    apk add dnscrypt-proxy2
    dnscrypt_init=${ROUTER_CONFIG_DNSCRYPT_INIT:-/etc/init.d/dnscrypt-proxy}
    "$dnscrypt_init" enable
}

dns_over_https_stage() {
    candidate_dir=$1
    overlay_file=$2
    dnscrypt_candidate=$3
    apply_overlay "$candidate_dir" "$overlay_file"
    dnscrypt-proxy -check -config "$dnscrypt_candidate" >/dev/null ||
        die 'DNSCrypt rejected candidate configuration'
}

dns_over_https_validate() {
    candidate_dir=$1
    dnscrypt_candidate=$2
    dnscrypt_endpoint=$(awk '
        /^[[:space:]]*\[/ { exit }
        /^[[:space:]]*listen_addresses[[:space:]]*=/ {
            line = $0
            sub(/^[^=]*=[[:space:]]*\[[[:space:]]*["\047]/, "", line)
            sub(/["\047][[:space:]]*\].*$/, "", line)
            print line
            exit
        }
    ' "$dnscrypt_candidate")
    [ -n "$dnscrypt_endpoint" ] || die 'DNSCrypt candidate lacks a top-level listen_addresses endpoint'
    dnsmasq_endpoint=$(uci_get "$candidate_dir" dhcp.dnsmasq.server) ||
        die 'dnsmasq candidate lacks an upstream server'
    case " $dnsmasq_endpoint " in
        *" ${dnscrypt_endpoint%:*}#${dnscrypt_endpoint##*:} "*) : ;;
        *) die 'DNSCrypt listen_addresses does not match dnsmasq upstream' ;;
    esac
}
