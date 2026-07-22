# Encrypted DNS module

Sources: [`modules/dns-over-https.sh`](../modules/dns-over-https.sh) and
[`uci/dns-over-https`](../uci/dns-over-https)

This module installs and enables `https-dns-proxy` and its LuCI application,
then makes these coordinated configuration changes:

- dnsmasq ignores resolv.conf, uses an 8,192-entry
  [`cachesize`](https://openwrt.org/docs/guide-user/base-system/dhcp)
  (OpenWrt UCI → dnsmasq `-c`), and forwards to four local proxy instances on
  `127.0.0.1` ports 5053 through 5056.
- The named Quad9, Cloudflare Security, Control D Ads & Tracking, and Mullvad
  Base instances use the same IPv4 bootstrap list.
- `https-dns-proxy` is prevented from changing dnsmasq or firewall state on
  service start and stop; those settings remain transaction-managed.
- WAN stops accepting peer-provided DNS servers.
- Explicit
  [`firewall` rules](https://openwrt.org/docs/guide-user/firewall/firewall_configuration)
  for `pixel`, `pixelguest`, `pixelthings`, and `pixeliot` intercept TCP/UDP
  port 53, reject direct TCP/UDP DNS-over-TLS on port 853, and reject
  DNS-over-QUIC on UDP port 8853. RFC DoQ on UDP/853 is already covered by the
  DoT reject rules.

Time sync is handled by the [Encrypted NTP (NTS)](nts.md) module, not this
one. NTS is primary; plain NTP-by-IP bootstrap in chrony still covers cold boot
before DNS is available.

Candidate validation requires exactly the four named proxy instances, their
expected URLs, unique ports, bootstrap values, and matching dnsmasq forwards.
The module changes the `https-dns-proxy`, `dhcp`, `network`, and `firewall`
UCI packages as one transaction.

[Back to the README](../README.md)
