#!/bin/sh

# adblock-fast package installation and transaction callbacks.

adblock_fast_install() {
    apk add adblock-fast luci-app-adblock-fast
    adblock_init=${ROUTER_CONFIG_ADBLOCK_INIT:-/etc/init.d/adblock-fast}
    "$adblock_init" enable
}

adblock_fast_stage() {
    candidate_dir=$1
    overlay_file=$2
    apply_overlay "$candidate_dir" "$overlay_file"
}

adblock_fast_validate() {
    candidate_dir=$1
    [ "$(uci_get "$candidate_dir" adblock-fast.config.enabled)" = 1 ] ||
        die 'adblock-fast candidate is not enabled'
    [ "$(uci_get "$candidate_dir" adblock-fast.config.dns)" = dnsmasq.servers ] ||
        die 'adblock-fast candidate has an unexpected DNS backend'
}
