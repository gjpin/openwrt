# Internal transaction callback module sourced by router-config.sh.
# Binds uhttpd and Dropbear to the Pixel management VLAN only.

admin_access_dropbear_sections() {
    admin_config_dir=$1
    uci -q -c "$admin_config_dir" show dropbear |
        sed -n "s/^dropbear\.\([^=]*\)=dropbear$/\1/p"
}

admin_access_find_dropbear() {
    admin_config_dir=$1
    ADMIN_DROPBEAR_SECTION=
    admin_dropbear_count=0
    for admin_section in $(admin_access_dropbear_sections "$admin_config_dir"); do
        admin_dropbear_count=$((admin_dropbear_count + 1))
        ADMIN_DROPBEAR_SECTION=$admin_section
    done
    [ "$admin_dropbear_count" = 1 ] || die 'dropbear must contain exactly one instance'
    [ -n "$ADMIN_DROPBEAR_SECTION" ] || die 'dropbear instance section is empty'
}

admin_access_preflight() {
    [ -s "$CONFIG_DIR/uhttpd" ] || die "missing or empty $CONFIG_DIR/uhttpd"
    [ -s "$CONFIG_DIR/dropbear" ] || die "missing or empty $CONFIG_DIR/dropbear"
    uci -q -c "$CONFIG_DIR" show uhttpd >/dev/null || die 'malformed UCI package: uhttpd'
    uci -q -c "$CONFIG_DIR" show dropbear >/dev/null || die 'malformed UCI package: dropbear'
    [ "$(uci_get "$CONFIG_DIR" uhttpd.main)" = uhttpd ] || die 'stock uhttpd lacks named main section'
    admin_access_find_dropbear "$CONFIG_DIR"
}

admin_access_stage() {
    candidate_dir=$1
    overlay_file=$2
    admin_access_find_dropbear "$candidate_dir"
    if [ "$ADMIN_DROPBEAR_SECTION" != main ]; then
        uci -q -c "$candidate_dir" rename "dropbear.$ADMIN_DROPBEAR_SECTION=main" ||
            die 'failed to name the stock dropbear instance'
        uci -q -c "$candidate_dir" commit dropbear || die 'failed to serialize named dropbear candidate'
    fi
    [ "$(uci_get "$candidate_dir" uhttpd.main)" = uhttpd ] || die 'candidate lacks named uhttpd.main'
    apply_overlay "$candidate_dir" "$overlay_file"
}

admin_access_validate() {
    candidate_dir=$1
    [ "$(uci_get "$candidate_dir" network.pixel.ipaddr)" = 192.168.8.1 ] ||
        die 'pixel address must be 192.168.8.1 before binding admin services'
    [ "$(uci_get "$candidate_dir" uhttpd.main)" = uhttpd ] || die 'candidate lacks named uhttpd.main'
    [ "$(uci_get "$candidate_dir" uhttpd.main.listen_http)" = '192.168.8.1:80' ] ||
        die 'uhttpd must listen only on 192.168.8.1:80'
    [ "$(uci_get "$candidate_dir" uhttpd.main.listen_https)" = '192.168.8.1:443' ] ||
        die 'uhttpd must listen only on 192.168.8.1:443'
    [ "$(uci_get "$candidate_dir" uhttpd.main.redirect_https)" = 1 ] ||
        die 'uhttpd must redirect HTTP to HTTPS'

    [ "$(uci_get "$candidate_dir" dropbear.main)" = dropbear ] || die 'candidate lacks named dropbear.main'
    [ "$(uci_get "$candidate_dir" dropbear.main.DirectInterface)" = pixel ] ||
        die 'dropbear must bind DirectInterface to pixel'
    [ "$(uci_get "$candidate_dir" dropbear.main.Port)" = 22 ] || die 'dropbear Port must remain 22'
    [ "$(uci_get "$candidate_dir" dropbear.main.enable)" = 1 ] || die 'dropbear must remain enabled'
    ! uci_get "$candidate_dir" dropbear.main.Interface >/dev/null 2>&1 ||
        die 'dropbear Interface must be cleared when DirectInterface is set'
    admin_access_find_dropbear "$candidate_dir"
    [ "$ADMIN_DROPBEAR_SECTION" = main ] || die 'dropbear candidate must use the named main section'
}
