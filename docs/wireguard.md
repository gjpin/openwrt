# WireGuard module

Sources: [`modules/wireguard.sh`](../modules/wireguard.sh) and
[`uci/wireguard`](../uci/wireguard)

This module installs WireGuard tools and LuCI protocol support, then creates:

- A server interface named by `VPN_IF`, listening on UDP `VPN_PORT` with the
  IPv4 and IPv6 addresses in `VPN_ADDR` and `VPN_ADDR6`.
- One peer named `wgclient`, using `VPN_PUB` and `VPN_PSK`.
- Peer routes for client address `.2/32` in the configured IPv4 subnet and
  `:2/128` in the configured IPv6 prefix.
- A WAN firewall rule allowing the configured UDP port.
- Membership of the server interface in the trusted `pixel` firewall zone.

The server private key (`VPN_KEY`) and peer preshared key (`VPN_PSK`) are
injected directly into the mode-0600 candidate. The rendered overlay is checked
for unresolved placeholders before installation.

The current configuration describes a server and a single peer; it does not
generate a client configuration or configure an endpoint on the client.

[Back to the README](../README.md)
