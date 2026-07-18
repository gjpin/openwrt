#!/bin/sh

set -eu

[ "$#" -eq 1 ] && [ "$1" = --recovery-ready ] || {
    printf '%s\n' 'usage: setup.sh --recovery-ready' >&2
    printf '%s\n' 'A verified local Ethernet or serial recovery path is required.' >&2
    exit 2
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

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

validate_repository() {
    for repository_file in \
        router-config.sh router-config-rollback.init \
        uci/network uci/firewall uci/wireless uci/dns-over-https \
        uci/adblock-fast uci/wireguard \
        modules/base-packages.sh modules/network.sh modules/firewall.sh \
        modules/wireless.sh modules/dns-over-https.sh modules/adblock-fast.sh \
        modules/wireguard.sh; do
        [ -f "$SCRIPT_DIR/$repository_file" ] && [ -s "$SCRIPT_DIR/$repository_file" ] ||
            die "repository file is missing or empty: $repository_file"
    done
    [ -x "$SCRIPT_DIR/router-config.sh" ] || die 'router-config.sh is not executable'
}

validate_inputs() {
    for variable_name in \
        PIXEL_WIFI_PASSWORD THINGS_WIFI_PASSWORD GUEST_WIFI_PASSWORD IOT_WIFI_PASSWORD \
        VPN_IF VPN_PORT VPN_KEY VPN_ADDR VPN_PUB VPN_PSK; do
        require_variable "$variable_name"
    done
    for variable_name in PIXEL_WIFI_PASSWORD THINGS_WIFI_PASSWORD GUEST_WIFI_PASSWORD IOT_WIFI_PASSWORD; do
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
    validate_wireguard_key VPN_KEY
    validate_wireguard_key VPN_PUB
    validate_wireguard_key VPN_PSK
}

# Validate the entire public environment contract before the first router
# mutation. Error messages intentionally name variables but never print values.
validate_inputs
validate_repository
export PIXEL_WIFI_PASSWORD THINGS_WIFI_PASSWORD GUEST_WIFI_PASSWORD IOT_WIFI_PASSWORD
export VPN_IF VPN_PORT VPN_KEY VPN_ADDR VPN_PUB VPN_PSK

# Modules are internal sourced files. Their fixed order is part of the setup
# contract and is deliberately not user-selectable.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/modules/base-packages.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/modules/dns-over-https.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/modules/adblock-fast.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/modules/wireguard.sh"

base_packages_run
dns_over_https_install
adblock_fast_install
wireguard_install

prepare_output=$("$SCRIPT_DIR/router-config.sh" prepare --recovery-ready)
printf '%s\n' "$prepare_output"
transaction_id=$(printf '%s\n' "$prepare_output" | sed -n '$p')
[ -n "$transaction_id" ] || die 'router-config did not return a transaction ID'
"$SCRIPT_DIR/router-config.sh" apply "$transaction_id"
