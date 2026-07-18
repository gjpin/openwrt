#!/bin/sh

# Confirmed transaction manager for the router's UCI and DNSCrypt configuration.
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
SYSNTPD_INIT=${ROUTER_CONFIG_SYSNTPD_INIT:-/etc/init.d/sysntpd}
DNSCRYPT_INIT=${ROUTER_CONFIG_DNSCRYPT_INIT:-/etc/init.d/dnscrypt-proxy}
DNSMASQ_INIT=${ROUTER_CONFIG_DNSMASQ_INIT:-/etc/init.d/dnsmasq}
ADBLOCK_INIT=${ROUTER_CONFIG_ADBLOCK_INIT:-/etc/init.d/adblock-fast}
DNSCRYPT_CONFIG=${ROUTER_CONFIG_DNSCRYPT_CONFIG:-${DNSCRYPT_CONFIG_FILE:-/etc/dnscrypt-proxy2/dnscrypt-proxy.toml}}
TIMEOUT=${ROUTER_CONFIG_TIMEOUT:-300}
POLL_INTERVAL=${ROUTER_CONFIG_POLL_INTERVAL:-1}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${ROUTER_CONFIG_UCI_DIR:-}" ]; then
    UCI_DIR=$ROUTER_CONFIG_UCI_DIR
elif [ -n "${ROUTER_CONFIG_OVERLAY_DIR:-}" ]; then
    UCI_DIR=$ROUTER_CONFIG_OVERLAY_DIR
else
    UCI_DIR=$SCRIPT_DIR/uci
fi
DNSCRYPT_SOURCE=${ROUTER_CONFIG_DNSCRYPT_SOURCE:-$SCRIPT_DIR/configs/dnscrypt/dnscrypt-proxy.toml}
if [ -n "${ROUTER_CONFIG_MODULE_DIR:-}" ]; then
    MODULE_DIR=$ROUTER_CONFIG_MODULE_DIR
elif [ -d "$SCRIPT_DIR/modules" ]; then
    MODULE_DIR=$SCRIPT_DIR/modules
else
    MODULE_DIR=${LIBEXEC}.modules
fi
RUNTIME_MODULE_DIR=${ROUTER_CONFIG_RUNTIME_MODULE_DIR:-${LIBEXEC}.modules}
UCI_PACKAGES='network firewall wireless dhcp system adblock-fast'
MODULES='network firewall wireless dns-over-https adblock-fast wireguard'

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
    for command_name in uci fw4 ubus wifi sha256sum dnscrypt-proxy; do
        command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
    done
}

