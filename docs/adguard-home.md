# AdGuard Home DNS and ad-blocking module

Sources: [`modules/adguard-home.sh`](../modules/adguard-home.sh) and
[`uci/adguard-home`](../uci/adguard-home)

The module installs `adguardhome` and `luci-app-adguardhome`. The native
AdGuard Home dashboard is served with authentication at
`http://192.168.8.1:3000` and binds only to the Pixel gateway. The LuCI package
provides service integration; the full dashboard is served by AdGuard Home.

AdGuard Home is the primary resolver on TCP/UDP port 53 and binds to loopback,
the four managed VLAN gateway addresses, and the IPv4 host address derived from
`VPN_ADDR`. The WireGuard listener is rendered from the configured CIDR rather
than hard-coded. Dnsmasq moves to port 54, has no public upstreams or cache, and
remains responsible for DHCP, `.lan` names, and private PTR answers. AdGuard
routes `.lan` and private reverse queries to `127.0.0.1:54`. Every DHCP pool
explicitly advertises its own gateway as DNS. Firewall rules reject client
access to dnsmasq port 54, including from Pixel and its WireGuard member, so it
cannot bypass filtering.

The four existing encrypted upstreams are configured directly in AdGuard Home
in load-balancing mode:

- Quad9
- Cloudflare Security
- Control D Ads & Tracking
- Mullvad Base

Bootstrap DNS uses `9.9.9.11`, `1.1.1.1`, and `8.8.8.8`. AdGuard does not
provide incoming DoH, DoT, DoQ, or DNSCrypt. Existing firewall redirects force
all managed VLAN TCP/UDP port-53 traffic to the router. Direct DoT and standard
DoQ on TCP/UDP 853, plus alternate/legacy DoQ on UDP 784 and 8853, are rejected
to every routed destination rather than only to WAN.

AdGuard DNS, AdAway Default Blocklist, and HaGeZi DNS Rebind Protection are
enabled. The 23 non-duplicate adblock-fast sources are also enabled with fixed
IDs, including HaGeZi's Apple, Windows/Office, TikTok, and Threat Intelligence
Feeds lists. The former direct AdGuard DNS URL is omitted because it duplicates
the built-in AdGuard DNS filter. Filters refresh every 24 hours. When optional
`DNS_REBIND_DOMAIN` is set, the rendered user rule `@@||DOMAIN^` permits private
answers for that apex and its subdomains; the input is normalized to lowercase.
Blocked responses use `NXDOMAIN`, including private answers rejected by the
HaGeZi DNS Rebind Protection filter, instead of returning `0.0.0.0` or `::`.

Query logging is file-backed with a 5,000-entry memory buffer. Query-log and
statistics intervals are both `7d`. Data is stored persistently in
`/opt/adguardhome`; rotated query-log files may retain some records beyond the
nominal seven-day interval.

`ADGUARD_USERNAME` and a precomputed 60-character bcrypt
`ADGUARD_PASSWORD_HASH` are required. They are validated before package
installation, never printed, and rendered only into the mode-0600 candidate.
The installed YAML is `/etc/adguardhome/adguardhome.yaml`, owned by the native
`adguardhome` account. Candidate validation runs `AdGuardHome --check-config`.

Package installation is outside rollback. A fresh install leaves AdGuard Home
stopped and disabled until the candidate is applied and confirmed. The
transaction backs up the YAML, whether it existed, and the prior init-enable
state. Apply starts dnsmasq before AdGuard and requires TCP/UDP 53, TCP/UDP 54,
and TCP 3000 listeners. Confirmation enables AdGuard. Rollback restores the
prior YAML and enablement, and removes the YAML when it did not exist before.

## Manual migration of an existing OpenWrt router

Do not run `setup.sh` for this path: its stock-base preflight intentionally
rejects an already-configured router. Perform this only with an off-router
`sysupgrade -b` backup and verified local Ethernet or serial recovery.

1. Record `uci show dhcp`, `uci show firewall`, `uci show adblock-fast`, and
   `uci show https-dns-proxy`; copy `/etc/config`, `/etc/crontabs/root`, and any
   current DNS configuration off the router.
2. Generate a bcrypt dashboard password hash off-router. Export
   `ADGUARD_USERNAME`, `ADGUARD_PASSWORD_HASH`, and optional
   `DNS_REBIND_DOMAIN` without echoing them.
3. Install `adguardhome luci-app-adguardhome`. Immediately stop and disable
   AdGuard Home if package defaults started its setup wizard. Do not remove the
   old DNS packages yet.
4. Copy this reviewed repository to the router. In a mode-0700 staging
   directory, define a local `die()` helper, source `modules/adguard-home.sh`, run
   `adguard_home_inputs_preflight`, and call `adguard_home_render_config` to
   create a mode-0600 staged YAML. Validate it with
   `/usr/bin/AdGuardHome --check-config --config STAGED_YAML --no-check-update`.
5. Build staged UCI copies—not live edits—with dnsmasq port 54, cache 0,
   `noresolv=1`, no `server` entries, `.lan` local service, per-VLAN DHCP option
   6, the four port-53 redirects, destination-independent DoT/DoQ rejects, and
   port-54 bypass rejects.
   Configure `/etc/config/adguardhome` for the standard YAML path and
   `/opt/adguardhome` work directory. Run `fw4 check` against the candidate.
6. Create a local five-minute rollback job before cutover. It must stop AdGuard,
   restore every backed-up UCI file and the previous DNS services, restart
   dnsmasq and the previous resolver/adblock services, and disable AdGuard.
7. Stop AdGuard and dnsmasq. Atomically install the staged UCI files and YAML,
   preserving YAML mode `0600` and ownership `adguardhome:adguardhome`. Reload
   network and firewall, start dnsmasq, then start AdGuard Home.
8. From Pixel, every restricted VLAN, and a WireGuard peer, verify DHCP where
   applicable, ordinary DNS, local/PTR resolution, forced DNS using an arbitrary
   resolver address, DoT/DoQ blocking, and the existing isolation/internet
   policy. Verify port 54 is unreachable from clients, AdGuard owns TCP/UDP 53
   on the host address from `VPN_ADDR`, and the dashboard binds only to Pixel.
9. Enable AdGuard and cancel the rollback only after all checks pass. Keep the
   old packages installed but disabled until the router has operated normally
   through a reboot.
10. After the observation period, remove `https-dns-proxy`,
    `luci-app-https-dns-proxy`, `adblock-fast`, and `luci-app-adblock-fast`, and
    remove only their managed cron entry. Preserve unrelated root cron jobs.

The repository currently downloads the mutable GitHub `main` archive during
deployment. Review and pin a commit before using these instructions on a live
router.

[Back to the README](../README.md)
