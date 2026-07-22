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
  wireless, dns-over-https, adblock-fast, wireguard. Package install callbacks
  for DNS, adblock, and WireGuard run from `setup.sh` before prepare.
- `uci/` holds feature-oriented UCI batch overlays applied onto a copy of the
  live config inside a candidate directory. They are not full replacements for
  `/etc/config/*`.
- `docs/` documents each module. Prefer those docs over inventing behavior.
- `tests/` and `tools/` provide simulated-router Python tests, a pinned QEMU
  OpenWrt VM suite, and an ImageBuilder flash/package gate. CI lives in
  `.github/workflows/test.yml`.

## Transaction model

UCI changes are built and applied as one candidate, together with a managed
`/etc/modules.conf` for Wireless Ethernet Dispatch (WED):

1. `prepare --recovery-ready` copies live UCI into
   `/root/router-config-backups/<id>/backup` and `candidate`, copies
   `/etc/modules.conf` (or an empty stand-in) the same way, applies overlays
   to the candidate only, injects secrets into the mode-0600 candidate,
   validates, writes `manifest.sha256`, and installs runtime helpers.
2. `apply <id>` verifies the manifest, marks the transaction pending, installs
   the candidate into `/etc/config` and `/etc/modules.conf`, runs `fw4 check`,
   reloads services, starts a five-minute watchdog, and waits for confirmation.
3. `confirm <id>` from a second local/recovery-capable session clears pending
   and keeps the change. Without confirmation, the watchdog restores the
   backup. A reboot with a pending file triggers early-boot recovery.
   Reboot after confirm for WED (`mt7915e wed_enable`) to load; do not reboot
   while pending.

Package installation and init-service enablement happen before the protected
transaction and are not removed by rollback. Prefer this prepare/apply/confirm
path over direct remote replacement of live config files.

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
- Pin addressing as one change: static WAN `192.168.1.2/24` with gateway
  `192.168.1.1` (ISP router LAN), and managed VLANs `pixel` `192.168.8.1/24`,
  `pixelguest` `192.168.9.1/24`, `pixeliot` `192.168.10.1/24`, and
  `pixelthings` `192.168.11.1/24`. This is double NAT behind the ISP router;
  inbound WireGuard needs an ISP port forward to `192.168.1.2` for `VPN_PORT`.
  Keep `VPN_ADDR` off the WAN and managed VLAN subnets.
- Keep VLAN IDs, bridge-VLAN ports, subnets, wireless `network` values,
  firewall zones, forwarding, and DNS divert rules consistent as one change.
- Every VLAN must have an explicit DHCP decision. Managed pools live in
  `uci/network`; preserve named sections and documented ranges.
- Preserve the isolation policy in `uci/firewall` / `docs/firewall.md`: Pixel
  can reach WAN and the other VLANs; Guest and Things can reach WAN but not
  other VLANs; IoT has no WAN forwarding and rejects general zone output.
  Restricted VLANs allow only explicitly permitted router services (DNS/DHCP),
  plus the IoT DHCP-reply exception.
- Enable software and hardware flow offloading on `firewall.defaults`
  (`flow_offloading=1`, `flow_offloading_hw=1`). Keep SQM disabled while this
  offload policy is in use; do not install or enable SQM.
- Enable WED with exactly one `options mt7915e wed_enable=Y` line in the
  managed `/etc/modules.conf` candidate. Reboot only after confirm for WED to
  load. WED bypasses AQL; do not treat AQL tuning as compatible with WED.
- WAN and managed VLANs are IPv4-only. Do not reintroduce IPv6 delegation, RA,
  DHCPv6, NDP, `wan6`, or ULA unless that is an intentional, tested change.
- Overlays update an existing stock configuration. Checked-in `uci/network` has
  no loopback or globals sections and does not create `network.wan`; it pins
  WAN addressing on the stock section. Checked-in `uci/firewall` has no
  defaults or WAN zone. Do not present overlays as safe full replacements.
  Stock-base preflight still expects fresh OpenWrt `network.lan` at
  `192.168.1.1` before migration; that is not the managed `pixel` subnet
  (`192.168.8.1`). Do not “fix” the stock LAN preflight to `192.168.8.1`.
  Apply WAN and VLAN renumbering together; do not leave live WAN on
  `192.168.1.2` while stock LAN remains `192.168.1.1`.
- Target hardware expectations are device-specific: DSA ports `lan1` through
  `lan5`, `br-lan`, and exactly one `2g` plus one `5g` `wifi-device`. Do not
  generalize without target evidence. Preflight rejects customized or ambiguous
  stock base sections rather than guessing.
- Do not commit real Wi-Fi passwords, WireGuard private or preshared keys,
  tokens, or other secrets. Keep placeholders in tracked templates; inject
  secrets only into the candidate at prepare time. Never print secret-bearing
  values, files, or environment variables.
- Shell variables are not expanded by copying a UCI file. WireGuard rendering
  must happen explicitly; reject any leftover `${...}` placeholder before
  install.
- Keep dnsmasq's upstream list identical to the named `https-dns-proxy` listen
  ports, and keep the two daemons from contending for the same ports.
  `https-dns-proxy` must not mutate dnsmasq or firewall outside the
  transaction (`dnsmasq_config_update='-'`, `force_dns='0'`, `notrack_dns='0'`).

## Editing shell and modules

- Write portable POSIX `sh` for OpenWrt BusyBox `ash`; no Bash syntax.
- Keep `#!/bin/sh` shebangs. Quote expansions unless intentional word splitting
  is documented (and shellcheck-justified).
- Validate every required variable before the first router mutation. Required
  secrets/settings are `PIXEL_WIFI_PASSWORD`, `THINGS_WIFI_PASSWORD`,
  `GUEST_WIFI_PASSWORD`, `IOT_WIFI_PASSWORD`, `COUNTRY`, `VPN_IF`, `VPN_PORT`,
  `VPN_KEY`, `VPN_ADDR`, `VPN_PUB`, and `VPN_PSK`. There is no `VPN_ADDR6`.
  `COUNTRY` is a required two-letter ISO code with no default.
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
uci show https-dns-proxy
logread -e netifd -e firewall -e https-dns-proxy
```

Confirm from a client in each VLAN that DHCP and DNS work, expected internet
access works, forbidden inter-VLAN routes remain blocked, and the management
VLAN can still reach the router. Verify WireGuard handshake and routing
separately. After confirm and reboot, verify WED with
`cat /sys/module/mt7915e/parameters/wed_enable` (expect `Y`). If a command is
unavailable on the target OpenWrt release, report that and use the
release-appropriate equivalent rather than skipping silently.

## Change scope

In the final report, list files changed, static checks and automated suites
run, checks that still require real router hardware, and any lockout,
secret-handling, package-vs-UCI rollback, or compatibility risk.
