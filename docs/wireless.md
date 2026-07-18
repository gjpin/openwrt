# Wireless module

Sources: [`modules/wireless.sh`](../modules/wireless.sh) and
[`uci/wireless`](../uci/wireless)

This module creates four WPA3-SAE access points on `radio0`:

| SSID | Attached network | Password variable |
|---|---|---|
| `Pixel` | `pixel` | `PIXEL_WIFI_PASSWORD` |
| `PixelGuest` | `pixelguest` | `GUEST_WIFI_PASSWORD` |
| `PixelIoT` | `pixeliot` | `IOT_WIFI_PASSWORD` |
| `PixelThings` | `pixelthings` | `THINGS_WIFI_PASSWORD` |

Passwords must contain 8–63 printable characters. They are injected into the
mode-0600 transaction candidate and are never stored in the tracked overlay.

The module requires an existing `radio0`; radio selection, channel, country,
and other device settings remain part of the router's base configuration.

[Back to the README](../README.md)
