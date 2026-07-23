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

nts_check_chrony_conf() {
    chrony_file=$1
    expected_auth_count=$2

    [ -s "$chrony_file" ] || die "missing or empty Chrony configuration: $chrony_file"
    directive_counts=$(
        awk '
            /^[[:space:]]*(#|$)/ { next }
            $1 == "authselectmode" {
                auth_count++
                if (NF == 2 && $2 == "ignore") ignore_count++
                next
            }
            $1 == "confdir" {
                confdir_count++
                if (NF == 2 && $2 == "/var/etc/chrony.d") generated_count++
            }
            END {
                printf "%d %d %d %d\n",
                    auth_count + 0, ignore_count + 0,
                    confdir_count + 0, generated_count + 0
            }
        ' "$chrony_file"
    ) || die "failed to inspect Chrony configuration: $chrony_file"
    # Intentional splitting of four numeric fields emitted by the awk program.
    # shellcheck disable=SC2086
    set -- $directive_counts
    auth_count=$1
    ignore_count=$2
    confdir_count=$3
    generated_count=$4

    [ "$confdir_count" = 1 ] && [ "$generated_count" = 1 ] ||
        die 'Chrony configuration must contain exactly one confdir /var/etc/chrony.d'
    if [ "$expected_auth_count" = optional ]; then
        [ "$auth_count" -le 1 ] ||
            die 'Chrony configuration must contain at most one authselectmode directive'
    else
        [ "$auth_count" = "$expected_auth_count" ] ||
            die "Chrony configuration must contain exactly $expected_auth_count authselectmode directive(s)"
    fi
    [ "$ignore_count" = "$auth_count" ] ||
        die 'Chrony configuration has a conflicting authselectmode'
}

nts_preflight() {
    nts_check_chrony_conf "$CHRONY_CONF" optional
}

nts_stage_chrony_conf() {
    chrony_file=$1
    staged_file=$chrony_file.new.$$
    awk '
        /^[[:space:]]*authselectmode[[:space:]]+/ { next }
        /^[[:space:]]*confdir[[:space:]]+\/var\/etc\/chrony\.d[[:space:]]*([#].*)?$/ {
            print "authselectmode ignore"
        }
        { print }
    ' "$chrony_file" >"$staged_file" ||
        die 'failed to stage Chrony authentication selection policy'
    mv -f "$staged_file" "$chrony_file" ||
        die 'failed to install Chrony configuration candidate'
}

nts_stage() {
    candidate_dir=$1
    overlay_file=$2
    # The package ships a default pool, DHCP NTP source, and LAN allow.
    # Start from an empty candidate so none of those survive.
    : >"$candidate_dir/chrony"
    apply_overlay "$candidate_dir" "$overlay_file"
    nts_stage_chrony_conf "$candidate_dir/chrony.conf"
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
        [ "$(uci_get "$candidate_dir" "chrony.$provider.prefer")" = 1 ] ||
            die "chrony NTS server must be preferred: $provider"
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
        bootstrap_prefer=$(uci_get "$candidate_dir" "chrony.$bootstrap.prefer" || :)
        [ -z "$bootstrap_prefer" ] ||
            die "chrony bootstrap server must not be preferred: $bootstrap"
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

    nts_check_chrony_conf "$candidate_dir/chrony.conf" 1
    adjacent_policy_count=$(
        awk '
            previous == "authselectmode ignore" &&
                $0 ~ /^[[:space:]]*confdir[[:space:]]+\/var\/etc\/chrony\.d[[:space:]]*([#].*)?$/ {
                count++
            }
            { previous = $0 }
            END { print count + 0 }
        ' "$candidate_dir/chrony.conf"
    ) || die 'failed to validate Chrony authentication selection policy'
    [ "$adjacent_policy_count" = 1 ] ||
        die 'authselectmode ignore must immediately precede the generated Chrony confdir'
}
