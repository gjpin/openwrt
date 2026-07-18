#!/bin/sh

# Build the single release asset consumed by setup.sh. Publish the resulting
# archive at the immutable versioned URL, then copy the printed digest into
# ROUTER_CONFIG_BUNDLE_SHA256.

set -eu

[ "$#" -eq 1 ] || {
    printf '%s\n' 'usage: tools/build-router-config-bundle.sh <output.tar.gz>' >&2
    exit 2
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
output_directory=$(CDPATH='' cd -- "$(dirname -- "$1")" && pwd)
output_path=$output_directory/$(basename -- "$1")
staging_directory=$(mktemp -d)
trap 'rm -rf "$staging_directory"' EXIT HUP INT TERM

mkdir -p "$staging_directory/uci" "$staging_directory/modules"
cp "$repository_dir/router-config.sh" "$repository_dir/router-config-rollback.init" "$staging_directory/"
cp "$repository_dir/uci/network" \
    "$repository_dir/uci/firewall" \
    "$repository_dir/uci/wireless" \
    "$repository_dir/uci/dns-over-https" \
    "$repository_dir/uci/adblock-fast" \
    "$repository_dir/uci/wireguard" \
    "$staging_directory/uci/"
cp "$repository_dir/modules/base-packages.sh" \
    "$repository_dir/modules/network.sh" \
    "$repository_dir/modules/firewall.sh" \
    "$repository_dir/modules/wireless.sh" \
    "$repository_dir/modules/dns-over-https.sh" \
    "$repository_dir/modules/adblock-fast.sh" \
    "$repository_dir/modules/wireguard.sh" \
    "$staging_directory/modules/"

(
    cd "$staging_directory"
    tar -czf "$output_path" \
        router-config.sh router-config-rollback.init uci modules
)
sha256sum "$output_path"
