#!/bin/sh

# Internal transaction callback module sourced by router-config.sh.

wireless_module_validate_passwords() {
    password_value=
    for variable_name in PIXEL_WIFI_PASSWORD THINGS_WIFI_PASSWORD GUEST_WIFI_PASSWORD IOT_WIFI_PASSWORD; do
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
    [ -n "${COUNTRY-}" ] || die 'required variable is empty: COUNTRY'
    CHANNEL=${CHANNEL:-52}
    case $CHANNEL in
        '' | *[!0-9]*) die 'CHANNEL must be an integer from 36 through 177' ;;
    esac
    [ "$CHANNEL" -ge 36 ] 2>/dev/null && [ "$CHANNEL" -le 177 ] 2>/dev/null ||
        die 'CHANNEL must be an integer from 36 through 177'
    WIRELESS_2G_DEVICE=
    WIRELESS_5G_DEVICE=
    wifi_devices=$(uci -q -c "$CONFIG_DIR" show wireless |
        sed -n "s/^wireless\.\([^.]*\)=wifi-device$/\1/p")
    # Intentional splitting: UCI section names cannot contain whitespace.
    # shellcheck disable=SC2086
    for section_name in $wifi_devices; do
        band=$(uci -q -c "$CONFIG_DIR" get "wireless.$section_name.band" 2>/dev/null || :)
        case $band in
            2g)
                [ -z "$WIRELESS_2G_DEVICE" ] || die 'multiple 2.4 GHz wifi-device sections found'
                WIRELESS_2G_DEVICE=$section_name
                ;;
            5g)
                [ -z "$WIRELESS_5G_DEVICE" ] || die 'multiple 5 GHz wifi-device sections found'
                WIRELESS_5G_DEVICE=$section_name
                ;;
        esac
    done
    [ -n "$WIRELESS_2G_DEVICE" ] || die "missing wifi-device with band '2g'"
    [ -n "$WIRELESS_5G_DEVICE" ] || die "missing wifi-device with band '5g'"
    if uci -q -c "$CONFIG_DIR" show wireless | grep -E "wireless\.@wifi-iface\[[0-9]+\].*(pixel|pixelthings|pixelguest|pixeliot|Pixel|PixelThings|PixelGuest|PixelIoT)" >/dev/null; then
        die 'anonymous project wireless section found; migrate it to a named section first'
    fi
}

wireless_module_stage() {
    candidate_dir=$1
    overlay_file=$2
    apply_overlay "$candidate_dir" "$overlay_file"
    uci -q -c "$candidate_dir" set "wireless.pixel.key=$PIXEL_WIFI_PASSWORD"
    uci -q -c "$candidate_dir" set "wireless.pixelthings.key=$THINGS_WIFI_PASSWORD"
    uci -q -c "$candidate_dir" set "wireless.pixelguest.key=$GUEST_WIFI_PASSWORD"
    uci -q -c "$candidate_dir" set "wireless.pixeliot.key=$IOT_WIFI_PASSWORD"
    uci -q -c "$candidate_dir" set "wireless.pixel.device=$WIRELESS_5G_DEVICE"
    uci -q -c "$candidate_dir" set "wireless.pixelthings.device=$WIRELESS_5G_DEVICE"
    uci -q -c "$candidate_dir" set "wireless.pixelguest.device=$WIRELESS_5G_DEVICE"
    uci -q -c "$candidate_dir" set "wireless.pixeliot.device=$WIRELESS_2G_DEVICE"
    uci -q -c "$candidate_dir" set "wireless.$WIRELESS_2G_DEVICE.country=$COUNTRY"
    uci -q -c "$candidate_dir" set "wireless.$WIRELESS_5G_DEVICE.country=$COUNTRY"
    uci -q -c "$candidate_dir" set "wireless.$WIRELESS_5G_DEVICE.channel=$CHANNEL"
    uci -q -c "$candidate_dir" set "wireless.$WIRELESS_5G_DEVICE.htmode=HE80"
    uci -q -c "$candidate_dir" commit wireless || die 'failed to serialize wireless candidate'
    wireless_stage_wed "$candidate_dir/modules.conf"
}

wireless_stage_wed() {
    modules_file=$1
    [ -f "$modules_file" ] || die "missing modules.conf candidate: $modules_file"
    staged_file=$modules_file.wed.$$
    awk '
        /^[[:space:]]*options[[:space:]]+mt7915e([[:space:]]|$)/ && /wed_enable=/ { next }
        { print }
    ' "$modules_file" >"$staged_file" || die 'failed to stage WED modules.conf'
    printf '%s\n' 'options mt7915e wed_enable=Y' >>"$staged_file" ||
        die 'failed to append WED modules.conf option'
    mv -f "$staged_file" "$modules_file" || die 'failed to install WED modules.conf candidate'
}

wireless_module_validate() {
    candidate_dir=$1
    for section_name in pixel pixelthings pixelguest pixeliot; do
        [ "$(uci_get "$candidate_dir" "wireless.$section_name")" = wifi-iface ] || die "missing wireless.$section_name"
        key_value=$(uci_get "$candidate_dir" "wireless.$section_name.key") || die "missing Wi-Fi key for $section_name"
        [ -n "$key_value" ] || die "empty Wi-Fi key for $section_name"
    done
    for section_name in pixel pixelthings pixelguest; do
        [ "$(uci_get "$candidate_dir" "wireless.$section_name.device")" = "$WIRELESS_5G_DEVICE" ] ||
            die "wireless.$section_name is not assigned to the 5 GHz radio"
    done
    [ "$(uci_get "$candidate_dir" wireless.pixeliot.device)" = "$WIRELESS_2G_DEVICE" ] ||
        die 'wireless.pixeliot is not assigned to the 2.4 GHz radio'
    [ "$(uci_get "$candidate_dir" "wireless.$WIRELESS_2G_DEVICE.country")" = "$COUNTRY" ] ||
        die "wireless.$WIRELESS_2G_DEVICE.country is not set to COUNTRY"
    [ "$(uci_get "$candidate_dir" "wireless.$WIRELESS_5G_DEVICE.country")" = "$COUNTRY" ] ||
        die "wireless.$WIRELESS_5G_DEVICE.country is not set to COUNTRY"
    [ "$(uci_get "$candidate_dir" "wireless.$WIRELESS_5G_DEVICE.channel")" = "$CHANNEL" ] ||
        die "wireless.$WIRELESS_5G_DEVICE.channel is not set to CHANNEL"
    [ "$(uci_get "$candidate_dir" "wireless.$WIRELESS_5G_DEVICE.htmode")" = HE80 ] ||
        die "wireless.$WIRELESS_5G_DEVICE.htmode is not set to HE80"
    modules_file=$candidate_dir/modules.conf
    [ -f "$modules_file" ] || die 'candidate lacks modules.conf'
    grep -qx 'options mt7915e wed_enable=Y' "$modules_file" ||
        die 'candidate modules.conf lacks WED enablement'
    wed_lines=$(grep -c 'wed_enable=' "$modules_file" || :)
    [ "$wed_lines" = 1 ] || die 'candidate modules.conf has duplicate WED options'
}
