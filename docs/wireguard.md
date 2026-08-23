# WireGuard module

Sources: [`modules/wireguard.sh`](../modules/wireguard.sh) and
[`uci/wireguard`](../uci/wireguard)

This module installs WireGuard tools and LuCI protocol support, then creates:

- An IPv4-only server interface named by `VPN_IF`, listening on UDP `VPN_PORT`
  with the address in `VPN_ADDR`.
- A WAN firewall rule allowing the configured UDP port.
- Membership of the server interface in the trusted `pixel` firewall zone.
- AdGuard Home TCP/UDP DNS on the IPv4 host address derived from `VPN_ADDR`.

The Pixel zone accepts intra-zone forwarding, so physical Pixel clients and
WireGuard peers are mutually trusted and can route to each other. WireGuard
peers can also route peer-to-peer when their allowed IPs are configured
accordingly. They inherit the Pixel zone's DNS interception policy: queries sent
directly to the WireGuard server address, and intercepted port-53 queries aimed
at other resolver addresses, terminate at AdGuard Home. Direct access to
dnsmasq on port 54 is rejected.

The server private key (`VPN_KEY`) is injected directly into the mode-0600
candidate. The rendered overlay is checked for unresolved placeholders before
installation.

Setup creates no client peers. Add each peer separately, including its public
key, allowed IPs, and optional preshared key, before testing a handshake or
client routing. Also verify a DNS query to the host address from `VPN_ADDR`, a
forced query to a different port-53 address covered by the peer's `AllowedIPs`,
and failure when querying the WireGuard server on port 54.

`VPN_ADDR` must not overlap WAN (`192.168.2.0/24`) or the managed VLAN subnets
(`192.168.8`–`11.0/24`). Because WAN sits behind the ISP router, inbound peers
need an ISP-router UDP port forward to `192.168.2.2` for `VPN_PORT`.

[Back to the README](../README.md)
