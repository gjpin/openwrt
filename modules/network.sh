#!/bin/sh

# Internal transaction callback module sourced by router-config.sh.

network_check_allowed_options() {
    network_config_dir=$1
    network_package=$2
    network_section=$3
    network_allowed=$4
    network_options=$(uci -q -c "$network_config_dir" show "$network_package" |
        awk -v prefix="$network_package.$network_section." '
            index($0, prefix) == 1 {
                option = substr($0, length(prefix) + 1)
                sub(/=.*/, "", option)
                print option
            }
        ' | sort -u)
    for network_option in $network_options; do
        case " $network_allowed " in
            *" $network_option "*) : ;;
            *) die "custom option on stock $network_package.$network_section: $network_option" ;;
        esac
    done
}

network_find_br_lan() {
    network_config_dir=$1
    NETWORK_BR_LAN_SECTION=
    network_br_lan_count=0
    network_device_sections=$(uci -q -c "$network_config_dir" show network |
        sed -n "s/^network\.\([^=]*\)=device$/\1/p")
    for network_device_section in $network_device_sections; do
        network_device_name=$(uci_get "$network_config_dir" "network.$network_device_section.name" 2>/dev/null || :)
        [ "$network_device_name" = br-lan ] || continue
        network_br_lan_count=$((network_br_lan_count + 1))
        NETWORK_BR_LAN_SECTION=$network_device_section
    done
    [ "$network_br_lan_count" = 1 ] || die 'network must contain exactly one br-lan device'
    [ "$(uci_get "$network_config_dir" "network.$NETWORK_BR_LAN_SECTION.type")" = bridge ] ||
        die 'network br-lan device is not a bridge'
}

network_module_preflight() {
    require_type network.loopback interface
    require_type network.globals globals
    require_type network.wan interface
    network_find_br_lan "$CONFIG_DIR"

    for device_name in br-lan lan1 lan2 lan3 lan4 lan5; do
        [ -d "$SYS_CLASS_NET/$device_name" ] || die "required DSA interface missing: $device_name"
    done
    bridge_ports=$(uci_get "$CONFIG_DIR" "network.$NETWORK_BR_LAN_SECTION.ports") || die 'network br-lan has no ports'
    for port_name in lan1 lan2 lan3 lan4 lan5; do
        case " $bridge_ports " in
            *" $port_name "*) : ;;
            *) die "network.br_lan is missing port $port_name" ;;
        esac
    done
    for port_name in $bridge_ports; do
        case $port_name in
            lan1 | lan2 | lan3 | lan4 | lan5) : ;;
            *) die "unexpected network.br_lan port: $port_name" ;;
        esac
    done

    # A fresh upstream GL-MT6000 has a conventional lan interface and DHCP
    # pool.  Accept only that known shape; customized base LANs need an
    # operator-reviewed migration rather than an automatic destructive guess.
    if uci_get "$CONFIG_DIR" network.lan >/dev/null 2>&1; then
        require_type network.lan interface
        network_check_allowed_options "$CONFIG_DIR" network lan 'device proto ipaddr netmask ip6assign'
        [ "$(uci_get "$CONFIG_DIR" network.lan.device)" = br-lan ] ||
            die 'stock network.lan does not use br-lan'
        [ "$(uci_get "$CONFIG_DIR" network.lan.proto)" = static ] ||
            die 'stock network.lan is not static'
        network_lan_ipaddr=$(uci_get "$CONFIG_DIR" network.lan.ipaddr) ||
            die 'stock network.lan has no address'
        case $network_lan_ipaddr in
            192.168.1.1/24)
                ! uci_get "$CONFIG_DIR" network.lan.netmask >/dev/null 2>&1 ||
                    die 'stock network.lan mixes CIDR and netmask forms'
                ;;
            192.168.1.1)
                [ "$(uci_get "$CONFIG_DIR" network.lan.netmask)" = 255.255.255.0 ] ||
                    die 'stock network.lan has a customized netmask'
                ;;
            *) die 'stock network.lan has a customized address' ;;
        esac
        network_lan_ip6assign=$(uci_get "$CONFIG_DIR" network.lan.ip6assign 2>/dev/null || :)
        [ -z "$network_lan_ip6assign" ] || [ "$network_lan_ip6assign" = 60 ] ||
            die 'stock network.lan has a customized IPv6 assignment'
        [ "$(uci_get "$CONFIG_DIR" dhcp.lan)" = dhcp ] ||
            die 'stock dhcp.lan section is missing'
        network_check_allowed_options "$CONFIG_DIR" dhcp lan 'interface start limit leasetime'
        [ "$(uci_get "$CONFIG_DIR" dhcp.lan.interface)" = lan ] ||
            die 'stock dhcp.lan targets an unexpected interface'
        [ "$(uci_get "$CONFIG_DIR" dhcp.lan.start)" = 100 ] ||
            die 'stock dhcp.lan has a customized start address'
        [ "$(uci_get "$CONFIG_DIR" dhcp.lan.limit)" = 150 ] ||
            die 'stock dhcp.lan has a customized pool size'
        [ "$(uci_get "$CONFIG_DIR" dhcp.lan.leasetime)" = 12h ] ||
            die 'stock dhcp.lan has a customized lease time'
    elif uci_get "$CONFIG_DIR" dhcp.lan >/dev/null 2>&1; then
        die 'dhcp.lan exists without network.lan'
    fi

    if uci_get "$CONFIG_DIR" network.wan6 >/dev/null 2>&1; then
        network_check_allowed_options "$CONFIG_DIR" network wan6 'device proto'
        [ "$(uci_get "$CONFIG_DIR" network.wan6.proto)" = dhcpv6 ] ||
            die 'stock network.wan6 has a customized protocol'
        network_wan6_device=$(uci_get "$CONFIG_DIR" network.wan6.device) ||
            die 'stock network.wan6 has no device'
        case $network_wan6_device in
            @wan | "$(uci_get "$CONFIG_DIR" network.wan.device)") : ;;
            *) die 'stock network.wan6 has a customized device' ;;
        esac
    fi

    if uci -q -c "$CONFIG_DIR" show network | grep -E "network\.@(interface|bridge-vlan)\[[0-9]+\].*(pixel|pixelthings|pixelguest|pixeliot|br-lan\.[1-4])" >/dev/null; then
        die 'anonymous project network section found; migrate it to a named section first'
    fi

    canonicalize_dnsmasq "$CONFIG_DIR" check
}

