# WireGuard module

Sources: [`modules/wireguard.sh`](../modules/wireguard.sh) and
[`uci/wireguard`](../uci/wireguard)

This module installs WireGuard tools and LuCI protocol support, then creates:

- An IPv4-only server interface named by `VPN_IF`, listening on UDP `VPN_PORT`
  with the address in `VPN_ADDR`.
- A WAN firewall rule allowing the configured UDP port.
- Membership of the server interface in the trusted `pixel` firewall zone.

The Pixel zone accepts intra-zone forwarding, so physical Pixel clients and
WireGuard peers are mutually trusted and can route to each other. WireGuard
peers can also route peer-to-peer when their allowed IPs are configured
accordingly.

The server private key (`VPN_KEY`) is injected directly into the mode-0600
candidate. The rendered overlay is checked for unresolved placeholders before
installation.

Setup creates no client peers. Add each peer separately, including its public
key, allowed IPs, and optional preshared key, before testing a handshake or
client routing.

`VPN_ADDR` must not overlap WAN (`192.168.2.0/24`) or the managed VLAN subnets
(`192.168.8`–`11.0/24`). Because WAN sits behind the ISP router, inbound peers
need an ISP-router UDP port forward to `192.168.2.2` for `VPN_PORT`.

[Back to the README](../README.md)
