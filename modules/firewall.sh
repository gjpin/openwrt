#!/bin/sh

# Internal transaction callback module sourced by router-config.sh.

firewall_sections_of_type() {
    firewall_config_dir=$1
    firewall_section_type=$2
    uci -q -c "$firewall_config_dir" show firewall |
        sed -n "s/^firewall\.\([^=]*\)=${firewall_section_type}$/\1/p"
}

firewall_check_allowed_options() {
    firewall_config_dir=$1
    firewall_section=$2
    firewall_allowed=$3
    firewall_options=$(uci -q -c "$firewall_config_dir" show firewall |
        awk -v prefix="firewall.$firewall_section." '
            index($0, prefix) == 1 {
                option = substr($0, length(prefix) + 1)
                sub(/=.*/, "", option)
                print option
            }
        ' | sort -u)
    for firewall_option in $firewall_options; do
        case " $firewall_allowed " in
            *" $firewall_option "*) : ;;
            *) die "custom option on stock firewall.$firewall_section: $firewall_option" ;;
        esac
    done
}

firewall_classify_base() {
    firewall_config_dir=$1
    FIREWALL_DEFAULTS_SECTION=
    FIREWALL_LAN_SECTION=
    FIREWALL_WAN_SECTION=
    FIREWALL_LAN_WAN_SECTION=
    firewall_defaults_count=0
    firewall_lan_count=0
    firewall_wan_count=0
    firewall_lan_wan_count=0

    for firewall_section in $(firewall_sections_of_type "$firewall_config_dir" defaults); do
        firewall_defaults_count=$((firewall_defaults_count + 1))
        FIREWALL_DEFAULTS_SECTION=$firewall_section
    done
    [ "$firewall_defaults_count" = 1 ] || die 'firewall must contain exactly one defaults section'
    firewall_check_allowed_options "$firewall_config_dir" "$FIREWALL_DEFAULTS_SECTION" \
        'syn_flood input output forward flow_offloading flow_offloading_hw'
    [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_DEFAULTS_SECTION.syn_flood")" = 1 ] ||
        die 'stock firewall defaults lack synflood protection'
    [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_DEFAULTS_SECTION.input")" = REJECT ] ||
        die 'stock firewall defaults input policy was customized'
    [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_DEFAULTS_SECTION.output")" = ACCEPT ] ||
        die 'stock firewall defaults output policy was customized'
    [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_DEFAULTS_SECTION.forward")" = REJECT ] ||
        die 'stock firewall defaults forward policy was customized'

    for firewall_section in $(firewall_sections_of_type "$firewall_config_dir" zone); do
        firewall_zone_name=$(uci_get "$firewall_config_dir" "firewall.$firewall_section.name" 2>/dev/null || :)
        case $firewall_zone_name in
            lan)
                firewall_lan_count=$((firewall_lan_count + 1))
                FIREWALL_LAN_SECTION=$firewall_section
                ;;
            wan)
                firewall_wan_count=$((firewall_wan_count + 1))
                FIREWALL_WAN_SECTION=$firewall_section
                ;;
        esac
    done
    [ "$firewall_lan_count" -le 1 ] || die 'multiple firewall LAN zones found'
    [ "$firewall_wan_count" = 1 ] || die 'firewall must contain exactly one WAN zone'

    firewall_check_allowed_options "$firewall_config_dir" "$FIREWALL_WAN_SECTION" \
        'name network input output forward masq mtu_fix'
    [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_WAN_SECTION.input")" = REJECT ] ||
        die 'stock firewall WAN input policy was customized'
    [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_WAN_SECTION.output")" = ACCEPT ] ||
        die 'stock firewall WAN output policy was customized'
    [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_WAN_SECTION.forward")" = DROP ] ||
        die 'stock firewall WAN forward policy was customized'
    firewall_wan_network=$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_WAN_SECTION.network") ||
        die 'firewall WAN zone has no network membership'
    case " $firewall_wan_network " in
        ' wan ' | ' wan wan6 ' | ' wan6 wan ') : ;;
        *) die 'firewall WAN zone has customized network membership' ;;
    esac

    if [ "$firewall_lan_count" = 1 ]; then
        firewall_check_allowed_options "$firewall_config_dir" "$FIREWALL_LAN_SECTION" \
            'name network input output forward'
        [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_LAN_SECTION.network")" = lan ] ||
            die 'stock firewall LAN zone has customized network membership'
        for firewall_policy in input output forward; do
            [ "$(uci_get "$firewall_config_dir" "firewall.$FIREWALL_LAN_SECTION.$firewall_policy")" = ACCEPT ] ||
                die "stock firewall LAN $firewall_policy policy was customized"
        done
    fi

    for firewall_section in $(firewall_sections_of_type "$firewall_config_dir" forwarding); do
        firewall_src=$(uci_get "$firewall_config_dir" "firewall.$firewall_section.src" 2>/dev/null || :)
        firewall_dest=$(uci_get "$firewall_config_dir" "firewall.$firewall_section.dest" 2>/dev/null || :)
        if [ "$firewall_src" = lan ] && [ "$firewall_dest" = wan ]; then
            firewall_lan_wan_count=$((firewall_lan_wan_count + 1))
            # shellcheck disable=SC2034 # Read through firewall_rename_role's role indirection.
            FIREWALL_LAN_WAN_SECTION=$firewall_section
            firewall_check_allowed_options "$firewall_config_dir" "$firewall_section" 'src dest'
        fi
    done
    [ "$firewall_lan_wan_count" -le 1 ] || die 'multiple LAN to WAN forwardings found'

    [ "$firewall_lan_count" = "$firewall_lan_wan_count" ] ||
        die 'stock LAN zone and LAN to WAN forwarding must either both exist or both be absent'
}

