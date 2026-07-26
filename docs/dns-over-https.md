# Encrypted DNS module

Sources: [`modules/dns-over-https.sh`](../modules/dns-over-https.sh) and
[`uci/dns-over-https`](../uci/dns-over-https)

This module installs and enables `https-dns-proxy` and its LuCI application,
then makes these coordinated configuration changes:

- dnsmasq ignores resolv.conf, uses an 8,192-entry
  [`cachesize`](https://openwrt.org/docs/guide-user/base-system/dhcp)
  (OpenWrt UCI → dnsmasq `-c`), and forwards to four local proxy instances on
  `127.0.0.1` ports 5053 through 5056.
- dnsmasq rebind protection remains enabled. When the optional
  `DNS_REBIND_DOMAIN` environment variable contains one ASCII apex domain,
  dnsmasq permits private answers for that domain and all its subdomains.
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
one. Preferred NTS sources are primary. Chrony's explicit
`authselectmode ignore` policy lets non-preferred, plain NTP-by-IP sources cover
cold boot before DNS is available and remain a fallback when NTS is
unavailable; that fallback time is unauthenticated.

Candidate validation requires exactly the four named proxy instances, their
expected URLs, unique ports, bootstrap values, and matching dnsmasq forwards.
`DNS_REBIND_DOMAIN` accepts at least two valid DNS labels and is normalized to
lowercase; internationalized domains must be supplied in punycode. Do not add a
wildcard: `mydomain.com` already covers its subdomains, so
`*.mydomain.com` is rejected.

The exception is additive. Changing `DNS_REBIND_DOMAIN` adds the new domain
while retaining older and unrelated rebind exceptions. Leaving it unset or
empty does not change or remove any existing exceptions.

The module changes the `https-dns-proxy`, `dhcp`, `network`, and `firewall`
UCI packages as one transaction.

[Back to the README](../README.md)