acquire_lock() {
    lock_parent=${LOCK_DIR%/*}
    [ "$lock_parent" = "$LOCK_DIR" ] || mkdir -p "$lock_parent"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        trap 'release_lock' EXIT HUP INT TERM
        return
    fi
    lock_pid=
    [ ! -r "$LOCK_DIR/pid" ] || lock_pid=$(sed -n '1p' "$LOCK_DIR/pid")
    case $lock_pid in
        '' | *[!0-9]*) die "another operation holds $LOCK_DIR" ;;
    esac
    if kill -0 "$lock_pid" 2>/dev/null; then
        die "another operation holds $LOCK_DIR (pid $lock_pid)"
    fi
    die "stale lock found at $LOCK_DIR; inspect and remove it manually"
}

release_lock() {
    if [ -r "$LOCK_DIR/pid" ] && [ "$(sed -n '1p' "$LOCK_DIR/pid")" = "$$" ]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || :
    fi
    trap - EXIT HUP INT TERM
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
    dnsmasq_show=$(uci -q -c "$candidate_dir" show dhcp | grep "='dnsmasq'\$" || :)
    dnsmasq_count=$(printf '%s\n' "$dnsmasq_show" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$dnsmasq_count" = 1 ] || die 'dhcp must contain exactly one dnsmasq section'
    case $dnsmasq_show in
        "dhcp.dnsmasq='dnsmasq'") return ;;
        dhcp.@dnsmasq\[*\]="'dnsmasq'") : ;;
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

preflight() {
    require_commands
    ubus call system board >/dev/null 2>&1 || die 'ubus system probe failed'
    for config_name in $UCI_PACKAGES; do
        [ -s "$CONFIG_DIR/$config_name" ] || die "missing or empty $CONFIG_DIR/$config_name"
        uci -q -c "$CONFIG_DIR" show "$config_name" >/dev/null || die "malformed UCI package: $config_name"
    done
    [ -s "$DNSCRYPT_SOURCE" ] || die "missing or empty DNSCrypt source: $DNSCRYPT_SOURCE"
    network_module_preflight
    firewall_module_preflight
    wireless_module_preflight
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
    dnscrypt_candidate=$2
    for config_name in $UCI_PACKAGES; do
        [ -s "$candidate_dir/$config_name" ] || die "empty candidate package: $config_name"
        uci -q -c "$candidate_dir" show "$config_name" >/dev/null || die "malformed candidate package: $config_name"
        # shellcheck disable=SC2016
        grep -F '${' "$candidate_dir/$config_name" >/dev/null 2>&1 && die "unresolved placeholder in $config_name candidate"
    done
    # shellcheck disable=SC2016
    grep -F '${' "$dnscrypt_candidate" >/dev/null 2>&1 && die 'unresolved placeholder in DNSCrypt candidate'
    network_module_validate "$candidate_dir"
    firewall_module_validate "$candidate_dir"
    wireless_module_validate "$candidate_dir"
    dns_over_https_validate "$candidate_dir" "$dnscrypt_candidate"
    adblock_fast_validate "$candidate_dir"
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
    if [ -f "$transaction_dir/backup/dnscrypt-proxy.toml" ]; then
        manifest_files="$manifest_files backup/dnscrypt-proxy.toml"
    else
        manifest_files="$manifest_files backup/dnscrypt-proxy.missing"
    fi
    manifest_files="$manifest_files candidate/dnscrypt-proxy.toml"
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
    if [ -f "$DNSCRYPT_CONFIG" ]; then
        cp "$DNSCRYPT_CONFIG" "$transaction_dir/backup/dnscrypt-proxy.toml"
    else
        : >"$transaction_dir/backup/dnscrypt-proxy.missing"
    fi
    cp "$DNSCRYPT_SOURCE" "$transaction_dir/candidate/dnscrypt-proxy.toml"
    for overlay_name in network firewall wireless dns-over-https adblock-fast; do
        cp "$UCI_DIR/$overlay_name" "$transaction_dir/overlay/$overlay_name"
    done
    wireguard_render_overlay "$UCI_DIR/wireguard" "$transaction_dir/overlay/wireguard"
    chmod 600 "$transaction_dir"/backup/* "$transaction_dir"/candidate/* "$transaction_dir"/overlay/*

    network_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/network"
    firewall_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/firewall"
    wireless_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/wireless"
    dns_over_https_stage "$transaction_dir/candidate" "$transaction_dir/overlay/dns-over-https" "$transaction_dir/candidate/dnscrypt-proxy.toml"
    adblock_fast_stage "$transaction_dir/candidate" "$transaction_dir/overlay/adblock-fast"
    wireguard_stage "$transaction_dir/candidate" "$transaction_dir/overlay/wireguard"
    validate_candidate "$transaction_dir/candidate" "$transaction_dir/candidate/dnscrypt-proxy.toml"
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

install_candidate() {
    candidate_dir=$1
    install_uci_files "$candidate_dir" || return 1
    dnscrypt_parent=${DNSCRYPT_CONFIG%/*}
    [ "$dnscrypt_parent" = "$DNSCRYPT_CONFIG" ] || mkdir -p "$dnscrypt_parent" || return 1
    dnscrypt_temp=$DNSCRYPT_CONFIG.router-config.$$
    cp "$candidate_dir/dnscrypt-proxy.toml" "$dnscrypt_temp" || return 1
    chmod 600 "$dnscrypt_temp" || return 1
    mv -f "$dnscrypt_temp" "$DNSCRYPT_CONFIG" || return 1
}

reload_services() {
    "$NETWORK_INIT" restart &&
        wifi reload &&
        "$FIREWALL_INIT" reload &&
        "$SYSNTPD_INIT" restart &&
        "$DNSCRYPT_INIT" restart &&
        "$DNSMASQ_INIT" restart &&
        "$ADBLOCK_INIT" restart
}

restore_transaction() {
    transaction_dir=$1
    install_uci_files "$transaction_dir/backup" || die 'CRITICAL: UCI backup restoration failed'
    if [ -f "$transaction_dir/backup/dnscrypt-proxy.missing" ]; then
        rm -f "$DNSCRYPT_CONFIG"
    else
        dnscrypt_temp=$DNSCRYPT_CONFIG.router-config.restore.$$
        cp "$transaction_dir/backup/dnscrypt-proxy.toml" "$dnscrypt_temp" || die 'CRITICAL: DNSCrypt backup restoration failed'
        chmod 600 "$dnscrypt_temp" || die 'CRITICAL: DNSCrypt backup restoration failed'
        mv -f "$dnscrypt_temp" "$DNSCRYPT_CONFIG" || die 'CRITICAL: DNSCrypt backup restoration failed'
    fi
    if [ "${2-}" != boot ]; then
        reload_services || die 'CRITICAL: backups restored but a service reload failed'
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

watchdog() {
    transaction_id=$1
    sleep "$TIMEOUT"
    transaction_dir=$TX_ROOT/$transaction_id
    [ -f "$transaction_dir/pending" ] || exit 0
    acquire_lock
    if [ -f "$transaction_dir/pending" ]; then
        rollback_locked "$transaction_id"
    fi
    release_lock
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

    trap 'restore_transaction "$transaction_dir"; release_lock; exit 1' HUP INT TERM
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
    if ! reload_services; then
        restore_transaction "$transaction_dir"
        die 'service reload failed; backups restored'
    fi
    "$LIBEXEC" _watchdog "$transaction_id" >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$transaction_dir/watchdog.pid"
    release_lock
    trap - EXIT HUP INT TERM

    info 'candidate applied; confirm from a second local/recovery-capable session with:'
    printf '%s confirm %s\n' "$LIBEXEC" "$transaction_id"
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
    printf '%s\n' confirmed >"$transaction_dir/state"
    rm -f "$transaction_dir/pending"
    prune_confirmed
    release_lock
    trap - EXIT HUP INT TERM
    info "confirmed transaction $transaction_id"
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
    printf '%s\n' 'usage: router-config.sh prepare --recovery-ready' \
        '       router-config.sh apply <transaction-id>' \
        '       router-config.sh confirm <transaction-id>' \
        '       router-config.sh rollback <transaction-id>' >&2
    exit 2
}

load_transaction_modules

case ${1-} in
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
