#!/bin/sh

# Internal transaction callback module sourced by router-config.sh.

firewall_module_preflight() {
    defaults_type=$(uci_get "$CONFIG_DIR" 'firewall.@defaults[0]') || die 'firewall defaults section missing'
    [ "$defaults_type" = defaults ] || die 'firewall defaults section has unexpected type'
    uci -q -c "$CONFIG_DIR" show firewall | grep -Eq "\.name='?wan'?\$" || die 'firewall WAN zone missing'
    if uci -q -c "$CONFIG_DIR" show firewall | grep -E "firewall\.@(zone|forwarding|rule)\[[0-9]+\].*(pixel|pixelthings|pixelguest|pixeliot)" >/dev/null; then
        die 'anonymous project firewall section found; migrate it to a named section first'
    fi
}

firewall_module_stage() {
    candidate_dir=$1
    overlay_file=$2
    apply_overlay "$candidate_dir" "$overlay_file"
}

firewall_module_validate() {
    candidate_dir=$1
    [ "$(uci_get "$candidate_dir" 'firewall.@defaults[0]')" = defaults ] || die 'candidate lacks firewall defaults'
    uci -q -c "$candidate_dir" show firewall | grep -Eq "\.name='?wan'?\$" || die 'candidate lacks firewall WAN zone'
    for section_name in pixel pixelthings pixelguest pixeliot; do
        [ "$(uci_get "$candidate_dir" "firewall.$section_name")" = zone ] || die "missing firewall.$section_name"
    done
    UCI_CONFIG_DIR="$candidate_dir" fw4 check >/dev/null 2>&1 || die 'fw4 rejected candidate configuration'
}
