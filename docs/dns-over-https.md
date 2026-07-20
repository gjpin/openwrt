# Encrypted DNS module

Sources: [`modules/dns-over-https.sh`](../modules/dns-over-https.sh) and
[`uci/dns-over-https`](../uci/dns-over-https)

This module installs and enables `https-dns-proxy` and its LuCI application,
then makes these coordinated configuration changes:

- dnsmasq ignores resolv.conf, uses a 4,096-entry cache, and forwards to four
  local proxy instances on `127.0.0.1` ports 5053 through 5056.
- The named Quad9, Cloudflare Security, Control D Ads & Tracking, and Mullvad
  Base instances use the same IPv4 bootstrap list.
- `https-dns-proxy` is prevented from changing dnsmasq or firewall state on
  service start and stop; those settings remain transaction-managed.
- WAN stops accepting peer-provided DNS servers.
- The system NTP server list is replaced with fixed IP addresses so time can be
  established without depending on DNS.
- Explicit rules for `pixel`, `pixelguest`, `pixelthings`, and `pixeliot`
  intercept TCP/UDP port 53 and reject direct TCP/UDP DNS-over-TLS on port 853.

Candidate validation requires exactly the four named proxy instances, their
expected URLs, unique ports, bootstrap values, and matching dnsmasq forwards.
The module changes the `https-dns-proxy`, `dhcp`, `system`, `network`, and
`firewall` UCI packages as one transaction.

[Back to the README](../README.md)
