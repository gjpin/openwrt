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

    adblock_fast_show=$(uci -q -c "$candidate_dir" show adblock-fast) ||
        die 'failed to inspect adblock-fast candidate sources'
    printf '%s\n' "$adblock_fast_show" |
        sed -n \
            -e "s/^adblock-fast\.\([^.=]*\)='file_url'$/\1/p" \
            -e "s/^adblock-fast\.\([^.=]*\)=file_url$/\1/p" |
        awk '{ section[NR] = $0 } END { for (i = NR; i > 0; i--) print section[i] }' |
        while IFS= read -r section_name; do
            uci -q -c "$candidate_dir" delete "adblock-fast.$section_name" ||
                die "failed to remove adblock-fast source: $section_name"
        done || die 'failed to remove existing adblock-fast sources'

    apply_overlay "$candidate_dir" "$overlay_file"
}

adblock_fast_validate() {
    candidate_dir=$1
    [ "$(uci_get "$candidate_dir" adblock-fast.config.enabled)" = 1 ] ||
        die 'adblock-fast candidate is not enabled'
    [ "$(uci_get "$candidate_dir" adblock-fast.config.dns)" = dnsmasq.servers ] ||
        die 'adblock-fast candidate has an unexpected DNS backend'
    file_url_count=$(uci -q -c "$candidate_dir" show adblock-fast |
        grep -Ec "=('file_url'|file_url)\$") || :
    [ "$file_url_count" = 19 ] ||
        die 'adblock-fast candidate must contain exactly 19 sources'
    for section_name in \
        hagezi_multi_pro oisd steven_black peter_lowe \
        nextdns_windows nextdns_samsung nextdns_apple easylist \
        hagezi_dns_bypass smart_tv_agh hagezi_lg_webos smart_tv \
        perflyst_android divested_lg divested_mobile gameindustry_gaming \
        adguard_cname_trackers cert_polska adguard; do
        [ "$(uci_get "$candidate_dir" "adblock-fast.$section_name")" = file_url ] ||
            die "missing adblock-fast source: $section_name"
        [ "$(uci_get "$candidate_dir" "adblock-fast.$section_name.action")" = block ] ||
            die "adblock-fast source is not a blocklist: $section_name"
        [ "$(uci_get "$candidate_dir" "adblock-fast.$section_name.enabled")" = 1 ] ||
            die "adblock-fast source is not enabled: $section_name"
    done
}
