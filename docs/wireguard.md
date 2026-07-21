# WireGuard module

Sources: [`modules/wireguard.sh`](../modules/wireguard.sh) and
[`uci/wireguard`](../uci/wireguard)

This module installs WireGuard tools and LuCI protocol support, then creates:

- An IPv4-only server interface named by `VPN_IF`, listening on UDP `VPN_PORT`
  with the address in `VPN_ADDR`.
- One peer named `wgclient`, using `VPN_PUB` and `VPN_PSK`.
- A peer route for client address `.2/32` in the configured IPv4 subnet.
- A WAN firewall rule allowing the configured UDP port.
- Membership of the server interface in the trusted `pixel` firewall zone.

The server private key (`VPN_KEY`) and peer preshared key (`VPN_PSK`) are
injected directly into the mode-0600 candidate. The rendered overlay is checked
for unresolved placeholders before installation.

`VPN_ADDR` must not overlap WAN (`192.168.1.0/24`) or the managed VLAN subnets
(`192.168.8`–`11.0/24`). Because WAN sits behind the ISP router, inbound peers
need an ISP-router UDP port forward to `192.168.1.2` for `VPN_PORT`.

The current configuration describes a server and a single peer; it does not
generate a client configuration or configure an endpoint on the client.

[Back to the README](../README.md)
