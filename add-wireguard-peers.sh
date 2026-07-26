#!/bin/sh

# One-off router-side helper. This file is intentionally not part of the
# repository's provisioning transaction.

set -eu
umask 077

: "${VPN_IF:=wgserver}"
: "${VPN_ENDPOINT_HOST:?Set VPN_ENDPOINT_HOST to the public hostname or IPv4 address}"
: "${WG_CLIENT_DIR:=/root/wireguard-clients}"

case $VPN_ENDPOINT_HOST in
    *[!A-Za-z0-9._-]*)
        printf '%s\n' 'VPN_ENDPOINT_HOST must be a hostname or IPv4 address without a port' >&2
        exit 1
        ;;
esac

case $WG_CLIENT_DIR in
    /root/wireguard-clients | /root/wireguard-clients-*)
        ;;
    *)
        printf '%s\n' \
            'WG_CLIENT_DIR must be /root/wireguard-clients or /root/wireguard-clients-*' >&2
        exit 1
        ;;
esac

VPN_PORT=$(uci -q get "network.${VPN_IF}.listen_port") ||
    {
        printf 'Cannot find network.%s.listen_port\n' "$VPN_IF" >&2
        exit 1
    }

VPN_ADDR=$(uci -q get "network.${VPN_IF}.addresses") ||
    {
        printf 'Cannot find network.%s.addresses\n' "$VPN_IF" >&2
        exit 1
    }

case $VPN_ADDR in
    *.*.*.*/24)
        ;;
    *)
        printf 'Expected one README-style IPv4 /24 address; found: %s\n' "$VPN_ADDR" >&2
        exit 1
        ;;
esac

case $VPN_ADDR in
    *' '*)
        printf 'Expected exactly one WireGuard interface address; found: %s\n' "$VPN_ADDR" >&2
        exit 1
        ;;
esac

VPN_PREFIX=${VPN_ADDR%.*}
VPN_SERVER_ADDR=${VPN_ADDR%/*}
VPN_NETWORK="${VPN_PREFIX}.0/24"
CLIENT_ALLOWED_IPS="${VPN_NETWORK},192.168.8.0/24"
SERVER_PUBLIC=$(wg show "$VPN_IF" public-key 2>/dev/null || :)

if [ -z "$SERVER_PUBLIC" ]; then
    server_private=$(uci -q get "network.${VPN_IF}.private_key") ||
        {
            printf 'Cannot obtain the %s server key\n' "$VPN_IF" >&2
            exit 1
        }
    SERVER_PUBLIC=$(printf '%s' "$server_private" | wg pubkey)
    unset server_private
fi

timestamp=$(date +%Y%m%d-%H%M%S)
output_dir=$WG_CLIENT_DIR
backup="/root/network-before-wireguard-peers-${timestamp}"
config_backup="${output_dir}.before-${timestamp}"

[ ! -e "$output_dir" ] || [ -d "$output_dir" ] ||
    {
        printf 'Client configuration path is not a directory: %s\n' "$output_dir" >&2
        exit 1
    }
mkdir -p "$output_dir"
chmod 700 "$output_dir"
mkdir -m 700 "$config_backup"
for existing_config in "$output_dir"/*.conf; do
    [ -f "$existing_config" ] || continue
    cp -p "$existing_config" "$config_backup/"
done
cp -p /etc/config/network "$backup"
chmod 600 "$backup"

rollback() {
    printf 'WireGuard restart failed; restoring %s\n' "$backup" >&2
    cp -p "$backup" /etc/config/network
    ifdown "$VPN_IF" 2>/dev/null || :
    ifup "$VPN_IF" 2>/dev/null || /etc/init.d/network reload || :
    exit 1
}

config_value() {
    field=$1
    file=$2
    awk -v field="$field" '
        $1 == field && $2 == "=" {
            sub(/^[^=]*=[[:space:]]*/, "")
            print
            exit
        }
    ' "$file"
}

expected_public_keys=

