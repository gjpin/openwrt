#!/bin/sh

# Confirmed transaction manager for the router's UCI configuration.
# Run only on the intended router with a verified local recovery path.

set -eu

CONFIG_DIR=${ROUTER_CONFIG_CONFIG_DIR:-/etc/config}
TX_ROOT=${ROUTER_CONFIG_BACKUP_DIR:-/root/router-config-backups}
LOCK_DIR=${ROUTER_CONFIG_LOCK_DIR:-/var/lock/router-config.lock}
# shellcheck disable=SC2034 # Used by the sourced network module.
SYS_CLASS_NET=${ROUTER_CONFIG_SYS_CLASS_NET:-/sys/class/net}
INIT_SCRIPT=${ROUTER_CONFIG_INIT_SCRIPT:-/etc/init.d/router-config-rollback}
LIBEXEC=${ROUTER_CONFIG_LIBEXEC:-/usr/libexec/router-config}
NETWORK_INIT=${ROUTER_CONFIG_NETWORK_INIT:-/etc/init.d/network}
FIREWALL_INIT=${ROUTER_CONFIG_FIREWALL_INIT:-/etc/init.d/firewall}
UHTTPD_INIT=${ROUTER_CONFIG_UHTTPD_INIT:-/etc/init.d/uhttpd}
DROPBEAR_INIT=${ROUTER_CONFIG_DROPBEAR_INIT:-/etc/init.d/dropbear}
CHRONYD_INIT=${ROUTER_CONFIG_CHRONYD_INIT:-/etc/init.d/chronyd}
DNSMASQ_INIT=${ROUTER_CONFIG_DNSMASQ_INIT:-/etc/init.d/dnsmasq}
ADGUARDHOME_INIT=${ROUTER_CONFIG_ADGUARDHOME_INIT:-/etc/init.d/adguardhome}
ADGUARDHOME_BIN=${ROUTER_CONFIG_ADGUARDHOME_BIN:-/usr/bin/AdGuardHome}
ADGUARDHOME_CONFIG=${ROUTER_CONFIG_ADGUARDHOME_CONFIG:-/etc/adguardhome/adguardhome.yaml}
PROC_NET_DIR=${ROUTER_CONFIG_PROC_NET_DIR:-/proc/net}
MODULES_CONF=${ROUTER_CONFIG_MODULES_CONF:-/etc/modules.conf}
CHRONY_CONF=${ROUTER_CONFIG_CHRONY_CONF:-/etc/chrony/chrony.conf}
TIMEOUT=${ROUTER_CONFIG_TIMEOUT:-300}
POLL_INTERVAL=${ROUTER_CONFIG_POLL_INTERVAL:-1}
WATCHDOG_READY_ATTEMPTS=${ROUTER_CONFIG_WATCHDOG_READY_ATTEMPTS:-10}
WATCHDOG_READY_INTERVAL=${ROUTER_CONFIG_WATCHDOG_READY_INTERVAL:-1}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${ROUTER_CONFIG_UCI_DIR:-}" ]; then
    UCI_DIR=$ROUTER_CONFIG_UCI_DIR
elif [ -n "${ROUTER_CONFIG_OVERLAY_DIR:-}" ]; then
    UCI_DIR=$ROUTER_CONFIG_OVERLAY_DIR
else
    UCI_DIR=$SCRIPT_DIR/uci
fi
if [ -n "${ROUTER_CONFIG_MODULE_DIR:-}" ]; then
    MODULE_DIR=$ROUTER_CONFIG_MODULE_DIR
elif [ -d "$SCRIPT_DIR/modules" ]; then
    MODULE_DIR=$SCRIPT_DIR/modules
else
    MODULE_DIR=${LIBEXEC}.modules
fi
RUNTIME_MODULE_DIR=${ROUTER_CONFIG_RUNTIME_MODULE_DIR:-${LIBEXEC}.modules}
UCI_PACKAGES='network firewall wireless dhcp system adguardhome chrony uhttpd dropbear attendedsysupgrade'
MODULES='network firewall wireless admin-access attendedsysupgrade nts adguard-home wireguard'

die() {
    printf 'router-config: %s\n' "$*" >&2
    exit 1
}

info() {
    printf 'router-config: %s\n' "$*"
}

