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

The module requires exactly one existing `wifi-device` with `band '2g'` and one
with `band '5g'`. It discovers their section names rather than assuming radio
numbering. Channel, country, and other device settings remain part of the
router's base configuration.

[Back to the README](../README.md)
