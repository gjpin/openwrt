# AGENTS.md

## Purpose

This repository stores a device-specific OpenWrt configuration and a
provisioning flow for a GL.iNet GL-MT6000 on upstream OpenWrt 25.12. Treat
changes as router infrastructure: a bad network, firewall, or wireless
candidate can disconnect the router and require local recovery.

## Repository map

- `setup.sh` is the router entrypoint. It validates secrets and the repository,
  rejects unsupported stock bases, installs packages, then runs a confirmed
  UCI transaction. It requires `--recovery-ready` and must run only on the
  target router as root.
- `router-config.sh` is the transaction manager: `check-base`, `prepare`,
  `apply`, `confirm`, and `rollback`. At prepare time it installs itself to
  `/usr/libexec/router-config` plus an early-boot rollback init script.
- `router-config-rollback.init` becomes `/etc/init.d/router-config-rollback`
  (`START=05`) and restores any still-pending transaction before normal
  networking starts.
- `modules/` holds internal shell modules sourced by `setup.sh` or
  `router-config.sh`. They are not standalone commands. Fixed order matters:
  base packages (setup only), then during prepare staging: network, firewall,
  wireless, admin-access, attendedsysupgrade, nts, AdGuard Home, wireguard. Package
  install callbacks for NTS, AdGuard Home, and WireGuard run from `setup.sh`
  before prepare.
- `uci/` holds feature-oriented UCI batch overlays applied onto a copy of the
  live config inside a candidate directory. They are not full replacements for
  `/etc/config/*`.
- `docs/` documents each module. Prefer those docs over inventing behavior.
- `tests/` and `tools/` provide simulated-router Python tests, a pinned QEMU
  OpenWrt VM suite, and an ImageBuilder flash/package gate. CI lives in
  `.github/workflows/test.yml`.

## Transaction model

UCI changes are built and applied as one candidate, together with managed
`/etc/modules.conf` for Wireless Ethernet Dispatch (WED) and
`/etc/chrony/chrony.conf` for Chrony source selection, and
`/etc/adguardhome/adguardhome.yaml` for DNS:

1. `prepare --recovery-ready` copies live UCI into
   `/root/router-config-backups/<id>/backup` and `candidate`, copies
   `/etc/modules.conf` (or an empty stand-in) and the package-owned main Chrony
   configuration the same way, applies overlays to the candidate only, injects
   secrets into the mode-0600 candidate, validates, writes `manifest.sha256`,
   and installs runtime helpers.
2. `apply <id>` verifies the manifest, marks the transaction pending, installs
   the candidate into `/etc/config`, `/etc/modules.conf`, and
   `/etc/chrony/chrony.conf`, plus the AdGuard Home YAML, runs `fw4 check`,
   reloads services, starts a five-minute watchdog, and waits for confirmation.
3. `confirm <id>` from a second local/recovery-capable session clears pending
   and keeps the change. Without confirmation, the watchdog restores the
   backup. A reboot with a pending file triggers early-boot recovery.
   Reboot after confirm for WED (`mt7915e wed_enable`) to load; do not reboot
   while pending.

Package installation and most init-service enablement happen before the
protected transaction and are not removed by rollback. AdGuard Home is the
exception: its prior enablement is backed up, it is enabled only on confirm,
and rollback restores the prior state. Prefer this prepare/apply/confirm path
over direct remote replacement of live config files.

## Environment and execution safety

- Never run `setup.sh` or `router-config.sh` against a real router from this
  workspace unless the user explicitly asks for deployment and names the
  target. Never run them as a workstation install.
- Do not assume the development environment has OpenWrt tools such as `uci`,
  `apk`, `fw4`, or `/etc/init.d/*`. Use the repository test harnesses and
  static checks here; state clearly when validation must finish on a router or
  in the QEMU suite.
- Do not install missing OpenWrt tools into the development environment to make
  scripts “run locally.”
- Before any router deployment, require an off-router `sysupgrade -b` backup and
  a verified local Ethernet or serial recovery path. Setup refuses to start
  without `--recovery-ready`.
- Deployment currently downloads the mutable GitHub `main` source archive.
  There are no generated release artifacts. Call out that lack of pin when
  changing deploy docs or install steps. Prefer reviewed pins for any new
  remote installer.

## Configuration invariants

- Keep network names aligned across overlays and modules. Current VLAN
  interfaces are `pixel`, `pixelguest`, `pixeliot`, and `pixelthings`.
- Pin addressing as one change: static WAN `192.168.2.2/24` with gateway
  `192.168.2.1` (ISP router LAN), and managed VLANs `pixel` `192.168.8.1/24`,
  `pixelguest` `192.168.9.1/24`, `pixeliot` `192.168.10.1/24`, and
  `pixelthings` `192.168.11.1/24`. This is double NAT behind the ISP router;
  inbound WireGuard needs an ISP port forward to `192.168.2.2` for `VPN_PORT`.
  Keep `VPN_ADDR` off the WAN and managed VLAN subnets.
