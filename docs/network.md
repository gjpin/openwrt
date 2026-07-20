# Network and DHCP module

Sources: [`modules/network.sh`](../modules/network.sh) and
[`uci/network`](../uci/network)

This module adds four static interfaces and a DHCP pool for each one:

| Network | VLAN device | Router address | DHCP range |
|---|---|---|---|
| `pixel` | `br-lan.1` | `192.168.1.1/24` | `192.168.1.100`–`.249` |
| `pixelguest` | `br-lan.2` | `192.168.2.1/24` | `192.168.2.100`–`.249` |
| `pixeliot` | `br-lan.3` | `192.168.3.1/24` | `192.168.3.100`–`.249` |
| `pixelthings` | `br-lan.4` | `192.168.4.1/24` | `192.168.4.100`–`.249` |

Every IPv4 DHCP pool is enabled with a 12-hour lease. IPv6 delegation, router
advertisements, DHCPv6, and NDP proxying are disabled on every managed network,
and IPv6 is disabled on WAN.

## Ethernet layout

VLAN 1 is untagged and primary on `lan1` through `lan5`. VLANs 2, 3, and 4 are
tagged on `lan1`, making it a mixed Pixel access port and trunk. They are not
carried on `lan2` through `lan5`.

The module preserves the router's base network sections and refuses to proceed
unless loopback, globals, WAN, `br_lan`, and the five expected DSA ports exist.
A recognized fresh stock `lan` interface, DHCP pool, `wan6`, and ULA prefix are
removed transaction-locally. Customized stock LAN settings are rejected rather
than guessed. The overlay updates an existing configuration; it is not a
complete replacement for `/etc/config/network` or `/etc/config/dhcp`.

[Back to the README](../README.md)
