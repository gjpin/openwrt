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
  `ntppool1.time.nl`) with `iburst` and `nts`.
- Keeps four plain NTP-by-IP bootstrap sources so the clock can be set without
  DNS before DoH TLS is available.
- Disables DHCP-provided NTP sources and omits the stock openwrt pool and LAN
  `allow` sections (client-only; the router does not serve NTP).
- Keeps `makestep` and the chrony `nts` section with `rtccheck` and
  `systemcerts`. On devices without `/dev/rtc0`, OpenWrt's chrony init emits
  `nocerttimecheck 1` so NTS-KE can proceed with a cold clock.

NTS authenticates NTP (integrity and authenticity). It does not encrypt the
time payload itself; it is still the OpenWrt-supported secure NTP path.

Candidate validation requires the three NTS servers, four bootstrap servers,
disabled DHCP NTP, makestep/nts options, and no pool or allow sections. The
module changes only the `chrony` UCI package inside the transaction.

After apply, useful checks are `uci show chrony`, `chronyc tracking`, and
`chronyc -N authdata` (NTS sources should report mode `NTS`).

[Back to the README](../README.md)
