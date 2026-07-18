#!/bin/sh

# Internal transaction callback module sourced by router-config.sh.

wireless_module_validate_passwords() {
    password_value=
    for variable_name in MAIN_WIFI_PASSWORD SECONDARY_WIFI_PASSWORD GUEST_WIFI_PASSWORD IOT_WIFI_PASSWORD; do
        eval "password_value=\${$variable_name-}"
        password_length=${#password_value}
        [ "$password_length" -ge 8 ] && [ "$password_length" -le 63 ] ||
            die "$variable_name must contain 8 to 63 characters"
        case $password_value in
            *[!\ -~]*) die "$variable_name contains a non-printable character" ;;
        esac
    done
}

wireless_module_preflight() {
    wireless_module_validate_passwords
    require_type wireless.radio0 wifi-device
    if uci -q -c "$CONFIG_DIR" show wireless | grep -E "wireless\.@wifi-iface\[[0-9]+\].*(pixelmain|pixelsecondary|pixelguest|pixeliot|PixelMain|PixelSecondary|PixelGuest|PixelIoT)" >/dev/null; then
        die 'anonymous project wireless section found; migrate it to a named section first'
    fi
}

wireless_module_stage() {
    candidate_dir=$1
    overlay_file=$2
    apply_overlay "$candidate_dir" wireless "$overlay_file"
    uci -q -c "$candidate_dir" set "wireless.pixelmain.key=$MAIN_WIFI_PASSWORD"
    uci -q -c "$candidate_dir" set "wireless.pixelsecondary.key=$SECONDARY_WIFI_PASSWORD"
    uci -q -c "$candidate_dir" set "wireless.pixelguest.key=$GUEST_WIFI_PASSWORD"
    uci -q -c "$candidate_dir" set "wireless.pixeliot.key=$IOT_WIFI_PASSWORD"
    uci -q -c "$candidate_dir" commit wireless || die 'failed to serialize wireless candidate'
}

wireless_module_validate() {
    candidate_dir=$1
    for section_name in pixelmain pixelsecondary pixelguest pixeliot; do
        [ "$(uci_get "$candidate_dir" "wireless.$section_name")" = wifi-iface ] || die "missing wireless.$section_name"
        key_value=$(uci_get "$candidate_dir" "wireless.$section_name.key") || die "missing Wi-Fi key for $section_name"
        [ -n "$key_value" ] || die "empty Wi-Fi key for $section_name"
    done
}
