#!/bin/sh

# Internal transaction callback module sourced by router-config.sh.

network_module_preflight() {
    require_type network.loopback interface
    require_type network.globals globals
    require_type network.wan interface
    require_type network.wan6 interface
    require_type network.br_lan device
    [ "$(uci_get "$CONFIG_DIR" network.br_lan.name)" = br-lan ] || die 'network.br_lan is not br-lan'

    for device_name in br-lan lan1 lan2 lan3 lan4; do
        [ -d "$SYS_CLASS_NET/$device_name" ] || die "required DSA interface missing: $device_name"
    done
    bridge_ports=$(uci_get "$CONFIG_DIR" network.br_lan.ports) || die 'network.br_lan has no ports'
    for port_name in lan1 lan2 lan3 lan4; do
        case " $bridge_ports " in
            *" $port_name "*) : ;;
            *) die "network.br_lan is missing port $port_name" ;;
        esac
    done
    for port_name in $bridge_ports; do
        case $port_name in
            lan1 | lan2 | lan3 | lan4) : ;;
            *) die "unexpected network.br_lan port: $port_name" ;;
        esac
    done

    if uci -q -c "$CONFIG_DIR" show network | grep -E "network\.@(interface|bridge-vlan)\[[0-9]+\].*(pixelmain|pixelsecondary|pixelguest|pixeliot|br-lan\.[1-4])" >/dev/null; then
        die 'anonymous project network section found; migrate it to a named section first'
    fi

    canonicalize_dnsmasq "$CONFIG_DIR" check
}

network_module_stage() {
    candidate_dir=$1
    overlay_file=$2
    canonicalize_dnsmasq "$candidate_dir" rewrite
    apply_overlay "$candidate_dir" "$overlay_file"
}

network_module_validate() {
    candidate_dir=$1
    for required_section in loopback globals wan wan6 br_lan; do
        before=$(uci_get "$CONFIG_DIR" "network.$required_section") || die "base section disappeared: network.$required_section"
        after=$(uci_get "$candidate_dir" "network.$required_section") || die "candidate lacks network.$required_section"
        [ "$before" = "$after" ] || die "candidate changed base section type: network.$required_section"
    done
    for section_name in pixelmain pixelsecondary pixelguest pixeliot; do
        [ "$(uci_get "$candidate_dir" "network.$section_name")" = interface ] || die "missing network.$section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name")" = dhcp ] || die "missing dhcp.$section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.ignore")" = 0 ] || die "DHCP is not enabled for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.start")" = 100 ] || die "unexpected DHCP start for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.limit")" = 150 ] || die "unexpected DHCP limit for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.leasetime")" = 12h ] || die "unexpected DHCP lease time for $section_name"
    done
}
