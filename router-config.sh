#!/bin/sh

# Transactional OpenWrt network/firewall/wireless overlay manager.
# Run only on the intended router with a verified local recovery path.

set -eu

CONFIG_DIR=${ROUTER_CONFIG_CONFIG_DIR:-/etc/config}
TX_ROOT=${ROUTER_CONFIG_BACKUP_DIR:-/root/router-config-backups}
LOCK_DIR=${ROUTER_CONFIG_LOCK_DIR:-/var/lock/router-config.lock}
# shellcheck disable=SC2034 # Used by the sourced network transaction module.
SYS_CLASS_NET=${ROUTER_CONFIG_SYS_CLASS_NET:-/sys/class/net}
INIT_SCRIPT=${ROUTER_CONFIG_INIT_SCRIPT:-/etc/init.d/router-config-rollback}
LIBEXEC=${ROUTER_CONFIG_LIBEXEC:-/usr/libexec/router-config}
NETWORK_INIT=${ROUTER_CONFIG_NETWORK_INIT:-/etc/init.d/network}
FIREWALL_INIT=${ROUTER_CONFIG_FIREWALL_INIT:-/etc/init.d/firewall}
TIMEOUT=${ROUTER_CONFIG_TIMEOUT:-300}
POLL_INTERVAL=${ROUTER_CONFIG_POLL_INTERVAL:-1}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
OVERLAY_DIR=${ROUTER_CONFIG_OVERLAY_DIR:-$SCRIPT_DIR/configs/openwrt}
if [ -n "${ROUTER_CONFIG_MODULE_DIR:-}" ]; then
    MODULE_DIR=$ROUTER_CONFIG_MODULE_DIR
elif [ -d "$SCRIPT_DIR/modules" ]; then
    MODULE_DIR=$SCRIPT_DIR/modules
else
    MODULE_DIR=${LIBEXEC}.modules
fi
RUNTIME_MODULE_DIR=${ROUTER_CONFIG_RUNTIME_MODULE_DIR:-${LIBEXEC}.modules}

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
    if [ -r "$LOCK_DIR/pid" ]; then
        lock_pid=$(sed -n '1p' "$LOCK_DIR/pid")
    fi
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
    for module_name in network firewall wireless; do
        module_file=$MODULE_DIR/$module_name.sh
        [ -s "$module_file" ] || die "missing transaction module: $module_file"
        # shellcheck source=/dev/null
        . "$module_file"
    done
}

preflight() {
    require_commands
    ubus call system board >/dev/null 2>&1 || die 'ubus system probe failed'
    for config_name in network firewall wireless; do
        [ -s "$CONFIG_DIR/$config_name" ] || die "missing or empty $CONFIG_DIR/$config_name"
        uci -q -c "$CONFIG_DIR" show "$config_name" >/dev/null || die "malformed UCI package: $config_name"
    done

    network_module_preflight
    firewall_module_preflight
    wireless_module_preflight
}

apply_overlay() {
    candidate_dir=$1
    package_name=$2
    overlay_file=$3
    [ -s "$overlay_file" ] || die "missing or empty overlay: $overlay_file"
    # shellcheck disable=SC2016 # Search for a literal template marker.
    grep -F '${' "$overlay_file" >/dev/null 2>&1 && die "unresolved placeholder in $overlay_file"
    while IFS=' ' read -r operation target _; do
        [ "$operation" = delete ] || continue
        [ -n "$target" ] || die "invalid delete in $overlay_file"
        uci -q -c "$candidate_dir" delete "$target" 2>/dev/null || :
    done <"$overlay_file"
    sed '/^[[:space:]]*delete[[:space:]]/d' "$overlay_file" |
        uci -q -c "$candidate_dir" batch >/dev/null || die "failed to apply $package_name overlay"
    uci -q -c "$candidate_dir" commit "$package_name" || die "failed to serialize $package_name candidate"
}

validate_candidate() {
    candidate_dir=$1
    for config_name in network firewall wireless; do
        [ -s "$candidate_dir/$config_name" ] || die "empty candidate package: $config_name"
        uci -q -c "$candidate_dir" show "$config_name" >/dev/null || die "malformed candidate package: $config_name"
        # shellcheck disable=SC2016 # Search for a literal template marker.
        grep -F '${' "$candidate_dir/$config_name" >/dev/null 2>&1 && die "unresolved placeholder in $config_name candidate"
    done
    network_module_validate "$candidate_dir"
    firewall_module_validate "$candidate_dir"
    wireless_module_validate "$candidate_dir"
}

