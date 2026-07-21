#!/bin/sh

# WireGuard package installation and transaction callbacks.

wireguard_install() {
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        attempt=$((attempt + 1))
        apk add wireguard-tools luci-proto-wireguard && break
        [ "$attempt" -lt 5 ] || die 'failed to install WireGuard packages'
        sleep $((attempt * 2))
    done
}

wireguard_render_overlay() {
    source_file=$1
    rendered_file=$2
    vpn_client_addr=${VPN_ADDR%.*}.2/32
    sed \
        -e "s|\${VPN_IF}|$VPN_IF|g" \
        -e "s|\${VPN_PORT}|$VPN_PORT|g" \
        -e "s|\${VPN_ADDR}|$VPN_ADDR|g" \
        -e "s|\${VPN_PUB}|$VPN_PUB|g" \
        -e "s|\${VPN_CLIENT_ADDR}|$vpn_client_addr|g" \
        "$source_file" >"$rendered_file" || die 'failed to render WireGuard overlay'
    chmod 600 "$rendered_file"
    # shellcheck disable=SC2016
    grep -F '${' "$rendered_file" >/dev/null 2>&1 && die 'unresolved placeholder in rendered WireGuard overlay'
    return 0
}

wireguard_stage() {
    candidate_dir=$1
    overlay_file=$2
    apply_overlay "$candidate_dir" "$overlay_file"
    uci -q -c "$candidate_dir" set "network.$VPN_IF.private_key=$VPN_KEY" ||
        die 'failed to inject WireGuard private key'
    uci -q -c "$candidate_dir" set "network.wgclient.preshared_key=$VPN_PSK" ||
        die 'failed to inject WireGuard preshared key'
    uci -q -c "$candidate_dir" commit network || die 'failed to serialize WireGuard candidate'
}

wireguard_validate() {
    candidate_dir=$1
    [ "$(uci_get "$candidate_dir" "network.$VPN_IF")" = interface ] || die 'WireGuard interface is missing'
    [ "$(uci_get "$candidate_dir" network.wgclient)" = "wireguard_$VPN_IF" ] || die 'WireGuard peer is missing'
    [ -n "$(uci_get "$candidate_dir" "network.$VPN_IF.private_key")" ] || die 'WireGuard private key is missing'
    [ -n "$(uci_get "$candidate_dir" network.wgclient.preshared_key)" ] || die 'WireGuard preshared key is missing'
}
