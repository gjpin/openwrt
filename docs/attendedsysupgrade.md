# Attended Sysupgrade module

Sources: [`modules/attendedsysupgrade.sh`](../modules/attendedsysupgrade.sh) and
[`uci/attendedsysupgrade`](../uci/attendedsysupgrade)

The module enables LuCI's upgrade check on the Status Overview page by setting
`attendedsysupgrade.client.login_check_for_upgrades=1`. The plural `upgrades`
matches the option read by `luci-app-attendedsysupgrade` on OpenWrt 25.12.

The package's named `client` section must already exist on the supported stock
base. Both an existing disabled value (`0`) and enabled value (`1`) are
normalized to `1` in the candidate, so repeated prepares are idempotent. The
configuration participates in the confirmed transaction and is restored by
rollback.

[Back to the README](../README.md)
