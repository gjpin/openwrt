# OpenWrt router configuration

This repository provisions a device-specific OpenWrt network with four isolated
VLANs, encrypted DNS, AdGuard Home, and a WireGuard server. Changes are built
as one validated candidate and applied with automatic rollback unless they are
confirmed within five minutes.

## Features

- Four WPA3 networks: Pixel, Guest, IoT, and Things
- AP client isolation on Guest, IoT, and Things (`isolate=1`)
- 5 GHz on non-DFS channel `36` at `HE80`
- VLAN and DHCP configuration for each network
- Allowlisted inter-VLAN and internet access
- LuCI and SSH bound to the Pixel gateway only (`192.168.8.1` / `pixel`)
- LuCI checks for attended sysupgrades when the Status Overview page loads
- AdGuard Home as the primary DNS resolver, using encrypted upstreams and DNS
  bypass controls (port-53 interception plus DoT/DoQ rejects)
- Preferred authenticated NTP via `chrony-nts` (NTS), with unauthenticated
  NTP-by-IP cold-boot and outage fallback
- DNS-based ad and tracker blocking with an authenticated Pixel-only dashboard
- An IPv4-only WireGuard server attached to the trusted Pixel zone, with no
  preconfigured client peers
- Static IPv4 WAN behind an ISP router (`192.168.2.2/24`, gateway
  `192.168.2.1`), with managed VLANs on `192.168.8`–`11.0/24` (double NAT)
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
OpenWrt LAN `192.168.1.1` is removed). LuCI and SSH listen only on that Pixel
address/interface; Guest, IoT, and Things cannot reach them on their own
gateways. First make an off-router configuration
backup and verify a recovery path through local Ethernet or serial. `setup.sh`
must run on the target router as `root`; do not run it on a workstation.

## Run on the OpenWrt router

1. Set ISP router LAN address to: 192.168.2.1/24
2. Connect ISP router to Flint 2 WAN port
  - Physical ports: Any ISP router LAN port -> Flint 2 WAN port
3. Assign 192.168.2.2 for Flint 2
4. Connect to Flint 2 Wifi
5. Access Flint 2 Admin UI: 192.168.8.1
6. Upgrade Flint 2 to upstream OpenWRT
  - System -> Upgrade -> Firmware Local Upgrade
7. Connect to Flint via ethernet
8. Access 192.168.1.1 via 2 SSH: root@192.168.1.1
9. Disable ISP wifi network: 2.4 GHz, 5 GHz, and Guest Wi-Fi
10. Download script:
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
11. Set env vars and run setup:
   ```sh
   export PIXEL_WIFI_PASSWORD='replace-me'
   export THINGS_WIFI_PASSWORD='replace-me'
   export GUEST_WIFI_PASSWORD='replace-me'
   export IOT_WIFI_PASSWORD='replace-me'
   export COUNTRY='XX'
   # Optional: override the 5 GHz primary channel (default 36, non-DFS).
   # Width is always HE80; use only a country-legal channel.
   # export CHANNEL='36'
   # Optional: permit private DNS answers for this apex and its subdomains.
   # export DNS_REBIND_DOMAIN='mydomain.com'
   export ADGUARD_USERNAME='admin'
   # Generate this bcrypt hash off-router, for example with Apache htpasswd:
   # htpasswd -bnBC 12 '' 'replace-me' | cut -d: -f2
   export ADGUARD_PASSWORD_HASH='$2y$12$replace-with-a-real-60-character-bcrypt-hash'
   export VPN_IF='wgserver'
   export VPN_PORT='42451'
   export VPN_KEY="$(wg genkey)"
   export VPN_ADDR='10.10.0.1/24'
   ./setup.sh --recovery-ready
   ```
12. Access 192.168.8.1 via 2 SSH: root@192.168.8.1
13. Run `/usr/libexec/router-config confirm TRANSACTION_ID`
14. Open the AdGuard Home dashboard at `http://192.168.8.1:3000` from Pixel.
15. Run `reboot`
16. Create WireGuard peers by running add-wireguard-peers.sh in Flint (MUST add the peers in the TODO section)
  - Get the wireguard configs from /root/wireguard-clients
  - Create a port forward in ISP router for wireguard
17. Add Flint to ISP router DMZ


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
a run. `--profile live` additionally tests bad-clock synchronization from a
numeric NTP source while DNS is stopped, subsequent NTS authentication,
AdGuard Home encrypted upstream resolution, and filter downloads; run it from the manual CI
workflow when needed. On Linux x86_64, the exact target package/flash-fit gate
is:

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
Setup creates the WireGuard server without client peers; add a peer separately
before testing its handshake and routing.

## Module reference

The modules run in a fixed order and are internal files sourced by `setup.sh` or
the transaction helper. They are not standalone commands.

- [Base packages](docs/base-packages.md)
- [Network and DHCP](docs/network.md)
- [Firewall](docs/firewall.md)
- [Wireless](docs/wireless.md)
- [Admin access](docs/admin-access.md)
- [Attended Sysupgrade](docs/attendedsysupgrade.md)
- [Encrypted NTP (NTS)](docs/nts.md)
- [AdGuard Home DNS and ad blocking](docs/adguard-home.md)
- [WireGuard](docs/wireguard.md)
