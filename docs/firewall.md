# Firewall module

Sources: [`modules/firewall.sh`](../modules/firewall.sh) and
[`uci/firewall`](../uci/firewall)

This module creates one firewall zone per managed VLAN. Routing is allowlisted:

| Source | WAN | Pixel | Guest | IoT | Things |
|---|---:|---:|---:|---:|---:|
| Pixel | Allow | — | Allow | Allow | Allow |
| Guest | Allow | Block | — | Block | Block |
| IoT | Block | Block | Block | — | Block |
| Things | Allow | Block | Block | Block | — |

Pixel accepts access to services on the router. Guest, IoT, and Things reject
other router input but explicitly allow DNS and DHCP on TCP/UDP ports 53, 67,
and 68. IoT also rejects general zone output, with a narrow UDP 67-to-68
exception so the router can return DHCPv4 offers and acknowledgements; the
other three zones accept output.

The module identifies a unique stock defaults section, LAN and WAN zones, and
LAN-to-WAN forwarding by content. Anonymous sections are named only in the
candidate; the obsolete LAN policy is removed and `wan6` is removed from WAN.
Customized or ambiguous stock sections fail preflight. The complete candidate
is validated with `fw4 check`; the overlay is not a complete replacement for
`/etc/config/firewall`.

[Back to the README](../README.md)
