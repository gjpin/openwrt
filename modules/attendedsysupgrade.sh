#!/bin/sh

# Internal transaction callback module sourced by router-config.sh.
# Enables the LuCI status-page upgrade check.

attendedsysupgrade_preflight() {
    [ -s "$CONFIG_DIR/attendedsysupgrade" ] ||
        die "missing or empty $CONFIG_DIR/attendedsysupgrade"
    uci -q -c "$CONFIG_DIR" show attendedsysupgrade >/dev/null ||
        die 'malformed UCI package: attendedsysupgrade'
    [ "$(uci_get "$CONFIG_DIR" attendedsysupgrade.client)" = client ] ||
        die 'attendedsysupgrade lacks named client section'
}

attendedsysupgrade_stage() {
    candidate_dir=$1
    overlay_file=$2
    [ "$(uci_get "$candidate_dir" attendedsysupgrade.client)" = client ] ||
        die 'attendedsysupgrade candidate lacks named client section'
    apply_overlay "$candidate_dir" "$overlay_file"
}

attendedsysupgrade_validate() {
    candidate_dir=$1
    [ "$(uci_get "$candidate_dir" attendedsysupgrade.client.login_check_for_upgrades)" = 1 ] ||
        die 'attendedsysupgrade login upgrade check must be enabled'
}
