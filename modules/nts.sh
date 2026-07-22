#!/bin/sh

# chrony-nts package installation and transaction callbacks.

nts_install() {
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        attempt=$((attempt + 1))
        apk add chrony-nts && break
        [ "$attempt" -lt 5 ] || die 'failed to install chrony-nts'
        sleep $((attempt * 2))
    done
    sysntpd_init=${ROUTER_CONFIG_SYSNTPD_INIT:-/etc/init.d/sysntpd}
    chronyd_init=${ROUTER_CONFIG_CHRONYD_INIT:-/etc/init.d/chronyd}
    "$sysntpd_init" stop || :
    "$sysntpd_init" disable
    "$chronyd_init" enable
}

nts_stage() {
    candidate_dir=$1
    overlay_file=$2
    # The package ships a default pool, DHCP NTP source, and LAN allow.
    # Start from an empty candidate so none of those survive.
    : >"$candidate_dir/chrony"
    apply_overlay "$candidate_dir" "$overlay_file"
}

nts_validate() {
    candidate_dir=$1

    for provider_spec in \
        'cloudflare|time.cloudflare.com' \
        'netnod|nts.netnod.se' \
        'time_nl|ntppool1.time.nl'; do
        provider=${provider_spec%%|*}
        hostname=${provider_spec#*|}
        [ "$(uci_get "$candidate_dir" "chrony.$provider")" = server ] ||
            die "missing chrony NTS server: $provider"
        [ "$(uci_get "$candidate_dir" "chrony.$provider.hostname")" = "$hostname" ] ||
            die "unexpected chrony hostname for $provider"
        [ "$(uci_get "$candidate_dir" "chrony.$provider.iburst")" = 1 ] ||
            die "chrony NTS server must use iburst: $provider"
        [ "$(uci_get "$candidate_dir" "chrony.$provider.nts")" = 1 ] ||
            die "chrony NTS server must enable nts: $provider"
    done

    for bootstrap_spec in \
        'bootstrap_1|194.177.4.1' \
        'bootstrap_2|213.222.217.11' \
        'bootstrap_3|80.50.102.114' \
        'bootstrap_4|193.219.28.60'; do
        bootstrap=${bootstrap_spec%%|*}
        hostname=${bootstrap_spec#*|}
        [ "$(uci_get "$candidate_dir" "chrony.$bootstrap")" = server ] ||
            die "missing chrony bootstrap server: $bootstrap"
        [ "$(uci_get "$candidate_dir" "chrony.$bootstrap.hostname")" = "$hostname" ] ||
            die "unexpected chrony hostname for $bootstrap"
        [ "$(uci_get "$candidate_dir" "chrony.$bootstrap.iburst")" = 1 ] ||
            die "chrony bootstrap server must use iburst: $bootstrap"
        [ "$(uci_get "$candidate_dir" "chrony.$bootstrap.nts")" = 0 ] ||
            die "chrony bootstrap server must not enable nts: $bootstrap"
    done

    [ "$(uci_get "$candidate_dir" chrony.dhcp_ntp_server)" = dhcp_ntp_server ] ||
        die 'chrony candidate lacks dhcp_ntp_server'
    [ "$(uci_get "$candidate_dir" chrony.dhcp_ntp_server.disabled)" = 1 ] ||
        die 'chrony must not use DHCP NTP sources'
    [ "$(uci_get "$candidate_dir" chrony.makestep)" = makestep ] ||
        die 'chrony candidate lacks makestep'
    [ "$(uci_get "$candidate_dir" chrony.makestep.threshold)" = 1.0 ] ||
        die 'unexpected chrony makestep threshold'
    [ "$(uci_get "$candidate_dir" chrony.makestep.limit)" = 3 ] ||
        die 'unexpected chrony makestep limit'
    [ "$(uci_get "$candidate_dir" chrony.nts)" = nts ] ||
        die 'chrony candidate lacks nts section'
    [ "$(uci_get "$candidate_dir" chrony.nts.rtccheck)" = 1 ] ||
        die 'chrony nts rtccheck must be enabled'
    [ "$(uci_get "$candidate_dir" chrony.nts.systemcerts)" = 1 ] ||
        die 'chrony nts systemcerts must be enabled'

    pool_or_allow=$(uci -q -c "$candidate_dir" show chrony |
        sed -n "s/^chrony\.[^=]*=\(pool\|allow\)$/\1/p")
    [ -z "$pool_or_allow" ] ||
        die 'chrony candidate must not enable pool or allow sections'
    server_count=$(uci -q -c "$candidate_dir" show chrony |
        grep -Ec "=('server'|server)\$") || :
    [ "$server_count" = 7 ] ||
        die 'chrony candidate must contain exactly seven server sections'
}
