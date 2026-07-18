# Encrypted DNS module

Sources: [`modules/dns-over-https.sh`](../modules/dns-over-https.sh),
[`uci/dns-over-https`](../uci/dns-over-https), and
[`configs/dnscrypt/dnscrypt-proxy.toml`](../configs/dnscrypt/dnscrypt-proxy.toml)

This module installs and enables `dnscrypt-proxy2`, then makes these coordinated
configuration changes:

- dnsmasq ignores resolv.conf, disables its cache, and forwards to
  `127.0.0.53#53`.
- DNSCrypt listens on the matching `127.0.0.53:53`, requires DNSSEC, and selects
  the configured Quad9, Cloudflare, Control D, and Mullvad resolvers.
- WAN and WAN6 stop accepting peer-provided DNS servers.
- The system NTP server list is replaced with fixed IP addresses so time can be
  established without depending on DNS.
- Firewall rules DNAT WAN port 53 to LAN port 53, DNAT LAN port 5353 to port 53,
  and reject LAN-to-WAN DNS-over-TLS on TCP port 853.

Candidate validation runs DNSCrypt's configuration check and verifies that its
listening endpoint exactly matches dnsmasq's upstream. The module changes the
`dhcp`, `system`, `network`, and `firewall` UCI packages as one transaction and
installs the DNSCrypt TOML alongside them.

[Back to the README](../README.md)