require_root() {
    if [ "${ROUTER_CONFIG_TESTING:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
        die 'must run as root'
    fi
}

require_commands() {
    for command_name in uci fw4 ubus wifi sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
    done
    [ -x "$ADGUARDHOME_BIN" ] || die "required command not found: $ADGUARDHOME_BIN"
}

require_base_commands() {
    for command_name in uci ubus setsid; do
        command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
    done
}

remove_lock_dir() {
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    [ ! -e "$LOCK_DIR" ] || die "failed to remove lock directory: $LOCK_DIR"
}

clear_lock_traps() {
    if [ "${ignore_lock_hup:-0}" = 1 ]; then
        trap - EXIT INT TERM
        trap '' HUP
    else
        trap - EXIT HUP INT TERM
    fi
}

acquire_lock() {
    lock_parent=${LOCK_DIR%/*}
    [ "$lock_parent" = "$LOCK_DIR" ] || mkdir -p "$lock_parent"
    lock_attempt=0
    while [ "$lock_attempt" -lt 2 ]; do
        lock_attempt=$((lock_attempt + 1))
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" >"$LOCK_DIR/pid"
            if [ "${ignore_lock_hup:-0}" = 1 ]; then
                trap 'release_lock' EXIT INT TERM
                trap '' HUP
            else
                trap 'release_lock' EXIT HUP INT TERM
            fi
            return
        fi
        lock_pid=
        [ ! -r "$LOCK_DIR/pid" ] || lock_pid=$(sed -n '1p' "$LOCK_DIR/pid")
        case $lock_pid in
            '' | *[!0-9]*)
                # Empty or corrupt lock dirs are safe to clear and retry once.
                remove_lock_dir
                continue
                ;;
        esac
        if kill -0 "$lock_pid" 2>/dev/null; then
            die "another operation holds $LOCK_DIR (pid $lock_pid)"
        fi
        # Owner pid is dead; clear the stale lock and retry once.
        remove_lock_dir
    done
    die "could not acquire lock at $LOCK_DIR"
}

release_lock() {
    if [ -d "$LOCK_DIR" ]; then
        if [ -r "$LOCK_DIR/pid" ]; then
            lock_pid=$(sed -n '1p' "$LOCK_DIR/pid")
            if [ "$lock_pid" != "$$" ]; then
                clear_lock_traps
                return 0
            fi
        fi
        rm -f "$LOCK_DIR/pid"
        remove_lock_dir
    fi
    clear_lock_traps
}

uci_get() {
    uci -q -c "$1" get "$2"
}

require_type() {
    actual=$(uci_get "$CONFIG_DIR" "$1") || die "required UCI section missing: $1"
    [ "$actual" = "$2" ] || die "unexpected UCI type for $1: $actual"
}

load_transaction_modules() {
    for module_name in $MODULES; do
        module_file=$MODULE_DIR/$module_name.sh
        [ -s "$module_file" ] || die "missing transaction module: $module_file"
        # shellcheck source=/dev/null
        . "$module_file"
    done
}

canonicalize_dnsmasq() {
    candidate_dir=$1
    action=$2
    dnsmasq_sections=$(uci -q -c "$candidate_dir" show dhcp |
        sed -n "s/^\(dhcp\.[^=]*\)=dnsmasq$/\1/p")
    dnsmasq_count=$(printf '%s\n' "$dnsmasq_sections" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$dnsmasq_count" = 1 ] || die 'dhcp must contain exactly one dnsmasq section'
    case $dnsmasq_sections in
        dhcp.dnsmasq) return ;;
        dhcp.@dnsmasq\[*\]) : ;;
        *) die 'dnsmasq section has an ambiguous nonstandard name' ;;
    esac
    [ "$action" = rewrite ] || return 0

    export_file=$candidate_dir/.dhcp.export.$$
    rewrite_file=$candidate_dir/.dhcp.rewrite.$$
    uci -q -c "$candidate_dir" export dhcp >"$export_file" || die 'failed to export dhcp candidate'
    awk '
        BEGIN { changed = 0 }
        $1 == "config" && $2 == "dnsmasq" && NF == 2 {
            print "config dnsmasq \047dnsmasq\047"
            changed++
            next
        }
        { print }
        END { if (changed != 1) exit 1 }
    ' "$export_file" >"$rewrite_file" || die 'failed to name the anonymous dnsmasq section'
    uci -q -c "$candidate_dir" import dhcp <"$rewrite_file" || die 'failed to import named dnsmasq candidate'
    uci -q -c "$candidate_dir" commit dhcp || die 'failed to serialize dhcp candidate'
    rm -f "$export_file" "$rewrite_file"
}

preflight_base() {
    require_base_commands
    ubus call system board >/dev/null 2>&1 || die 'ubus system probe failed'
    for config_name in network firewall wireless dhcp system; do
        [ -s "$CONFIG_DIR/$config_name" ] || die "missing or empty $CONFIG_DIR/$config_name"
        uci -q -c "$CONFIG_DIR" show "$config_name" >/dev/null || die "malformed UCI package: $config_name"
    done
    network_module_preflight
    firewall_module_preflight
    wireless_module_preflight
    admin_access_preflight
    attendedsysupgrade_preflight
}

preflight() {
    require_commands
    adguard_home_inputs_preflight
    preflight_base
    [ -s "$CONFIG_DIR/adguardhome" ] || die "missing or empty $CONFIG_DIR/adguardhome"
    uci -q -c "$CONFIG_DIR" show adguardhome >/dev/null || die 'malformed UCI package: adguardhome'
    nts_preflight
}

check_base() {
    require_root
    preflight_base
    info 'base configuration is supported'
}

apply_overlay() {
    candidate_dir=$1
    overlay_file=$2
    [ -s "$overlay_file" ] || die "missing or empty overlay: $overlay_file"
    # shellcheck disable=SC2016
    grep -F '${' "$overlay_file" >/dev/null 2>&1 && die "unresolved placeholder in $overlay_file"
    while IFS=' ' read -r operation target _; do
        [ "$operation" = delete ] || continue
        [ -n "$target" ] || die "invalid delete in $overlay_file"
        uci -q -c "$candidate_dir" delete "$target" 2>/dev/null || :
    done <"$overlay_file"
    sed '/^[[:space:]]*delete[[:space:]]/d' "$overlay_file" |
        uci -q -c "$candidate_dir" batch >/dev/null || die "failed to apply overlay: $overlay_file"
    for package_name in $UCI_PACKAGES; do
        uci -q -c "$candidate_dir" commit "$package_name" || die "failed to serialize $package_name candidate"
    done
}

validate_candidate() {
    candidate_dir=$1
    for config_name in $UCI_PACKAGES; do
        [ -s "$candidate_dir/$config_name" ] || die "empty candidate package: $config_name"
        uci -q -c "$candidate_dir" show "$config_name" >/dev/null || die "malformed candidate package: $config_name"
        # shellcheck disable=SC2016
        grep -F '${' "$candidate_dir/$config_name" >/dev/null 2>&1 && die "unresolved placeholder in $config_name candidate"
    done
    network_module_validate "$candidate_dir"
    firewall_module_validate "$candidate_dir"
    wireless_module_validate "$candidate_dir"
    admin_access_validate "$candidate_dir"
    attendedsysupgrade_validate "$candidate_dir"
    nts_validate "$candidate_dir"
    adguard_home_validate "$candidate_dir"
    wireguard_validate "$candidate_dir"
}

new_transaction_id() {
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    entropy=$(printf '%s:%s\n' "$$" "$(date +%s)" | sha256sum | sed 's/[[:space:]].*//' | cut -c1-12)
    printf '%s-%s\n' "$timestamp" "$entropy"
}

write_manifest() {
    transaction_dir=$1
    manifest_files=
    for package_name in $UCI_PACKAGES; do
        manifest_files="$manifest_files backup/$package_name candidate/$package_name"
    done
    manifest_files="$manifest_files backup/modules.conf candidate/modules.conf"
    manifest_files="$manifest_files backup/chrony.conf candidate/chrony.conf"
    manifest_files="$manifest_files backup/adguardhome.yaml candidate/adguardhome.yaml"
    manifest_files="$manifest_files backup/adguardhome.present candidate/adguardhome.present"
    manifest_files="$manifest_files backup/adguardhome.enabled candidate/adguardhome.enabled"
    # Intentional splitting of the internally constructed relative path list.
    # shellcheck disable=SC2086
    (cd "$transaction_dir" && sha256sum $manifest_files) >"$transaction_dir/manifest.sha256"
    chmod 600 "$transaction_dir/manifest.sha256"
}

verify_manifest() {
    transaction_dir=$1
    (cd "$transaction_dir" && sha256sum -c manifest.sha256 >/dev/null) || die 'transaction checksum verification failed'
}

install_runtime() {
    mkdir -p "${LIBEXEC%/*}" "${INIT_SCRIPT%/*}" "$RUNTIME_MODULE_DIR"
    runtime_temp=$LIBEXEC.new.$$
    cp "$0" "$runtime_temp"
    chmod 700 "$runtime_temp"
    mv -f "$runtime_temp" "$LIBEXEC"
    for module_name in $MODULES; do
        module_temp=$RUNTIME_MODULE_DIR/$module_name.sh.new.$$
        cp "$MODULE_DIR/$module_name.sh" "$module_temp"
        chmod 600 "$module_temp"
        mv -f "$module_temp" "$RUNTIME_MODULE_DIR/$module_name.sh"
    done
    init_source=$SCRIPT_DIR/router-config-rollback.init
    [ -s "$init_source" ] || die "missing rollback service: $init_source"
    init_temp=$INIT_SCRIPT.new.$$
    sed "s|@ROUTER_CONFIG@|$LIBEXEC|g" "$init_source" >"$init_temp"
    chmod 700 "$init_temp"
    mv -f "$init_temp" "$INIT_SCRIPT"
    if [ "${ROUTER_CONFIG_TESTING:-0}" != 1 ]; then
        "$INIT_SCRIPT" enable >/dev/null 2>&1 || die 'could not enable early-boot rollback service'
    fi
}

prepare() {
    [ "${1-}" = --recovery-ready ] || die 'prepare requires --recovery-ready'
    require_root
    acquire_lock
    preflight
    mkdir -p "$TX_ROOT"
    chmod 700 "$TX_ROOT"
    transaction_id=$(new_transaction_id)
    transaction_dir=$TX_ROOT/$transaction_id
    umask 077
    mkdir "$transaction_dir" "$transaction_dir/backup" "$transaction_dir/candidate" "$transaction_dir/overlay"
    for package_name in $UCI_PACKAGES; do
        cp "$CONFIG_DIR/$package_name" "$transaction_dir/backup/$package_name"
        cp "$CONFIG_DIR/$package_name" "$transaction_dir/candidate/$package_name"
    done
    if [ -f "$MODULES_CONF" ]; then
        cp "$MODULES_CONF" "$transaction_dir/backup/modules.conf"
        cp "$MODULES_CONF" "$transaction_dir/candidate/modules.conf"
    else
        : >"$transaction_dir/backup/modules.conf"
        : >"$transaction_dir/candidate/modules.conf"
    fi
    cp "$CHRONY_CONF" "$transaction_dir/backup/chrony.conf"
    cp "$CHRONY_CONF" "$transaction_dir/candidate/chrony.conf"
    if [ -f "$ADGUARDHOME_CONFIG" ]; then
        cp "$ADGUARDHOME_CONFIG" "$transaction_dir/backup/adguardhome.yaml"
        printf '%s\n' 1 >"$transaction_dir/backup/adguardhome.present"
    else
        : >"$transaction_dir/backup/adguardhome.yaml"
        printf '%s\n' 0 >"$transaction_dir/backup/adguardhome.present"
    fi
    if "$ADGUARDHOME_INIT" enabled >/dev/null 2>&1; then
        printf '%s\n' 1 >"$transaction_dir/backup/adguardhome.enabled"
    else
        printf '%s\n' 0 >"$transaction_dir/backup/adguardhome.enabled"
    fi
    cp "$transaction_dir/backup/adguardhome.yaml" "$transaction_dir/candidate/adguardhome.yaml"
    printf '%s\n' 1 >"$transaction_dir/candidate/adguardhome.present"
    printf '%s\n' 1 >"$transaction_dir/candidate/adguardhome.enabled"
    for overlay_name in network firewall wireless admin-access attendedsysupgrade nts adguard-home; do
        cp "$UCI_DIR/$overlay_name" "$transaction_dir/overlay/$overlay_name"
    done
    wireguard_render_overlay "$UCI_DIR/wireguard" "$transaction_dir/overlay/wireguard"
    chmod 600 "$transaction_dir"/backup/* "$transaction_dir"/candidate/* "$transaction_dir"/overlay/*

    network_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/network"
    firewall_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/firewall"
    wireless_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/wireless"
    admin_access_stage "$transaction_dir/candidate" "$transaction_dir/overlay/admin-access"
    attendedsysupgrade_stage "$transaction_dir/candidate" "$transaction_dir/overlay/attendedsysupgrade"
    nts_stage "$transaction_dir/candidate" "$transaction_dir/overlay/nts"
    adguard_home_stage "$transaction_dir/candidate" "$transaction_dir/overlay/adguard-home"
    wireguard_stage "$transaction_dir/candidate" "$transaction_dir/overlay/wireguard"
    chmod 600 "$transaction_dir/candidate/modules.conf" "$transaction_dir/candidate/chrony.conf" \
        "$transaction_dir/candidate/adguardhome.yaml" "$transaction_dir/candidate/adguardhome.present" \
        "$transaction_dir/candidate/adguardhome.enabled"
    validate_candidate "$transaction_dir/candidate"
    write_manifest "$transaction_dir"
    printf '%s\n' prepared >"$transaction_dir/state"
    chmod 600 "$transaction_dir/state"
    install_runtime
    release_lock
    trap - EXIT HUP INT TERM
    info "prepared transaction $transaction_id"
    printf '%s\n' "$transaction_id"
}

install_uci_files() {
    source_dir=$1
    for config_name in $UCI_PACKAGES; do
        install_temp=$CONFIG_DIR/.$config_name.router-config.$$
        cp "$source_dir/$config_name" "$install_temp" || return 1
        chmod 600 "$install_temp" || return 1
        mv -f "$install_temp" "$CONFIG_DIR/$config_name" || return 1
    done
}

install_modules_conf() {
    source_dir=$1
    modules_parent=${MODULES_CONF%/*}
    [ "$modules_parent" = "$MODULES_CONF" ] || mkdir -p "$modules_parent" || return 1
    install_temp=$MODULES_CONF.router-config.$$
    cp "$source_dir/modules.conf" "$install_temp" || return 1
    chmod 600 "$install_temp" || return 1
    mv -f "$install_temp" "$MODULES_CONF" || return 1
}

install_chrony_conf() {
    source_dir=$1
    chrony_parent=${CHRONY_CONF%/*}
    [ "$chrony_parent" = "$CHRONY_CONF" ] || mkdir -p "$chrony_parent" || return 1
    install_temp=$CHRONY_CONF.router-config.$$
    cp "$source_dir/chrony.conf" "$install_temp" || return 1
    chmod 644 "$install_temp" || return 1
    mv -f "$install_temp" "$CHRONY_CONF" || return 1
}

install_adguard_home_config() {
    source_dir=$1
    config_parent=${ADGUARDHOME_CONFIG%/*}
    [ "$config_parent" = "$ADGUARDHOME_CONFIG" ] || mkdir -p "$config_parent" || return 1
    if [ "$(sed -n '1p' "$source_dir/adguardhome.present")" = 0 ]; then
        rm -f "$ADGUARDHOME_CONFIG" || return 1
        return 0
    fi
    install_temp=$ADGUARDHOME_CONFIG.router-config.$$
    cp "$source_dir/adguardhome.yaml" "$install_temp" || return 1
    chmod 600 "$install_temp" || return 1
    if [ "${ROUTER_CONFIG_TESTING:-0}" != 1 ]; then
        chown adguardhome:adguardhome "$install_temp" || return 1
        chmod 700 "$config_parent" || return 1
        chown adguardhome:adguardhome "$config_parent" || return 1
    fi
    mv -f "$install_temp" "$ADGUARDHOME_CONFIG" || return 1
}

install_candidate() {
    candidate_dir=$1
    install_uci_files "$candidate_dir" || return 1
    install_modules_conf "$candidate_dir" || return 1
    install_chrony_conf "$candidate_dir" || return 1
    install_adguard_home_config "$candidate_dir" || return 1
}

socket_port_listening() {
    socket_protocol=$1
    socket_port=$2
    hex_port=$(printf '%04X' "$socket_port")
    grep -Eq ":[0]*${hex_port}[[:space:]]" "$PROC_NET_DIR/$socket_protocol" 2>/dev/null
}

adguard_home_listeners_ready() {
    socket_port_listening tcp 53 && socket_port_listening udp 53 &&
        socket_port_listening tcp 54 && socket_port_listening udp 54 &&
        socket_port_listening tcp 3000
}

wait_for_adguard_home_listeners() {
    health_attempts=10
    [ "${ROUTER_CONFIG_TESTING:-0}" != 1 ] || health_attempts=1
    health_attempt=0
    while [ "$health_attempt" -lt "$health_attempts" ]; do
        health_attempt=$((health_attempt + 1))
        adguard_home_listeners_ready && return 0
        [ "$health_attempt" -lt "$health_attempts" ] || break
        sleep 1
    done
    return 1
}

reload_common_services() {
    RELOAD_FAILED_STEP=
    if ! "$NETWORK_INIT" reload; then
        RELOAD_FAILED_STEP=network
        return 1
    fi
    if ! wifi reload; then
        RELOAD_FAILED_STEP=wifi
        return 1
    fi
    if ! "$FIREWALL_INIT" reload; then
        RELOAD_FAILED_STEP=firewall
        return 1
    fi
    if ! "$UHTTPD_INIT" restart; then
        RELOAD_FAILED_STEP=uhttpd
        return 1
    fi
    if ! "$DROPBEAR_INIT" restart; then
        RELOAD_FAILED_STEP=dropbear
        return 1
    fi
    if ! "$CHRONYD_INIT" restart; then
        RELOAD_FAILED_STEP=chronyd
        return 1
    fi
}

reload_candidate_services() {
    reload_common_services || return 1
    if ! "$DNSMASQ_INIT" restart; then
        RELOAD_FAILED_STEP=dnsmasq
        return 1
    fi
    if ! "$ADGUARDHOME_INIT" restart; then
        RELOAD_FAILED_STEP=adguardhome
        return 1
    fi
    if ! wait_for_adguard_home_listeners; then
        RELOAD_FAILED_STEP=adguardhome-listeners
        return 1
    fi
}

reload_backup_services() {
    backup_dir=$1
    reload_common_services || return 1
    if ! "$DNSMASQ_INIT" restart; then
        RELOAD_FAILED_STEP=dnsmasq
        return 1
    fi
    if [ "$(sed -n '1p' "$backup_dir/adguardhome.enabled")" = 1 ]; then
        if ! "$ADGUARDHOME_INIT" restart; then
            RELOAD_FAILED_STEP=adguardhome
            return 1
        fi
        if ! wait_for_adguard_home_listeners; then
            RELOAD_FAILED_STEP=adguardhome-listeners
            return 1
        fi
    fi
}

restore_transaction() {
    transaction_dir=$1
    "$ADGUARDHOME_INIT" stop >/dev/null 2>&1 || :
    "$ADGUARDHOME_INIT" disable >/dev/null 2>&1 ||
        die 'CRITICAL: could not disable AdGuard Home during rollback'
    install_uci_files "$transaction_dir/backup" || die 'CRITICAL: UCI backup restoration failed'
    install_modules_conf "$transaction_dir/backup" || die 'CRITICAL: modules.conf backup restoration failed'
    install_chrony_conf "$transaction_dir/backup" || die 'CRITICAL: chrony.conf backup restoration failed'
    install_adguard_home_config "$transaction_dir/backup" ||
        die 'CRITICAL: AdGuard Home configuration backup restoration failed'
    if [ "$(sed -n '1p' "$transaction_dir/backup/adguardhome.enabled")" = 1 ]; then
        "$ADGUARDHOME_INIT" enable >/dev/null 2>&1 ||
            die 'CRITICAL: could not restore AdGuard Home enablement'
    fi
    if [ "${2-}" != boot ]; then
        reload_backup_services "$transaction_dir/backup" ||
            die 'CRITICAL: backups restored but a service reload failed'
    fi
    printf '%s\n' rolledback >"$transaction_dir/state"
    rm -f "$transaction_dir/pending" "$transaction_dir/watchdog.pid"
}

rollback_locked() {
    transaction_id=$1
    transaction_dir=$TX_ROOT/$transaction_id
    [ -d "$transaction_dir" ] || die "unknown transaction: $transaction_id"
    verify_manifest "$transaction_dir"
    restore_transaction "$transaction_dir"
    info "rolled back transaction $transaction_id"
}

watchdog_pid() {
    pid_file=$1
    [ -r "$pid_file" ] || return 1
    published_pid=$(sed -n '1p' "$pid_file")
    case $published_pid in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$published_pid"
}

remove_own_watchdog_pid() {
    pid_file=$1
    published_pid=$(watchdog_pid "$pid_file") || return 0
    [ "$published_pid" = "$$" ] || return 0
    rm -f "$pid_file"
}

watchdog() {
    transaction_id=$1
    transaction_dir=$TX_ROOT/$transaction_id
    pid_file=$transaction_dir/watchdog.pid
    trap '' HUP
    printf '%s\n' "$$" >"$pid_file"
    chmod 600 "$pid_file"
    sleep "$TIMEOUT"
    if [ ! -f "$transaction_dir/pending" ]; then
        remove_own_watchdog_pid "$pid_file"
        exit 0
    fi
    ignore_lock_hup=1
    acquire_lock
    if [ -f "$transaction_dir/pending" ]; then
        rollback_locked "$transaction_id"
    fi
    release_lock
    trap '' HUP
    remove_own_watchdog_pid "$pid_file"
}

terminate_watchdog_startup() {
    if [ -n "${watchdog_launcher_pid:-}" ]; then
        kill "$watchdog_launcher_pid" 2>/dev/null || :
    fi
    published_pid=$(watchdog_pid "$transaction_dir/watchdog.pid") || published_pid=
    if [ -n "$published_pid" ]; then
        kill "$published_pid" 2>/dev/null || :
    fi
}

apply_interrupted() {
    if [ "${watchdog_ready:-0}" = 1 ]; then
        release_lock
        exit 1
    fi
    terminate_watchdog_startup
    restore_transaction "$transaction_dir"
    release_lock
    exit 1
}

start_watchdog() {
    : >"$transaction_dir/watchdog.pid"
    chmod 600 "$transaction_dir/watchdog.pid"
    setsid "$LIBEXEC" _watchdog "$transaction_id" </dev/null >/dev/null 2>&1 &
    watchdog_launcher_pid=$!
    ready_attempt=0
    while [ "$ready_attempt" -lt "$WATCHDOG_READY_ATTEMPTS" ]; do
        ready_attempt=$((ready_attempt + 1))
        published_pid=$(watchdog_pid "$transaction_dir/watchdog.pid") || published_pid=
        if [ -n "$published_pid" ] && kill -0 "$published_pid" 2>/dev/null; then
            watchdog_ready=1
            watchdog_launcher_pid=
            return 0
        fi
        [ "$ready_attempt" -lt "$WATCHDOG_READY_ATTEMPTS" ] || break
        sleep "$WATCHDOG_READY_INTERVAL"
    done
    terminate_watchdog_startup
    return 1
}

apply_transaction() {
    transaction_id=${1-}
    [ -n "$transaction_id" ] || die 'apply requires a transaction ID'
    require_root
    acquire_lock
    transaction_dir=$TX_ROOT/$transaction_id
    [ -d "$transaction_dir" ] || die "unknown transaction: $transaction_id"
    [ "$(sed -n '1p' "$transaction_dir/state")" = prepared ] || die 'transaction is not prepared'
    verify_manifest "$transaction_dir"
    : >"$transaction_dir/pending"
    printf '%s\n' pending >"$transaction_dir/state"
    chmod 600 "$transaction_dir/pending" "$transaction_dir/state"

    watchdog_launcher_pid=
    watchdog_ready=0
    trap 'apply_interrupted' HUP INT TERM
    "$ADGUARDHOME_INIT" stop >/dev/null 2>&1 || :
    if ! "$DNSMASQ_INIT" stop; then
        restore_transaction "$transaction_dir"
        die 'could not stop dnsmasq; backups restored'
    fi
    if ! install_candidate "$transaction_dir/candidate"; then
        restore_transaction "$transaction_dir"
        die 'candidate installation failed; backups restored'
    fi
    if ! UCI_CONFIG_DIR="$CONFIG_DIR" fw4 check >/dev/null 2>&1; then
        restore_transaction "$transaction_dir"
        die 'fw4 rejected installed candidate; backups restored'
    fi
    if ! reload_candidate_services; then
        failed_step=$RELOAD_FAILED_STEP
        restore_transaction "$transaction_dir"
        die "service reload failed at $failed_step; backups restored"
    fi
    if ! start_watchdog; then
        restore_transaction "$transaction_dir"
        die 'could not start rollback watchdog; backups restored'
    fi
    release_lock
    trap - EXIT HUP INT TERM

    info 'candidate applied; confirm from a second local/recovery-capable session with:'
    printf '%s confirm %s\n' "$LIBEXEC" "$transaction_id"
    info 'software and hardware flow offloading are active after firewall reload'
    info 'reboot after confirm for Wireless Ethernet Dispatch (WED) to take effect'
    while [ -f "$transaction_dir/pending" ]; do
        sleep "$POLL_INTERVAL"
    done
    final_state=$(sed -n '1p' "$transaction_dir/state")
    [ "$final_state" = confirmed ] || die "transaction ended in state: $final_state"
    info "confirmed transaction $transaction_id"
}

prune_confirmed() {
    confirmed_list=
    for state_file in "$TX_ROOT"/*/state; do
        [ -f "$state_file" ] || continue
        [ "$(sed -n '1p' "$state_file")" = confirmed ] || continue
        confirmed_list="$confirmed_list\n${state_file%/state}"
    done
    printf '%b\n' "$confirmed_list" | sed '/^$/d' | sort -r | sed -n '4,$p' |
        while IFS= read -r old_transaction; do
            [ ! -f "$old_transaction/pending" ] || continue
            rm -rf "$old_transaction"
        done
}

confirm_transaction() {
    transaction_id=${1-}
    [ -n "$transaction_id" ] || die 'confirm requires a transaction ID'
    require_root
    acquire_lock
    transaction_dir=$TX_ROOT/$transaction_id
    [ -f "$transaction_dir/pending" ] || die 'transaction is not pending'
    "$ADGUARDHOME_INIT" enable >/dev/null 2>&1 ||
        die 'could not enable AdGuard Home; transaction remains pending'
    printf '%s\n' confirmed >"$transaction_dir/state"
    rm -f "$transaction_dir/pending"
    prune_confirmed
    release_lock
    trap - EXIT HUP INT TERM
    info "confirmed transaction $transaction_id"
    info 'reboot required for WED (mt7915e wed_enable) to take effect'
}

rollback_transaction() {
    transaction_id=${1-}
    [ -n "$transaction_id" ] || die 'rollback requires a transaction ID'
    require_root
    acquire_lock
    rollback_locked "$transaction_id"
    release_lock
    trap - EXIT HUP INT TERM
}

recover_pending() {
    require_root
    acquire_lock
    for pending_file in "$TX_ROOT"/*/pending; do
        [ -f "$pending_file" ] || continue
        transaction_id=$(basename "${pending_file%/pending}")
        transaction_dir=$TX_ROOT/$transaction_id
        verify_manifest "$transaction_dir"
        restore_transaction "$transaction_dir" boot
        info "rolled back pending boot transaction $transaction_id"
    done
    release_lock
    trap - EXIT HUP INT TERM
}

usage() {
    printf '%s\n' 'usage: router-config.sh check-base' \
        '       router-config.sh prepare --recovery-ready' \
        '       router-config.sh apply <transaction-id>' \
        '       router-config.sh confirm <transaction-id>' \
        '       router-config.sh rollback <transaction-id>' >&2
    exit 2
}

load_transaction_modules

case ${1-} in
    check-base)
        shift
        [ "$#" -eq 0 ] || usage
        check_base
        ;;
    prepare)
        shift
        prepare "$@"
        ;;
    apply)
        shift
        apply_transaction "$@"
        ;;
    confirm)
        shift
        confirm_transaction "$@"
        ;;
    rollback)
        shift
        rollback_transaction "$@"
        ;;
    _watchdog)
        shift
        watchdog "$@"
        ;;
    _recover-pending) recover_pending ;;
    *) usage ;;
esac
