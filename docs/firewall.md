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
and 68. IoT also rejects zone output; the other three zones accept it.

The module requires the existing firewall defaults and WAN zone, preserves
them, and validates the complete candidate with `fw4 check`. The overlay is not
a complete replacement for `/etc/config/firewall`.

[Back to the README](../README.md)
