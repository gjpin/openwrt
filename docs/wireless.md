# Wireless module

Sources: [`modules/wireless.sh`](../modules/wireless.sh) and
[`uci/wireless`](../uci/wireless)

This module creates four WPA3-SAE access points across the router's 2.4 GHz and
5 GHz radios:

| SSID | Band | Attached network | Password variable |
|---|---|---|---|
| `Pixel` | 5 GHz | `pixel` | `PIXEL_WIFI_PASSWORD` |
| `PixelGuest` | 5 GHz | `pixelguest` | `GUEST_WIFI_PASSWORD` |
| `PixelIoT` | 2.4 GHz | `pixeliot` | `IOT_WIFI_PASSWORD` |
| `PixelThings` | 5 GHz | `pixelthings` | `THINGS_WIFI_PASSWORD` |

Passwords must contain 8–63 printable characters. They are injected into the
mode-0600 transaction candidate and are never stored in the tracked overlay.

`COUNTRY` must be set to a two-letter ISO country code (`A–Z`). It is applied to
both discovered `wifi-device` sections at prepare time. There is no default;
setup fails if `COUNTRY` is unset or empty.

The module requires exactly one existing `wifi-device` with `band '2g'` and one
with `band '5g'`. It discovers their section names rather than assuming radio
numbering. Channel and other device settings remain part of the router's base
configuration.

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
