# Wireless module

Sources: [`modules/wireless.sh`](../modules/wireless.sh) and
[`uci/wireless`](../uci/wireless)

This module creates four WPA3-SAE access points across the router's 2.4 GHz and
5 GHz radios:

| SSID | Band | Attached network | Password variable | Client isolation |
|---|---|---|---|---|
| `Pixel` | 5 GHz | `pixel` | `PIXEL_WIFI_PASSWORD` | off |
| `PixelGuest` | 5 GHz | `pixelguest` | `GUEST_WIFI_PASSWORD` | on (`isolate=1`) |
| `PixelIoT` | 2.4 GHz | `pixeliot` | `IOT_WIFI_PASSWORD` | on (`isolate=1`) |
| `PixelThings` | 5 GHz | `pixelthings` | `THINGS_WIFI_PASSWORD` | on (`isolate=1`) |

Guest, IoT, and Things set OpenWrt's `wifi-iface` option `isolate` to `1`, which
isolates wireless clients from each other on that AP (hostapd `ap_isolate`; see
[OpenWrt Wi-Fi /etc/config/wireless](https://openwrt.org/docs/guide-user/network/wifi/basic)).
Pixel leaves client isolation off so trusted stations can talk L2 to each other.
This is same-SSID L2 isolation and is separate from the inter-VLAN firewall
policy in [`docs/firewall.md`](firewall.md).

Passwords must contain 8–63 printable characters. They are injected into the
mode-0600 transaction candidate and are never stored in the tracked overlay.

`COUNTRY` must be set to a two-letter ISO country code (`A–Z`). It is applied to
both discovered `wifi-device` sections at prepare time. There is no default;
setup fails if `COUNTRY` is unset or empty.

`CHANNEL` selects the 5 GHz primary channel and defaults to `36` when unset.
Channel 36 is in the non-DFS UNII-1 block in typical regulatory domains, so the
default `HE80` radio uses the 36–48 block without a DFS Channel Availability
Check. The country code still controls whether the channel is available and
what power and indoor/outdoor restrictions apply. Setup and prepare accept an
integer from `36` through `177`; an explicit override can therefore select a
DFS channel and should be chosen only when it is intentional and country-legal.
The module always sets the 5 GHz `htmode` to `HE80` (802.11ax 80 MHz per
OpenWrt's `wifi-device` options). 2.4 GHz channel and `htmode` remain part of
the router's base configuration.

The module requires exactly one existing `wifi-device` with `band '2g'` and one
with `band '5g'`. It discovers their section names rather than assuming radio
numbering.

The discovered 5 GHz radio is configured with the hostapd option
`he_twt_responder=0`. For example, when the 5 GHz section is `radio1`, this is
equivalent to:

```
uci add_list wireless.radio1.hostapd_options='he_twt_responder=0'
```

The same transaction also manages `/etc/modules.conf` for Wireless Ethernet
Dispatch (WED). The candidate ensures exactly one line:

```
options mt7915e wed_enable=Y
```

`modules.conf` is backed up, checksummed, installed, and restored with the UCI
packages so a reboot while pending rolls it back. WED loads only after a reboot
**after confirm**; do not reboot while the transaction is still pending. WED
bypasses AQL on accelerated Wi-Fi traffic.

[Back to the README](../README.md)