- Keep VLAN IDs, bridge-VLAN ports, subnets, wireless `network` values,
  firewall zones, forwarding, and DNS divert rules consistent as one change.
  Keep per-VLAN reject-to-WAN rules for DoT (`dest_port=853`, `tcp udp`) and
  DoQ (`dest_port=8853`, `udp`) in the encrypted-DNS overlay
  (`uci/adguard-home`).
- Every VLAN must have an explicit DHCP decision. Managed pools live in
  `uci/network`; preserve named sections and documented ranges.
- Preserve the isolation policy in `uci/firewall` / `docs/firewall.md`: Pixel
  can reach WAN and the other VLANs; Guest and Things can reach WAN but not
  other VLANs; IoT has no WAN forwarding and rejects general zone output.
  Restricted VLANs allow only explicitly permitted router services (DNS/DHCP),
  plus the IoT DHCP-reply exception.
- Bind LuCI and SSH to Pixel only via `uci/admin-access` /
  `docs/admin-access.md`: uhttpd listens on `192.168.8.1:80` and
  `192.168.8.1:443` only; Dropbear uses `DirectInterface=pixel` (not the
  legacy IP-only `Interface` option). Restricted-VLAN firewall input remains
  complementary defense; do not leave stock wildcard listeners on Guest/IoT/
  Things gateway addresses.
- Keep Wi-Fi client isolation (`wifi-iface.isolate=1`) on Guest, IoT, and
  Things only; leave Pixel unisolated so trusted stations can talk L2. This is
  OpenWrt's AP-mode isolate option (hostapd `ap_isolate`), distinct from
  firewall VLAN isolation.
- Enable software and hardware flow offloading on `firewall.defaults`
  (`flow_offloading=1`, `flow_offloading_hw=1`). Keep SQM disabled while this
  offload policy is in use; do not install or enable SQM.
- Enable WED with exactly one `options mt7915e wed_enable=Y` line in the
  managed `/etc/modules.conf` candidate. Reboot only after confirm for WED to
  load. WED bypasses AQL; do not treat AQL tuning as compatible with WED.
- WAN and managed VLANs are IPv4-only. Do not reintroduce IPv6 delegation, RA,
  DHCPv6, NDP, `wan6`, or ULA unless that is an intentional, tested change.
- Fresh setup creates the IPv4 WireGuard server with no client peers. Add a
  peer separately before testing a handshake or client routing; do not restore
  an installer-managed default peer.
- Overlays update an existing stock configuration. Checked-in `uci/network` has
  no loopback or globals sections and does not create `network.wan`; it pins
  WAN addressing on the stock section. Checked-in `uci/firewall` has no
  defaults or WAN zone. Do not present overlays as safe full replacements.
  Stock-base preflight still expects fresh OpenWrt `network.lan` at
  `192.168.1.1` before migration; that is not the managed `pixel` subnet
  (`192.168.8.1`). Do not “fix” the stock LAN preflight to `192.168.8.1`.
  Keep the ISP transit on `192.168.2.0/24` so it does not overlap that stock
  LAN during package installation. Apply WAN and VLAN renumbering together.
- Target hardware expectations are device-specific: DSA ports `lan1` through
  `lan5`, `br-lan`, and exactly one `2g` plus one `5g` `wifi-device`. Do not
  generalize without target evidence. Preflight rejects customized or ambiguous
  stock base sections rather than guessing. Audit every stock-base preflight
  assumption against the pinned official OpenWrt 25.12.4 runtime, the selected
  package payloads, and the GL-MT6000 target-generation scripts; keep the
  preflight consistent with all three.
- Do not commit real Wi-Fi passwords, WireGuard private or preshared keys,
  tokens, or other secrets. Keep placeholders in tracked templates; inject
  secrets only into the candidate at prepare time. Never print secret-bearing
  values, files, or environment variables.
- Shell variables are not expanded by copying a UCI file. WireGuard rendering
  must happen explicitly; reject any leftover `${...}` placeholder before
  install.
- Keep AdGuard Home primary on port 53 and dnsmasq on port 54 with no public
  dnsmasq upstreams or cache. AdGuard must route `.lan` and private PTR queries
  to dnsmasq. Preserve per-VLAN DHCP option 6, port-53 interception, port-54
  bypass rejects, and the DoT/DoQ rejects as one transaction.
