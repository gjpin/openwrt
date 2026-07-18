#!/bin/sh

set -eu

[ "$#" -eq 1 ] && [ "$1" = --recovery-ready ] || {
    printf '%s\n' 'usage: setup.sh --recovery-ready' >&2
    printf '%s\n' 'A verified local Ethernet or serial recovery path is required.' >&2
    exit 2
}

# Publish the bundle as an immutable GitHub release asset, then replace both
# values together. Deployment is refused while either placeholder remains.
ROUTER_CONFIG_BUNDLE_VERSION='REPLACE_WITH_IMMUTABLE_VERSION'
ROUTER_CONFIG_BUNDLE_SHA256='REPLACE_WITH_64_CHARACTER_SHA256'
ROUTER_CONFIG_BUNDLE_URL="https://github.com/gjpin/openwrt/releases/download/${ROUTER_CONFIG_BUNDLE_VERSION}/router-config-bundle.tar.gz"

die() {
    printf 'setup: %s\n' "$*" >&2
    exit 1
}

require_variable() {
    variable_name=$1
    eval "variable_value=\${$variable_name-}"
    [ -n "$variable_value" ] || die "required variable is empty: $variable_name"
}

validate_wifi_password() {
    variable_name=$1
    password_value=
    eval "password_value=\${$variable_name-}"
    password_length=${#password_value}
    [ "$password_length" -ge 8 ] && [ "$password_length" -le 63 ] ||
        die "$variable_name must contain 8 to 63 characters"
    case $password_value in
        *[!\ -~]*) die "$variable_name contains a non-printable character" ;;
    esac
}

validate_wireguard_key() {
    variable_name=$1
    key_value=
    eval "key_value=\${$variable_name-}"
    [ "${#key_value}" -eq 44 ] || die "$variable_name must be a 44-character WireGuard key"
    case $key_value in
        *[!A-Za-z0-9+/=]*) die "$variable_name is not a valid base64 WireGuard key" ;;
        *=) : ;;
        *) die "$variable_name is not a padded WireGuard key" ;;
    esac
}

validate_inputs() {
    for variable_name in \
        MAIN_WIFI_PASSWORD SECONDARY_WIFI_PASSWORD GUEST_WIFI_PASSWORD IOT_WIFI_PASSWORD \
        VPN_IF VPN_PORT VPN_KEY VPN_ADDR VPN_ADDR6 VPN_PUB VPN_PSK; do
        require_variable "$variable_name"
    done
    for variable_name in MAIN_WIFI_PASSWORD SECONDARY_WIFI_PASSWORD GUEST_WIFI_PASSWORD IOT_WIFI_PASSWORD; do
        validate_wifi_password "$variable_name"
    done
    case $VPN_IF in
        [A-Za-z_]*) ;;
        *) die 'VPN_IF must begin with a letter or underscore' ;;
    esac
    case $VPN_IF in
        *[!A-Za-z0-9_]*) die 'VPN_IF must be a safe UCI section name containing only letters, digits, and underscores' ;;
    esac
    [ "${#VPN_IF}" -le 15 ] || die 'VPN_IF must fit the Linux interface-name limit of 15 characters'
    case $VPN_PORT in
        '' | *[!0-9]*) die 'VPN_PORT must be an integer from 1 through 65535' ;;
    esac
    [ "$VPN_PORT" -ge 1 ] 2>/dev/null && [ "$VPN_PORT" -le 65535 ] 2>/dev/null ||
        die 'VPN_PORT must be an integer from 1 through 65535'
    case $VPN_ADDR in
        *.*.*.*/*) : ;;
        *) die 'VPN_ADDR must be an IPv4 CIDR address' ;;
    esac
    case $VPN_ADDR in
        *[!0-9./]*) die 'VPN_ADDR must contain only an IPv4 address and prefix length' ;;
    esac
    case $VPN_ADDR6 in
        *:/* | *:*/*) : ;;
        *) die 'VPN_ADDR6 must be an IPv6 CIDR address' ;;
    esac
    case $VPN_ADDR6 in
        *[!0-9A-Fa-f:./]*) die 'VPN_ADDR6 must contain only an IPv6 address and prefix length' ;;
    esac
    validate_wireguard_key VPN_KEY
    validate_wireguard_key VPN_PUB
    validate_wireguard_key VPN_PSK

    case $ROUTER_CONFIG_BUNDLE_VERSION in
        REPLACE_*) die 'publish an immutable router-config bundle and set its version first' ;;
    esac
    case $ROUTER_CONFIG_BUNDLE_SHA256 in
        *[!0-9a-f]* | '') die 'bundle SHA-256 must be 64 lowercase hexadecimal characters' ;;
    esac
    [ "${#ROUTER_CONFIG_BUNDLE_SHA256}" -eq 64 ] || die 'bundle SHA-256 must contain exactly 64 characters'
}

# Validate the entire public environment contract before the first router
# mutation. Error messages intentionally name variables but never print values.
validate_inputs
export MAIN_WIFI_PASSWORD SECONDARY_WIFI_PASSWORD GUEST_WIFI_PASSWORD IOT_WIFI_PASSWORD

bundle_archive=$(mktemp /tmp/router-config-bundle.XXXXXX.tar.gz)
bundle_directory=$(mktemp -d /tmp/router-config-bundle.XXXXXX)
cleanup() {
    rm -f "$bundle_archive"
    rm -rf "$bundle_directory"
}
trap 'cleanup' EXIT HUP INT TERM

uclient-fetch "$ROUTER_CONFIG_BUNDLE_URL" -O "$bundle_archive"
[ -s "$bundle_archive" ] || die 'router-config bundle download is empty'
printf '%s  %s\n' "$ROUTER_CONFIG_BUNDLE_SHA256" "$bundle_archive" | sha256sum -c -
tar -xzf "$bundle_archive" -C "$bundle_directory"
for bundle_file in \
    router-config.sh router-config-rollback.init \
    configs/openwrt/network configs/openwrt/firewall configs/openwrt/wireless \
    configs/dnscrypt/dnscrypt-proxy.toml \
    modules/base-packages.sh modules/network.sh modules/firewall.sh \
    modules/wireless.sh modules/dns-over-https.sh modules/adblock-fast.sh \
    modules/wireguard.sh; do
    [ -f "$bundle_directory/$bundle_file" ] && [ -s "$bundle_directory/$bundle_file" ] ||
        die "bundle member is missing or empty: $bundle_file"
done
chmod 700 "$bundle_directory/router-config.sh"

# Modules are internal sourced files. Their fixed order is part of the setup
# contract and is deliberately not user-selectable.
. "$bundle_directory/modules/base-packages.sh"
. "$bundle_directory/modules/dns-over-https.sh"
. "$bundle_directory/modules/adblock-fast.sh"
. "$bundle_directory/modules/wireguard.sh"

base_packages_run

prepare_output=$("$bundle_directory/router-config.sh" prepare --recovery-ready)
printf '%s\n' "$prepare_output"
transaction_id=$(printf '%s\n' "$prepare_output" | sed -n '$p')
[ -n "$transaction_id" ] || die 'router-config did not return a transaction ID'
"$bundle_directory/router-config.sh" apply "$transaction_id"

dns_over_https_run "$bundle_directory"
adblock_fast_run
wireguard_run
