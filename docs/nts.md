# Encrypted NTP (NTS) module

Sources: [`modules/nts.sh`](../modules/nts.sh) and [`uci/nts`](../uci/nts)

This module replaces BusyBox
[`sysntpd`](https://openwrt.org/docs/guide-user/services/ntp/client-server)
with OpenWrt's [`chrony-nts`](https://openwrt.org/packages/pkgdata/chrony-nts)
package so the router can authenticate NTP with Network Time Security (NTS).
Plain `chrony` is built without NTS; install `chrony-nts` instead.

It makes these coordinated changes:

- Installs `chrony-nts`, disables `sysntpd`, and enables `chronyd`.
- Configures named NTS servers (`time.cloudflare.com`, `nts.netnod.se`,
  `ntppool1.time.nl`) with `iburst`, `nts`, and `prefer`.
- Keeps four plain NTP-by-IP bootstrap sources so the clock can be set without
  DNS before DoH TLS is available. These sources are not preferred, but remain
  eligible whenever the preferred NTS sources are unavailable.
- Adds `authselectmode ignore` immediately before the package's
  `confdir /var/etc/chrony.d` line. Chrony 4.8 otherwise defaults to `mix`,
  which effectively requires and trusts authenticated sources and prevents the
  unauthenticated bootstrap sources from selecting independently.
- Disables DHCP-provided NTP sources and omits the stock openwrt pool and LAN
  `allow` sections (client-only; the router does not serve NTP).
- Keeps `makestep` and the chrony `nts` section with `rtccheck` and
  `systemcerts`. On devices without `/dev/rtc0`, OpenWrt's chrony init emits
  `nocerttimecheck 1` so NTS-KE can proceed with a cold clock.

NTS authenticates NTP (integrity and authenticity). It does not encrypt the
time payload itself; it is still the OpenWrt-supported secure NTP path.
`authselectmode ignore` is an intentional availability tradeoff: the router
accepts unauthenticated time during cold-boot bootstrap and whenever all
preferred NTS sources are unavailable. Once NTS sources are usable, `prefer`
makes them win selection.

Candidate validation requires the three NTS servers, four bootstrap servers,
disabled DHCP NTP, makestep/nts options, no pool or allow sections, preference
only on NTS sources, and one correctly ordered authentication-selection
directive. Before creating a transaction, prepare rejects a missing or empty
main configuration, missing or ambiguous generated-config `confdir`, duplicate
authentication directives, or a conflicting authentication mode.

The confirmed transaction backs up, checksums, installs, and restores
`/etc/chrony/chrony.conf` together with UCI and `modules.conf`. Transaction
copies remain mode `0600`; the installed package-compatible mode is `0644`.
OpenWrt's init script still generates `/var/etc/chrony.d/10-uci.conf` from UCI.

After apply, inspect `/etc/chrony/chrony.conf`,
`/var/etc/chrony.d/10-uci.conf`, `uci show chrony`, `chronyc tracking`,
`chronyc -n selectdata -a`, and `chronyc -N authdata -a` (NTS sources should
report mode `NTS`). A physical cold-boot acceptance test should start from a
genuinely bad clock with DNS unavailable, prove a numeric source steps it, then
restore DNS/DoH and prove NTS authentication.

[Back to the README](../README.md)
