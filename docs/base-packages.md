# Base packages module

Source: [`modules/base-packages.sh`](../modules/base-packages.sh)

This module updates the OpenWrt package index and installs `gawk`, `grep`, `sed`,
`coreutils-sort`, and `nano`. These provide the command-line tools used by the
provisioning workflow or for router administration.

It does not change UCI configuration. Package installation occurs before the
protected configuration transaction, so an automatic or manual rollback does
not uninstall these packages.

[Back to the README](../README.md)

