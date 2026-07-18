# Ad blocking module

Sources: [`modules/adblock-fast.sh`](../modules/adblock-fast.sh) and
[`uci/adblock-fast`](../uci/adblock-fast)

This module installs and enables `adblock-fast` and its LuCI application. It
configures the service to use the `dnsmasq.servers` backend and forces DNS on
ports 53 and 853 for all four managed interfaces.

The module replaces every existing `file_url` source with a fixed set of 19
enabled blocklists. These cover general advertising and tracking, native
Windows/Apple/Samsung tracking, smart TVs and mobile devices, DNS bypass,
gaming, CNAME trackers, and malicious domains. Insecure downloads, non-ASCII
entries, and automatic source-configuration updates are disabled.

This replacement does not preserve or migrate an existing adblock-fast source
configuration. Package installation and init enablement are outside rollback;
the UCI configuration itself is protected by the transaction.

[Back to the README](../README.md)

