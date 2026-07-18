# OpenWrt network layout

## Provisioning entrypoint and modules

`setup.sh --recovery-ready` is the only supported provisioning entrypoint. The
files under `modules/` are internal POSIX `sh` modules that are sourced by the
entrypoint or transaction helper; they are not standalone commands and cannot
be selected or reordered by callers.

The fixed, fail-fast execution order is:

1. `base-packages.sh` updates package metadata and installs the common tools.
2. `network.sh`, `firewall.sh`, and `wireless.sh` stage and validate one
   rollback-capable transaction. All three candidates are installed before any
   of their services are reloaded, and setup does not continue until the
   transaction is confirmed.
3. `dns-over-https.sh` installs and configures DNSCrypt Proxy, with dnsmasq and
   DNSCrypt aligned on `127.0.0.53:53`.
4. `adblock-fast.sh` installs `adblock-fast` and its LuCI app from the official
   OpenWrt feeds, then configures four named block-list sources and forced DNS
   for every managed VLAN.
5. `wireguard.sh` creates stable named network, peer, and firewall sections and
   attaches the VPN interface to the named `pixelmain` zone.

`router-config.sh` owns shared preflight checks, candidate construction,
checksums, backups, atomic installation, confirmation, and rollback. The three
core modules own their package-specific stage, preflight, and candidate
validation callbacks. This keeps the overlays separate without weakening the
single network/firewall/wireless transaction boundary.

## Secrets and input contract

Export all secrets in the router shell before invoking setup. Do not write them
to this repository, a release bundle, command-line arguments, or deployment
logs:

```sh
export MAIN_WIFI_PASSWORD='...'
export SECONDARY_WIFI_PASSWORD='...'
export GUEST_WIFI_PASSWORD='...'
export IOT_WIFI_PASSWORD='...'
export VPN_IF='wgserver'
export VPN_PORT='51820'
export VPN_KEY='...'
export VPN_ADDR='10.10.0.1/24'
export VPN_ADDR6='fd10::1/64'
export VPN_PUB='...'
export VPN_PSK='...'
./setup.sh --recovery-ready
```

Setup validates every required variable, Wi-Fi password lengths, WireGuard key
shape, the port range, address families, and a safe UCI interface name before
the first router mutation. Wi-Fi keys are injected only into the protected
transaction candidate; WireGuard secrets are passed directly to UCI and are
never printed by the scripts.

## Immutable bundle publication

Build the single deployment artifact from the repository root:

```sh
tools/build-router-config-bundle.sh ./router-config-bundle.tar.gz
```

Publish that exact archive as `router-config-bundle.tar.gz` on an immutable
GitHub release. Update `ROUTER_CONFIG_BUNDLE_VERSION` and
`ROUTER_CONFIG_BUNDLE_SHA256` together in `setup.sh` using the release tag and
the digest printed by the builder. The bundle contains the transaction helper,
rollback init script, overlays, DNSCrypt configuration, and every module. Setup
verifies the archive digest and refuses missing or empty members before package
installation or configuration changes.

Provisioning supports fresh OpenWrt 25.12 or newer installations with official
`apk` feeds and at least 256 MB RAM. It uses `apk` exclusively and does not
preserve or migrate an existing ad-blocking configuration.

## Confirmation and rollback

Before running setup, create a configuration backup and establish a tested
local Ethernet or serial recovery path. Do not rely on the same remote path
that the VLAN transaction changes. During apply, setup prints a confirmation
command containing the transaction ID and waits. From a second local or
recovery-capable session, inspect connectivity and run the printed command,
which has this form:

```sh
/usr/libexec/router-config confirm TRANSACTION_ID
```

If confirmation does not arrive within the configured timeout (five minutes by
default), the watchdog restores all three backups. The early-boot rollback
service also restores a transaction left pending across a reboot. To revert a
confirmed transaction deliberately:

```sh
/usr/libexec/router-config rollback TRANSACTION_ID
```

Backups and candidates are stored under `/root/router-config-backups` with
checksummed manifests. Keep a separate off-router backup as well; automatic
rollback cannot substitute for a physical recovery path.

The files in `configs/openwrt/` are UCI batch overlays. They update named
project sections in an existing router configuration; they are not complete
replacements for `/etc/config/network`, `/etc/config/firewall`, or
`/etc/config/wireless`. The router must retain its base loopback, globals, WAN,
WAN6, firewall defaults, WAN zone, and `br_lan` device sections.

## How the files connect

The shared name is the link between the three configurations:

```text
wireless.<section>.network
            |
            v
network.<interface name>
            |
            v
firewall.<zone>.network
```

Example for the guest network:

```text
SSID PixelGuest
  wireless.pixelguest.network = pixelguest
                         |
                         v
  network.pixelguest = br-lan.2 / 192.168.2.1/24
                         |
                         v
  firewall.pixelguest.network = pixelguest
```

The complete mapping is:

| Purpose | SSID | Wireless radio | Network interface | VLAN | Router address | Firewall zone |
|---|---|---|---|---:|---|---|
| Main | `PixelMain` | `radio0` | `pixelmain` | 1 | `192.168.1.1/24` | `pixelmain` |
| Guest | `PixelGuest` | `radio0` | `pixelguest` | 2 | `192.168.2.1/24` | `pixelguest` |
| IoT | `PixelIoT` | `radio0` | `pixeliot` | 3 | `192.168.3.1/24` | `pixeliot` |
| Secondary | `PixelSecondary` | `radio0` | `pixelsecondary` | 4 | `192.168.4.1/24` | `pixelsecondary` |

All four SSIDs use WPA3-SAE. Passwords are not stored in the overlay;
`router-config.sh` injects them while preparing the candidate configuration.

## Network and VLANs

`configs/openwrt/network` defines four bridge VLANs on the existing `br-lan`
device and assigns one static interface to each VLAN.

```text
br-lan
  |
  +-- VLAN 1 -- br-lan.1 -- pixelmain      -- 192.168.1.1/24
  +-- VLAN 2 -- br-lan.2 -- pixelguest     -- 192.168.2.1/24
  +-- VLAN 3 -- br-lan.3 -- pixeliot       -- 192.168.3.1/24
  `-- VLAN 4 -- br-lan.4 -- pixelsecondary -- 192.168.4.1/24
```

Only `pixelmain` requests IPv6 prefix assignment, with `ip6assign='60'`.

Ethernet port membership:

```text
             VLAN 1       VLAN 2       VLAN 3       VLAN 4
lan1         untagged      tagged       tagged       tagged
lan2         untagged        -            -            -
lan3         untagged        -            -            -
lan4         untagged        -            -            -
```

`lan1` is therefore an untagged Main port plus a tagged trunk for Guest, IoT,
and Secondary. `lan2` through `lan4` are untagged Main ports. The `*` on each
`lanN:u*` entry makes VLAN 1 the port's primary VLAN ID.

## Wireless

`configs/openwrt/wireless` creates four access points on `radio0`. Each AP's
`network` option attaches it to the logical interface with the same name:

```text
radio0
  |
  +-- PixelMain      -- pixelmain      -- br-lan.1
  +-- PixelGuest     -- pixelguest     -- br-lan.2
  +-- PixelIoT       -- pixeliot       -- br-lan.3
  `-- PixelSecondary -- pixelsecondary -- br-lan.4
```

The radio and Ethernet port names are device-specific. This configuration
assumes the target provides `radio0`, `br-lan`, and `lan1` through `lan4`.

## Firewall policy

`configs/openwrt/firewall` places each logical network in a firewall zone of
the same name. Forwarding is allowlisted; any path not shown as allowed is
rejected by the zone policies.

```text
Internet forwarding:
  PixelMain      ----> WAN
  PixelGuest     ----> WAN
  PixelSecondary ----> WAN
  PixelIoT       --X-> WAN

Inter-VLAN forwarding:
  PixelMain ----> PixelGuest
  PixelMain ----> PixelSecondary
  PixelMain ----> PixelIoT

  PixelGuest, PixelSecondary, and PixelIoT --X-> other VLANs

Allowed routed flows:
  PixelMain      -> WAN, PixelGuest, PixelSecondary, PixelIoT
  PixelGuest     -> WAN
  PixelSecondary -> WAN
  PixelIoT       -> none
```

Access to services on the router itself:

| Zone | Input to router | Explicit exceptions |
|---|---|---|
| `pixelmain` | Accepted | Not required |
| `pixelguest` | Rejected | DNS and DHCP: ports 53, 67, 68 TCP/UDP |
| `pixelsecondary` | Rejected | DNS and DHCP: ports 53, 67, 68 TCP/UDP |
| `pixeliot` | Rejected | DNS and DHCP: ports 53, 67, 68 TCP/UDP |

Zone output is accepted for Main, Guest, and Secondary, but rejected for IoT.
Zone forwarding defaults to reject for all four zones; only the forwarding
sections listed above create inter-zone paths.

## DHCP and base configuration

No `/etc/config/dhcp` overlay is tracked. Each interface needs an explicit DHCP
decision on the target router before clients can be expected to receive an
address. DNS/DHCP firewall exceptions permit those services but do not configure
or enable a DHCP server.

Before applying network, firewall, or wireless changes, back up the router and
have a local Ethernet or serial recovery path. Validate the staged configuration
on the exact router model and OpenWrt release; these overlays depend on existing
base sections and device-specific port and radio names.