- Use `chrony-nts` (not plain `chrony`) for time sync. Disable BusyBox
  `sysntpd` so only one NTP client runs. Keep NTS servers primary and retain
  plain NTP-by-IP chrony sources for cold-boot bootstrap before encrypted DNS TLS.
  Set `authselectmode ignore` immediately before
  `confdir /var/etc/chrony.d` in the main Chrony configuration so plain sources
  can synchronize independently; mark every NTS source `prefer` and no
  bootstrap source preferred. This deliberately permits unauthenticated time
  whenever preferred NTS sources are unavailable. Keep chrony client-only (no
  pool, no LAN `allow`, DHCP NTP disabled).

## Editing shell and modules

- Write portable POSIX `sh` for OpenWrt BusyBox `ash`; no Bash syntax.
- Keep `#!/bin/sh` shebangs. Quote expansions unless intentional word splitting
  is documented (and shellcheck-justified).
- Validate every required variable before the first router mutation. Required
  secrets/settings are `PIXEL_WIFI_PASSWORD`, `THINGS_WIFI_PASSWORD`,
  `GUEST_WIFI_PASSWORD`, `IOT_WIFI_PASSWORD`, `COUNTRY`, `VPN_IF`, `VPN_PORT`,
  `VPN_KEY`, `VPN_ADDR`, `ADGUARD_USERNAME`, and `ADGUARD_PASSWORD_HASH`. There
  is no `VPN_ADDR6`; `DNS_REBIND_DOMAIN` remains optional.
  `COUNTRY` is a required two-letter ISO code with no default. Optional
  `CHANNEL` defaults to `36` (5 GHz non-DFS); the wireless module also forces
  5 GHz `htmode=HE80`.
- Keep operations idempotent. Re-running prepare/apply must not append
  duplicate UCI rules, redirects, list entries, sections, or `modules.conf`
  WED option lines.
- Resolve companion files relative to the script directory, and reject a
  missing or empty repository file before the first mutation.
- Address named UCI sections directly. Do not rename anonymous stock sections
  by index on the live router; naming happens only inside the candidate when
  content uniquely identifies a stock role.
- Group related candidate mutations per module, validate before apply, and
  reload services only after a successful candidate install and `fw4 check`.

## Validation

Run the checks relevant to the files changed.

Static shell and tree checks:

```sh
sh -n setup.sh router-config.sh router-config-rollback.init modules/*.sh tools/vm/*.sh
shellcheck -s sh setup.sh router-config.sh router-config-rollback.init modules/*.sh tools/vm/*.sh
shfmt -d -i 4 -ci setup.sh router-config.sh router-config-rollback.init modules/*.sh tools/vm/*.sh
git diff --check
```

Simulated-router integration tests (no real router):

```sh
python tools/run-tests.py
```

Pinned QEMU acceptance suite (OpenWrt userland, UCI, fw4, services, VLAN
clients, DNS, WireGuard, idempotency, rollback). Does not emulate switch ASICs,
RF, or eMMC recovery:

```sh
python3 tools/run-vm-tests.py --profile stable
```

Exact target ImageBuilder package/flash-fit gate (Linux x86_64 CI/host):

```sh
python3 tools/check-imagebuilder.py
```

On a disposable router or after a real apply, inspect at least:

```sh
uci show network
uci show firewall
uci show wireless
fw4 check
uci get firewall.defaults.flow_offloading
uci get firewall.defaults.flow_offloading_hw
grep -x 'options mt7915e wed_enable=Y' /etc/modules.conf
grep -B1 -x 'confdir /var/etc/chrony.d' /etc/chrony/chrony.conf
uci show adguardhome
grep -E '^(http:|dns:|filters:|querylog:|statistics:)' /etc/adguardhome/adguardhome.yaml
uci show chrony
uci show uhttpd | grep listen_
uci show dropbear
chronyc tracking
chronyc -n selectdata -a
chronyc -N authdata
/etc/init.d/sysntpd enabled >/dev/null 2>&1 && echo 'sysntpd still enabled'
logread -e netifd -e firewall -e adguardhome -e dnsmasq -e chronyd -e uhttpd -e dropbear
```

Confirm from a client in each VLAN that DHCP and DNS work, expected internet
access works, forbidden inter-VLAN routes remain blocked, and the management
VLAN can still reach the router (LuCI/SSH only on `192.168.8.1` / Pixel).
Verify Guest/IoT/Things cannot open TCP to their own gateway on ports 22, 80,
or 443. Verify WireGuard handshake and routing separately. After confirm and
reboot, verify WED with
`cat /sys/module/mt7915e/parameters/wed_enable` (expect `Y`). If a command is
unavailable on the target OpenWrt release, report that and use the
release-appropriate equivalent rather than skipping silently.

## Change scope

In the final report, list files changed, static checks and automated suites
run, checks that still require real router hardware, and any lockout,
secret-handling, package-vs-UCI rollback, or compatibility risk.