add_peer() {
    peer_name=$1
    host_number=$2
    section="wg_${peer_name}"
    peer_address="${VPN_PREFIX}.${host_number}"
    allowed_address="${peer_address}/32"
    config="${output_dir}/${peer_name}.conf"
    config_tmp="${config}.tmp.$$"

    conflicts=$(
        uci -q show network |
            grep -F ".allowed_ips='${allowed_address}'" |
            grep -v "^network.${section}.allowed_ips=" || :
    )
    if [ -n "$conflicts" ]; then
        printf 'Address is already assigned outside network.%s: %s\n' \
            "$section" "$allowed_address" >&2
        exit 1
    fi

    existing_type=$(uci -q get "network.${section}" || :)

    if [ -f "$config" ]; then
        private_key=$(config_value PrivateKey "$config")
        preshared_key=$(config_value PresharedKey "$config")
        existing_address=$(config_value Address "$config")

        [ -n "$private_key" ] && [ -n "$preshared_key" ] ||
            {
                printf 'Existing client configuration is missing keys: %s\n' "$config" >&2
                exit 1
            }
        [ "$existing_address" = "$allowed_address" ] ||
            {
                printf 'Refusing to renumber %s from %s to %s\n' \
                    "$peer_name" "$existing_address" "$allowed_address" >&2
                exit 1
            }
        peer_status=updated
    else
        [ -z "$existing_type" ] ||
            {
                printf 'UCI peer network.%s exists but its private client config is missing.\n' \
                    "$section" >&2
                printf 'Set WG_CLIENT_DIR to the directory containing %s.conf.\n' \
                    "$peer_name" >&2
                exit 1
            }
        private_key=$(wg genkey)
        preshared_key=$(wg genpsk)
        peer_status=created
    fi

    public_key=$(printf '%s' "$private_key" | wg pubkey)

    [ -z "$existing_type" ] || [ "$existing_type" = "wireguard_${VPN_IF}" ] ||
        {
            printf 'network.%s has unexpected type: %s\n' "$section" "$existing_type" >&2
            exit 1
        }

    existing_public=$(uci -q get "network.${section}.public_key" || :)
    [ -z "$existing_public" ] || [ "$existing_public" = "$public_key" ] ||
        {
            printf 'Public-key mismatch for network.%s; refusing to replace it.\n' \
                "$section" >&2
            exit 1
        }

    existing_preshared=$(uci -q get "network.${section}.preshared_key" || :)
    [ -z "$existing_preshared" ] || [ "$existing_preshared" = "$preshared_key" ] ||
        {
            printf 'Preshared-key mismatch for network.%s; refusing to replace it.\n' \
                "$section" >&2
            exit 1
        }

    {
        printf '%s\n' '[Interface]'
        printf 'PrivateKey = %s\n' "$private_key"
        printf 'Address = %s\n' "$allowed_address"
        printf 'DNS = %s\n\n' "$VPN_SERVER_ADDR"
        printf '%s\n' '[Peer]'
        printf 'PublicKey = %s\n' "$SERVER_PUBLIC"
        printf 'PresharedKey = %s\n' "$preshared_key"
        printf 'Endpoint = %s:%s\n' "$VPN_ENDPOINT_HOST" "$VPN_PORT"
        printf 'AllowedIPs = %s\n' "$CLIENT_ALLOWED_IPS"
        printf '%s\n' 'PersistentKeepalive = 25'
    } >"$config_tmp"
    chmod 600 "$config_tmp"
    mv "$config_tmp" "$config"

    uci -q delete "network.${section}" 2>/dev/null || :
    uci set "network.${section}=wireguard_${VPN_IF}"
    uci set "network.${section}.description=${peer_name}"
    uci set "network.${section}.public_key=${public_key}"
    uci set "network.${section}.preshared_key=${preshared_key}"
    uci add_list "network.${section}.allowed_ips=${allowed_address}"

    expected_public_keys="${expected_public_keys} ${public_key}"
    printf '%-12s %s\n' "$peer_name" "$peer_status"
    unset private_key public_key preshared_key
}

# TODO:
# Add your peers here
# format: add_peer hostname address
# eg. add_peer macbook 2

uci commit network
ifdown "$VPN_IF" || rollback
ifup "$VPN_IF" || rollback

attempt=0
all_peers_loaded=0
while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    live_public_keys=$(wg show "$VPN_IF" peers 2>/dev/null || :)
    all_peers_loaded=1
    for expected_public_key in $expected_public_keys; do
        printf '%s\n' "$live_public_keys" |
            grep -Fx "$expected_public_key" >/dev/null 2>&1 ||
            {
                all_peers_loaded=0
                break
            }
    done
    [ "$all_peers_loaded" -eq 0 ] || break
    sleep 1
done
[ "$all_peers_loaded" -eq 1 ] ||
    {
        printf '%s\n' 'WireGuard did not load every configured peer.' >&2
        rollback
    }

if command -v fw4 >/dev/null 2>&1; then
    fw4 check || rollback
fi

printf '\nInstalled WireGuard peers:\n'
wg show "$VPN_IF" | sed -n '/^peer:/p'

printf '\nClient configurations:\n  %s\n' "$output_dir"
printf 'Previous client configurations:\n  %s\n' "$config_backup"
printf 'Network backup:\n  %s\n' "$backup"
printf '\nReuse this directory on every run:\n  export WG_CLIENT_DIR=%s\n' "$output_dir"
printf '%s\n' 'Keep its secret client files available if this script will be run again.'
