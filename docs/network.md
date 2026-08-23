# Network and DHCP module

Sources: [`modules/network.sh`](../modules/network.sh) and
[`uci/network`](../uci/network)

This module pins a static WAN behind the ISP router and adds four static
interfaces with a DHCP pool for each one:

| Role | Address |
|---|---|
| WAN | `192.168.2.2/24`, gateway `192.168.2.1` |
| `pixel` (`br-lan.1`) | `192.168.8.1/24`, DHCP `192.168.8.100`–`.249` |
| `pixelguest` (`br-lan.2`) | `192.168.9.1/24`, DHCP `192.168.9.100`–`.249` |
| `pixeliot` (`br-lan.3`) | `192.168.10.1/24`, DHCP `192.168.10.100`–`.249` |
| `pixelthings` (`br-lan.4`) | `192.168.11.1/24`, DHCP `192.168.11.100`–`.249` |

WAN uses the stock `network.wan` device with `proto=static`. Upstream is the ISP
router LAN at `192.168.2.1`, so internet egress is double NAT. The ISP router
must be moved to `192.168.2.1/24` before the OpenWrt WAN is connected, with
`192.168.2.2` reserved for or excluded from DHCP. Keeping the transit on
`192.168.2.0/24` avoids overlapping the fresh OpenWrt LAN at
`192.168.1.1/24`, so package installation has working WAN connectivity before
the candidate replaces the stock LAN.

Every IPv4 DHCP pool is enabled with a 12-hour lease. IPv6 delegation, router
advertisements, DHCPv6, and NDP proxying are disabled on every managed network,
and IPv6 is disabled on WAN. Client DNS is provided directly by AdGuard Home;
dnsmasq remains on port 54 for DHCP and local/PTR resolution. The overlay does
not set WAN DNS servers.

## Ethernet layout

VLAN 1 is untagged and primary on `lan1` through `lan5`. VLANs 2, 3, and 4 are
tagged on `lan1`, making it a mixed Pixel access port and trunk. They are not
carried on `lan2` through `lan5`.

The module preserves the router's base network sections and refuses to proceed
unless loopback, globals, WAN, `br_lan`, and the five expected DSA ports exist.
A recognized fresh stock `lan` interface (still expected at `192.168.1.1` before
migration), DHCP pool, `wan6`, and ULA prefix are removed transaction-locally.
The stock DHCP check accepts the explicit DHCPv4, DHCPv6, RA, SLAAC, and RA flag
values written by the upstream `odhcpd` first-boot defaults, while rejecting
non-stock modes or flags.
The stock LAN preflight address is deliberately distinct from the
`192.168.2.0/24` ISP transit; do not renumber the stock LAN instead. Customized
stock LAN settings are rejected rather than guessed. The overlay updates an
existing configuration; it is not a complete replacement for
`/etc/config/network` or `/etc/config/dhcp`.

[Back to the README](../README.md)