firewall_rename_role() {
    firewall_config_dir=$1
    firewall_role=$2
    firewall_target=$3
    firewall_classify_base "$firewall_config_dir"
    eval "firewall_source=\${FIREWALL_${firewall_role}_SECTION}"
    [ -n "$firewall_source" ] || return 0
    [ "$firewall_source" = "$firewall_target" ] && return 0
    uci -q -c "$firewall_config_dir" rename "firewall.$firewall_source=$firewall_target" ||
        die "failed to name stock firewall section: $firewall_target"
    uci -q -c "$firewall_config_dir" commit firewall || die 'failed to serialize named firewall candidate'
}

firewall_module_preflight() {
    firewall_classify_base "$CONFIG_DIR"
    if uci_get "$CONFIG_DIR" network.lan >/dev/null 2>&1; then
        [ -n "$FIREWALL_LAN_SECTION" ] || die 'stock network.lan requires a LAN firewall zone and forwarding'
    else
        [ -z "$FIREWALL_LAN_SECTION" ] || die 'obsolete LAN firewall policy exists without network.lan'
    fi
    if uci -q -c "$CONFIG_DIR" show firewall | grep -E "firewall\.@(zone|forwarding|rule)\[[0-9]+\].*(pixel|pixelthings|pixelguest|pixeliot)" >/dev/null; then
        die 'anonymous project firewall section found; migrate it to a named section first'
    fi
}

firewall_module_stage() {
    candidate_dir=$1
    overlay_file=$2
    firewall_rename_role "$candidate_dir" DEFAULTS defaults
    firewall_rename_role "$candidate_dir" WAN wan
    firewall_classify_base "$candidate_dir"
    if [ -n "$FIREWALL_LAN_SECTION" ]; then
        firewall_rename_role "$candidate_dir" LAN base_lan
        firewall_rename_role "$candidate_dir" LAN_WAN base_lan_wan
    fi
    uci -q -c "$candidate_dir" delete firewall.base_lan_wan 2>/dev/null || :
    uci -q -c "$candidate_dir" delete firewall.base_lan 2>/dev/null || :
    uci -q -c "$candidate_dir" del_list firewall.wan.network=wan6 2>/dev/null || :
    uci -q -c "$candidate_dir" commit firewall || die 'failed to normalize stock firewall candidate'
    apply_overlay "$candidate_dir" "$overlay_file"
    uci -q -c "$candidate_dir" set firewall.defaults.flow_offloading='1' ||
        die 'failed to enable software flow offloading'
    uci -q -c "$candidate_dir" set firewall.defaults.flow_offloading_hw='1' ||
        die 'failed to enable hardware flow offloading'
    uci -q -c "$candidate_dir" commit firewall || die 'failed to serialize flow offloading candidate'
}