network_module_stage() {
    candidate_dir=$1
    overlay_file=$2
    canonicalize_dnsmasq "$candidate_dir" rewrite
    network_find_br_lan "$candidate_dir"
    if [ "$NETWORK_BR_LAN_SECTION" != br_lan ]; then
        uci -q -c "$candidate_dir" rename "network.$NETWORK_BR_LAN_SECTION=br_lan" ||
            die 'failed to name the stock br-lan device'
        uci -q -c "$candidate_dir" commit network || die 'failed to serialize named br-lan candidate'
    fi
    apply_overlay "$candidate_dir" "$overlay_file"
}

network_module_validate() {
    candidate_dir=$1
    for required_section in loopback globals wan; do
        before=$(uci_get "$CONFIG_DIR" "network.$required_section") || die "base section disappeared: network.$required_section"
        after=$(uci_get "$candidate_dir" "network.$required_section") || die "candidate lacks network.$required_section"
        [ "$before" = "$after" ] || die "candidate changed base section type: network.$required_section"
    done
    [ "$(uci_get "$candidate_dir" network.br_lan)" = device ] || die 'candidate lacks named br-lan device'
    [ "$(uci_get "$candidate_dir" network.br_lan.name)" = br-lan ] || die 'candidate br-lan has an unexpected name'
    ! uci_get "$candidate_dir" network.wan6 >/dev/null 2>&1 || die 'IPv6 WAN interface is still configured'
    ! uci_get "$candidate_dir" network.lan >/dev/null 2>&1 || die 'obsolete LAN interface is still configured'
    ! uci_get "$candidate_dir" dhcp.lan >/dev/null 2>&1 || die 'obsolete LAN DHCP pool is still configured'
    ! uci_get "$candidate_dir" network.globals.ula_prefix >/dev/null 2>&1 || die 'IPv6 ULA prefix is still configured'
    [ "$(uci_get "$candidate_dir" network.wan.proto)" = static ] || die 'WAN must use a static address'
    [ "$(uci_get "$candidate_dir" network.wan.ipaddr)" = 192.168.1.2 ] || die 'WAN address must be 192.168.1.2'
    [ "$(uci_get "$candidate_dir" network.wan.netmask)" = 255.255.255.0 ] || die 'WAN netmask must be 255.255.255.0'
    [ "$(uci_get "$candidate_dir" network.wan.gateway)" = 192.168.1.1 ] || die 'WAN gateway must be 192.168.1.1'
    [ "$(uci_get "$candidate_dir" network.wan.ipv6)" = 0 ] || die 'IPv6 is not disabled on WAN'
    for section_name in pixel pixelthings pixelguest pixeliot; do
        [ "$(uci_get "$candidate_dir" "network.$section_name")" = interface ] || die "missing network.$section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name")" = dhcp ] || die "missing dhcp.$section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.ignore")" = 0 ] || die "DHCP is not enabled for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.start")" = 100 ] || die "unexpected DHCP start for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.limit")" = 150 ] || die "unexpected DHCP limit for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.leasetime")" = 12h ] || die "unexpected DHCP lease time for $section_name"
        [ "$(uci_get "$candidate_dir" "network.$section_name.delegate")" = 0 ] || die "IPv6 delegation is not disabled for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.ra")" = disabled ] || die "IPv6 router advertisements are not disabled for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.dhcpv6")" = disabled ] || die "DHCPv6 is not disabled for $section_name"
        [ "$(uci_get "$candidate_dir" "dhcp.$section_name.ndp")" = disabled ] || die "NDP proxying is not disabled for $section_name"
        [ "$(uci_get "$candidate_dir" "network.$section_name.netmask")" = 255.255.255.0 ] ||
            die "unexpected netmask for $section_name"
    done
    [ "$(uci_get "$candidate_dir" network.pixel.ipaddr)" = 192.168.8.1 ] || die 'pixel address must be 192.168.8.1'
    [ "$(uci_get "$candidate_dir" network.pixelguest.ipaddr)" = 192.168.9.1 ] ||
        die 'pixelguest address must be 192.168.9.1'
    [ "$(uci_get "$candidate_dir" network.pixeliot.ipaddr)" = 192.168.10.1 ] ||
        die 'pixeliot address must be 192.168.10.1'
    [ "$(uci_get "$candidate_dir" network.pixelthings.ipaddr)" = 192.168.11.1 ] ||
        die 'pixelthings address must be 192.168.11.1'
}
