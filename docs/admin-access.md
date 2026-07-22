# Admin access module

Sources: [`modules/admin-access.sh`](../modules/admin-access.sh) and
[`uci/admin-access`](../uci/admin-access)

This module binds router administration to the Pixel management VLAN so Guest,
IoT, and Things cannot reach LuCI or SSH even if a firewall input policy bug
opens those zones. It follows OpenWrt's
[secure access](https://openwrt.org/docs/guide-user/security/secure.access)
guidance: restrict listeners **and** keep restricted-VLAN firewall input closed.

## uHTTPd (LuCI)

OpenWrt's [`uhttpd`](https://openwrt.org/docs/guide-user/services/webserver/uhttpd)
has no interface option. Listen addresses are `list listen_http` /
`list listen_https` values of the form `IP:port`. The overlay replaces stock
wildcards (`0.0.0.0` and `[::]`) with:

- `192.168.8.1:80`
- `192.168.8.1:443`

and sets `redirect_https=1`. IPv6 listens are removed because managed VLANs are
IPv4-only. The address matches `network.pixel.ipaddr`, which the network module
validates.

## Dropbear (SSH)

OpenWrt [`Dropbear`](https://openwrt.org/docs/guide-user/base-system/dropbear)
supports `DirectInterface` (24.10+) to bind the listener to the underlying
network device (`dropbear -l <ndev>`). The overlay sets
`DirectInterface=pixel`, keeps `Port=22`, clears any legacy `Interface` option,
and leaves password auth as configured on the stock instance.

`Interface` only binds resolved IP addresses; `DirectInterface` rejects traffic
arriving on other VLAN devices even when destined to `192.168.8.1`.

Stock OpenWrt ships one anonymous Dropbear section. The module names it `main`
inside the candidate when content uniquely identifies that single instance.

## Recovery and boot notes

Binding LuCI/SSH to Pixel drops access from other VLANs and from the obsolete
stock LAN address after apply. Keep the documented Ethernet or serial recovery
path and confirm from a Pixel session.

uhttpd can fail to bind at boot if `192.168.8.1` is not up yet. Apply and
rollback restart uhttpd after network reload. Dropbear reloads via procd
`interface.*` triggers when `pixel` comes up.

Firewall zone policy in [`docs/firewall.md`](firewall.md) remains complementary:
restricted VLANs still reject router input except DNS/DHCP.

[Back to the README](../README.md)
