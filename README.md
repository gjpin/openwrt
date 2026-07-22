# OpenWrt router configuration

This repository provisions a device-specific OpenWrt network with four isolated
VLANs, encrypted DNS, DNS blocklists, and a WireGuard server. Changes are built
as one validated candidate and applied with automatic rollback unless they are
confirmed within five minutes.

## Features

- Four WPA3 networks: Pixel, Guest, IoT, and Things
- VLAN and DHCP configuration for each network
- Allowlisted inter-VLAN and internet access
- HTTPS DNS proxy upstreams with DNS bypass controls
- DNS-based ad and tracker blocking
- An IPv4-only WireGuard server attached to the trusted Pixel zone
- Static IPv4 WAN behind an ISP router (`192.168.1.2/24`, gateway
  `192.168.1.1`), with managed VLANs on `192.168.8`–`11.0/24` (double NAT)
- IPv4-only WAN and managed VLANs, with IPv6 delegation and advertisements disabled
- Checksummed backups, candidate validation, and timed/early-boot rollback

## Compatibility and safety

This configuration supports a fresh upstream OpenWrt 25.12 installation on the
GL.iNet GL-MT6000 using official `apk` feeds and at least 256 MB RAM. It expects
one `2g` and one `5g` wifi-device, `br-lan`, and DSA ports `lan1` through `lan5`.
The installer recognizes the unique stock anonymous `br-lan` device, firewall
defaults, LAN and WAN zones, LAN-to-WAN forwarding, `lan`/`wan6` interfaces, LAN
DHCP pool, and ULA prefix by content. It removes obsolete base items only in the candidate.
Ambiguous or customized base sections are rejected before package installation.

Do not run this on a router with a different port or radio layout. Applying the
network, firewall, and wireless changes can disconnect every remote session.
After apply, management access moves to the Pixel gateway `192.168.8.1` (stock
OpenWrt LAN `192.168.1.1` is removed). First make an off-router configuration
backup and verify a recovery path through local Ethernet or serial. `setup.sh`
must run on the target router as `root`; do not run it on a workstation.

## Run on the OpenWrt router

1. Open two local or recovery-capable sessions to the router. Before apply,
   `ROUTER_ADDRESS` is typically the stock LAN address (`192.168.1.1`). After
   apply, use the Pixel gateway (`192.168.8.1`) for management and confirmation.
   In the first session, create a backup:

   ```sh
   ssh root@ROUTER_ADDRESS
   sysupgrade -b /tmp/openwrt-backup.tar.gz
   ```

   From a workstation terminal, copy `/tmp/openwrt-backup.tar.gz` off the router
   before continuing:

   ```sh
   scp root@ROUTER_ADDRESS:/tmp/openwrt-backup.tar.gz ./openwrt-backup.tar.gz
   ```

2. In the router session, download and extract the current `main` source archive.
   Git is not required. A fresh temporary directory avoids mixing files from an
   earlier download:

   ```sh
   set -eu
   archive="/tmp/openwrt-main.$$.tar.gz"
   source_root="/tmp/openwrt-source.$$"
   mkdir -p "$source_root"
   uclient-fetch 'https://github.com/gjpin/openwrt/archive/refs/heads/main.tar.gz' -O "$archive"
   [ -s "$archive" ] || { printf '%s\n' 'OpenWrt configuration download is empty' >&2; exit 1; }
   tar -xzf "$archive" -C "$source_root"
   cd "$source_root/openwrt-main"
   ```

   This intentionally follows the mutable `main` branch without a pinned digest.
   Review the current repository state before running it on a router.

3. Export the deployment secrets. Replace every
   example value; do not save real values in this repository or pass them as
   command-line arguments:

   ```sh
   export PIXEL_WIFI_PASSWORD='replace-me'
   export THINGS_WIFI_PASSWORD='replace-me'
   export GUEST_WIFI_PASSWORD='replace-me'
   export IOT_WIFI_PASSWORD='replace-me'
   export COUNTRY='XX'
   # Optional: 5 GHz channel (default 52, DFS). Width is always HE80.
   # export CHANNEL='52'
   export VPN_IF='wgserver'
   export VPN_PORT='42451'
   export VPN_KEY='replace-with-server-private-key'
   export VPN_ADDR='10.10.0.1/24'
   export VPN_PUB='replace-with-client-public-key'
   export VPN_PSK='replace-with-preshared-key'
   ./setup.sh --recovery-ready
   ```

4. Keep the first session open. Test management access, DHCP, DNS, and expected
   internet access from the appropriate VLANs. In the second recovery-capable
   session, run the exact confirmation command printed by setup:

   ```sh
   /usr/libexec/router-config confirm TRANSACTION_ID
   ```

If confirmation is not received within five minutes, or the router reboots with
a pending transaction, the saved configuration is restored. A confirmed change
can be reverted later with:

```sh
/usr/libexec/router-config rollback TRANSACTION_ID
```

Package installation and init-service enablement happen before the protected
configuration transaction and are not removed by rollback. Backups are kept in
`/root/router-config-backups`; retain the separate off-router backup too.

## Development checks

Run the Python integration suite concurrently across the available development
container CPUs:

```sh
python tools/run-tests.py
```

Use `--workers 1` for a serial run or `--workers N` to select another level of
concurrency. Each test uses its own simulated router filesystem; these tests do
not apply configuration to a router.

The full stable suite boots the SHA-256-pinned official OpenWrt 25.12.4 AArch64
kernel and ext4 rootfs in QEMU. Downloads are cached in `.cache/openwrt-vm` and
verified on every run. On Apple Silicon macOS:

```sh
cd /path/to/openwrt
brew install qemu
python3 tools/run-vm-tests.py --profile stable
```

Use `--keep-workdir` to retain the disposable disk and redacted serial log after
a run. `--profile live` additionally checks every external DoH provider and
blocklist URL; run it from the manual CI workflow when needed. On Linux x86_64,
the exact target package/flash-fit gate is:

```sh
python3 tools/check-imagebuilder.py
```

That command uses the pinned official `mediatek/filogic` ImageBuilder with
`PROFILE=glinet_gl-mt6000`, verifies factory and sysupgrade images plus their
package manifest, and discards all generated firmware. Nothing produced by the
test harness is a deployment artifact.

QEMU exercises OpenWrt userland, real UCI serialization, fw4, procd services,
namespaced VLAN clients, DNS interception, WireGuard, idempotency, and rollback.
It cannot emulate the MT7986/MT7531 switch, MT7915 RF behavior, 2.5 GbE PHYs,
bootloader, or eMMC recovery. Physical deployment therefore still requires an
off-router backup, local Ethernet or serial recovery, and real port, Wi-Fi,
reboot, WireGuard, DNS, and rollback acceptance tests.

## Module reference

The modules run in a fixed order and are internal files sourced by `setup.sh` or
the transaction helper. They are not standalone commands.

- [Base packages](docs/base-packages.md)
- [Network and DHCP](docs/network.md)
- [Firewall](docs/firewall.md)
- [Wireless](docs/wireless.md)
- [Encrypted DNS](docs/dns-over-https.md)
- [Ad blocking](docs/adblock-fast.md)
- [WireGuard](docs/wireguard.md)
