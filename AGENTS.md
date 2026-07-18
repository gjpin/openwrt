# AGENTS.md

## Purpose

This repository stores a device-specific OpenWrt configuration and a provisioning
script. Treat changes as router infrastructure changes: a bad network, firewall,
or wireless file can disconnect the router and require local recovery.

## Repository map

- `setup.sh` installs packages and applies encrypted DNS, ad blocking, firewall, and
  WireGuard settings on an OpenWrt router.
- `uci/` contains feature-oriented UCI batch overlays for network, firewall,
  wireless, DNS, adblock-fast, and WireGuard configuration.
- `uci/dns-over-https` contains the managed `https-dns-proxy` instances and
  coordinated dnsmasq settings.

## Environment and execution safety

- Repository checks run in the development container, but `setup.sh` must run
  only on the intended OpenWrt router as root. Never execute it in this workspace.
- Do not assume the container has OpenWrt tools such as `uci`, `apk`, `fw4`, or
  `/etc/init.d/*`. State clearly when validation must be completed on a router.
- Do not install missing tools into the development container. Use the available
  static checks and report any device-only validation that remains.
- Before changing `/etc/config/network`, `/etc/config/firewall`, or wireless
  settings on a router, require a backup and a recovery path through a local
  Ethernet or serial connection. Prefer staged files and rollback-capable apply
  procedures over direct remote replacement.
- Never run deployment commands against a router unless the user explicitly asks
  for deployment and identifies the target.

## Configuration invariants

- Keep network names aligned across the UCI feature overlays. Current VLAN interfaces
  are `pixel`, `pixelthings`, `pixelguest`, and `pixeliot`.
- Keep VLAN IDs, bridge devices, subnets, wireless `network` values, firewall
  zones, and forwarding endpoints consistent as one change.
- Every VLAN must have an explicit DHCP decision. The managed pools are declared
  in `uci/network`; preserve their named sections and documented ranges.
- Preserve the isolation policy documented in `uci/firewall`:
  Pixel can reach WAN and the other VLANs; Guest and Things can reach WAN
  but not other VLANs; IoT has no WAN forwarding. All restricted VLANs need only
  the explicitly allowed router services such as DNS and DHCP.
- Account for the target device's existing base configuration. The checked-in
  `network` file has no loopback, globals, WAN, or WAN6 sections, and the checked-in
  `firewall` file has no defaults or WAN zone. Do not present these files as safe
  full replacements unless those required sections are intentionally added and
  verified for the exact router model and OpenWrt release.
- Hardware port and radio names (`lan1` through `lan4`, `br-lan`, and `radio0`)
  are device-specific. Do not generalize them without target hardware evidence.
- Do not commit real Wi-Fi passwords, WireGuard private or preshared keys, tokens,
  or other secrets. Keep placeholders in tracked files and inject secrets only at
  deployment time. Avoid printing secret-bearing files or environment variables.
- Shell variables are not expanded merely by copying a UCI file. If templates are
  used, render them explicitly and verify that no literal `${...}` placeholder or
  extra quote remains before installation.
- Keep dnsmasq's upstream list identical to the named `https-dns-proxy` listen
  ports, and verify that the two daemons do not contend for the same ports.

## Editing `setup.sh`

- Write portable POSIX `sh` compatible with OpenWrt BusyBox `ash`; do not add Bash
  syntax.
- Add or retain a `#!/bin/sh` shebang. Quote expansions unless intentional word
  splitting is documented.
- Validate every required variable before the first mutation. The WireGuard block
  depends on `VPN_IF`, `VPN_PORT`, `VPN_KEY`, `VPN_ADDR`, `VPN_ADDR6`, `VPN_PUB`,
  and `VPN_PSK`; Wi-Fi rendering depends on the four password variables.
- Keep operations idempotent. Re-running the script must not append duplicate UCI
  rules, redirects, list entries, or sections.
- Resolve companion files relative to `setup.sh`, and reject a missing or empty
  repository file before the first router mutation.
- Deployment uses the current GitHub `main` source archive directly; there are no
  generated release artifacts to rebuild or publish after changing an overlay.
- Avoid unpinned remote installer execution. If an upstream installer must be
  used, pin a reviewed version or commit and document its provenance/checksum.
- Group related UCI mutations, commit once per package, and reload services only
  after successful validation. Preserve a rollback path for network and firewall
  changes.
- Address named UCI sections directly. Do not rename anonymous sections by index;
  section ordering is device- and configuration-dependent.

## Validation

Run the checks relevant to the files changed:

```sh
sh -n setup.sh
shellcheck -s sh setup.sh
shfmt -d -i 4 -ci setup.sh
git diff --check
```

On a disposable router or matching OpenWrt test target, validate staged UCI files
before replacing live configuration. After applying, inspect at least:

```sh
uci show network
uci show firewall
uci show wireless
fw4 check
uci show https-dns-proxy
logread -e netifd -e firewall -e https-dns-proxy
```

Confirm from a client in each VLAN that DHCP and DNS work, expected internet
access works, forbidden inter-VLAN routes remain blocked, and the management VLAN
can still reach the router. Verify WireGuard handshake and routing separately.
If a command is unavailable on the target OpenWrt release, report that fact and
use the release-appropriate equivalent rather than silently skipping the check.

## Change scope

- In the final report, list files changed, static checks run, checks that require
  real router hardware, and any lockout, secret-handling, or compatibility risk.