firewall_module_validate() {
    candidate_dir=$1
    [ "$(uci_get "$candidate_dir" firewall.defaults)" = defaults ] || die 'candidate lacks named firewall defaults'
    [ "$(uci_get "$candidate_dir" firewall.defaults.flow_offloading)" = 1 ] ||
        die 'candidate lacks software flow offloading'
    [ "$(uci_get "$candidate_dir" firewall.defaults.flow_offloading_hw)" = 1 ] ||
        die 'candidate lacks hardware flow offloading'
    [ "$(uci_get "$candidate_dir" firewall.wan)" = zone ] || die 'candidate lacks named firewall WAN zone'
    [ "$(uci_get "$candidate_dir" firewall.wan.network)" = wan ] || die 'candidate WAN zone must contain only wan'
    ! uci -q -c "$candidate_dir" show firewall | grep -Eq "\.network='?wan6'?\$" ||
        die 'firewall still references an IPv6 WAN interface'
    for section_name in pixel pixelthings pixelguest pixeliot; do
        [ "$(uci_get "$candidate_dir" "firewall.$section_name")" = zone ] || die "missing firewall.$section_name"
        [ "$(uci_get "$candidate_dir" "firewall.divert_dns_$section_name.src")" = "$section_name" ] ||
            die "missing DNS interception for $section_name"
        [ "$(uci_get "$candidate_dir" "firewall.reject_dot_$section_name.src")" = "$section_name" ] ||
            die "missing DoT rejection for $section_name"
        [ "$(uci_get "$candidate_dir" "firewall.reject_doq_$section_name.src")" = "$section_name" ] ||
            die "missing DoQ rejection for $section_name"
    done
    [ "$(uci_get "$candidate_dir" firewall.pixel.forward)" = ACCEPT ] ||
        die 'Pixel zone must accept intra-zone forwarding'
    for section_name in pixelguest pixelthings pixeliot; do
        [ "$(uci_get "$candidate_dir" "firewall.$section_name.forward")" = REJECT ] ||
            die "$section_name zone must reject intra-zone forwarding"
        transit_rule="reject_isp_transit_$section_name"
        [ "$(uci_get "$candidate_dir" "firewall.$transit_rule")" = rule ] ||
            die "missing ISP transit rejection for $section_name"
        [ "$(uci_get "$candidate_dir" "firewall.$transit_rule.src")" = "$section_name" ] ||
            die "ISP transit rejection has an unexpected source for $section_name"
        [ "$(uci_get "$candidate_dir" "firewall.$transit_rule.dest")" = wan ] ||
            die "ISP transit rejection has an unexpected destination zone for $section_name"
        [ "$(uci_get "$candidate_dir" "firewall.$transit_rule.dest_ip")" = 192.168.2.0/24 ] ||
            die "ISP transit rejection has an unexpected destination subnet for $section_name"
        [ "$(uci_get "$candidate_dir" "firewall.$transit_rule.family")" = ipv4 ] ||
            die "ISP transit rejection has an unexpected family for $section_name"
        [ "$(uci_get "$candidate_dir" "firewall.$transit_rule.proto")" = all ] ||
            die "ISP transit rejection has an unexpected protocol for $section_name"
        [ "$(uci_get "$candidate_dir" "firewall.$transit_rule.target")" = REJECT ] ||
            die "ISP transit rejection has an unexpected target for $section_name"
    done
    [ "$(uci_get "$candidate_dir" firewall.pixeliot_dhcp_reply.dest)" = pixeliot ] ||
        die 'missing outbound IoT DHCP exception'
    [ "$(uci_get "$candidate_dir" firewall.pixeliot_dhcp_reply.src_port)" = 67 ] ||
        die 'IoT DHCP exception has an unexpected source port'
    [ "$(uci_get "$candidate_dir" firewall.pixeliot_dhcp_reply.dest_port)" = 68 ] ||
        die 'IoT DHCP exception has an unexpected destination port'
    [ "$(uci_get "$candidate_dir" firewall.pixeliot_dhcp_reply.proto)" = udp ] ||
        die 'IoT DHCP exception has an unexpected protocol'
    UCI_CONFIG_DIR="$candidate_dir" fw4 check >/dev/null 2>&1 || die 'fw4 rejected candidate configuration'
}