new_transaction_id() {
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    entropy=$(printf '%s:%s\n' "$$" "$(date +%s)" | sha256sum | sed 's/[[:space:]].*//' | cut -c1-12)
    printf '%s-%s\n' "$timestamp" "$entropy"
}

write_manifest() {
    transaction_dir=$1
    (
        cd "$transaction_dir"
        sha256sum backup/network backup/firewall backup/wireless candidate/network candidate/firewall candidate/wireless
    ) >"$transaction_dir/manifest.sha256"
    chmod 600 "$transaction_dir/manifest.sha256"
}

verify_manifest() {
    transaction_dir=$1
    (cd "$transaction_dir" && sha256sum -c manifest.sha256 >/dev/null) || die 'transaction checksum verification failed'
}

install_runtime() {
    mkdir -p "${LIBEXEC%/*}" "${INIT_SCRIPT%/*}" "$RUNTIME_MODULE_DIR"
    runtime_temp="$LIBEXEC.new.$$"
    cp "$0" "$runtime_temp"
    chmod 700 "$runtime_temp"
    mv -f "$runtime_temp" "$LIBEXEC"
    for module_name in network firewall wireless; do
        module_temp=$RUNTIME_MODULE_DIR/$module_name.sh.new.$$
        cp "$MODULE_DIR/$module_name.sh" "$module_temp"
        chmod 600 "$module_temp"
        mv -f "$module_temp" "$RUNTIME_MODULE_DIR/$module_name.sh"
    done
    init_source="$SCRIPT_DIR/router-config-rollback.init"
    [ -s "$init_source" ] || die "missing rollback service: $init_source"
    init_temp="$INIT_SCRIPT.new.$$"
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
    cp "$CONFIG_DIR/network" "$CONFIG_DIR/firewall" "$CONFIG_DIR/wireless" "$transaction_dir/backup/"
    cp "$transaction_dir/backup/"* "$transaction_dir/candidate/"
    cp "$OVERLAY_DIR/network" "$OVERLAY_DIR/firewall" "$OVERLAY_DIR/wireless" "$transaction_dir/overlay/"
    chmod 600 "$transaction_dir"/backup/* "$transaction_dir"/candidate/* "$transaction_dir"/overlay/*

    network_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/network"
    firewall_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/firewall"
    wireless_module_stage "$transaction_dir/candidate" "$transaction_dir/overlay/wireless"
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

atomic_install() {
    source_dir=$1
    for config_name in network firewall wireless; do
        install_temp="$CONFIG_DIR/.$config_name.router-config.$$"
        cp "$source_dir/$config_name" "$install_temp" || return 1
        chmod 600 "$install_temp" || return 1
        mv -f "$install_temp" "$CONFIG_DIR/$config_name" || return 1
    done
}

reload_services() {
    "$NETWORK_INIT" restart && wifi reload && "$FIREWALL_INIT" reload
}

restore_transaction() {
    transaction_dir=$1
    atomic_install "$transaction_dir/backup" || die 'CRITICAL: backup restoration failed'
    if [ "${2-}" != boot ]; then
        reload_services || die 'CRITICAL: backup restored but a service reload failed'
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
    if ! atomic_install "$transaction_dir/candidate"; then
        restore_transaction "$transaction_dir"
        die 'candidate installation failed; backup restored'
    fi
    if ! UCI_CONFIG_DIR="$CONFIG_DIR" fw4 check >/dev/null 2>&1; then
        restore_transaction "$transaction_dir"
        die 'fw4 rejected installed candidate; backup restored'
    fi
    if ! reload_services; then
        restore_transaction "$transaction_dir"
        die 'service reload failed; backup restored'
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
    # Keep the newest three confirmed transactions. Prepared, pending, and
    # rolled-back transactions are never automatically removed.
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
        # Networking has not started at START=05. Restore the files only; the
        # normal boot sequence will load them after this service returns.
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
