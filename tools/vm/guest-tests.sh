#!/bin/sh

# Runs only inside the disposable OpenWrt VM created by run-vm-tests.py.
set -eu

profile=${1-stable}
[ "$profile" = stable ] || [ "$profile" = live ] || exit 2
cd "$(dirname "$0")/../.."

fail() {
    failure=$*
    printf 'vm-test: %s\n' "$failure" >&2
    printf '%s\n' '--- transaction lock ---' >&2
    if [ -e /var/lock/router-config.lock ]; then
        ls -la /var/lock/router-config.lock >&2 2>&1 || :
        if [ -d /var/lock/router-config.lock ]; then
            ls -la /var/lock/router-config.lock/ >&2 2>&1 || :
            if [ -r /var/lock/router-config.lock/pid ]; then
                printf 'pid file: ' >&2
                sed -n '1p' /var/lock/router-config.lock/pid >&2 2>&1 || :
            else
                printf '%s\n' 'pid file: missing' >&2
            fi
        fi
    else
        printf '%s\n' 'lock path absent' >&2
    fi
    printf '%s\n' '--- end transaction lock ---' >&2
    printf '%s\n' '--- transaction state ---' >&2
    find /root/router-config-backups -mindepth 2 -maxdepth 2 \
        \( -name state -o -name pending \) -print -exec sed -n '1p' {} \; >&2 2>&1 || :
    printf '%s\n' '--- end transaction state ---' >&2
    for package in network firewall wireless; do
        uci export "$package" 2>&1 | sed -e '/private_key/d' -e '/preshared_key/d' -e '/option key /d' >&2 || :
    done
    fw4 print >&2 2>&1 || :
    nft list ruleset >&2 2>&1 || :
    for service in network firewall sysntpd https-dns-proxy dnsmasq adblock-fast; do
        "/etc/init.d/$service" status >&2 2>&1 || :
    done
    logread >&2 2>&1 || :
    # Emit compact, high-signal diagnostics after logread so CI's truncated
    # serial/error tails still include the setup failure reason.
    printf '%s\n' '--- setup log ---' >&2
    if [ -s /tmp/setup.log ]; then
        tail -n 200 /tmp/setup.log >&2 2>&1 || :
    else
        printf '%s\n' '(empty or missing)' >&2
    fi
    printf '%s\n' '--- end setup log ---' >&2
    if [ -s /tmp/vm-test-failure-detail ]; then
        printf '%s\n' '--- failure detail ---' >&2
        cat /tmp/vm-test-failure-detail >&2 2>&1 || :
        printf '%s\n' '--- end failure detail ---' >&2
    fi
    printf 'vm-test: %s\n' "$failure" >&2
    exit 1
}

export_normalized_uci() {
    for package in network firewall wireless dhcp system https-dns-proxy adblock-fast; do
        uci show "$package"
    done |
        sed \
            -e '/\.private_key=/d' \
            -e '/\.preshared_key=/d' \
            -e '/^wireless\.[^.]*\.key=/d' \
            -e '/^adblock-fast\.[^.]*\.size=/d' |
        awk '
            {
                key = $0
                sub(/=.*/, "", key)
                occurrence[key]++
                printf "%s[%d]%s\n", key, occurrence[key], substr($0, length(key) + 1)
            }
        ' |
        sort
}

check_doh_listeners() {
    doh_phase=$1
    for doh_port in 5053 5054 5055 5056; do
        [ "$(uci show https-dns-proxy | grep -c "listen_port='$doh_port'")" = 1 ] ||
            fail "$doh_phase: DoH port $doh_port is not unique"
        if ! ss -lntu | grep -Eq "127\.0\.0\.1:${doh_port}[[:space:]]"; then
            {
                printf 'phase: %s\n' "$doh_phase"
                printf '%s\n' '--- ss -lntu ---'
                ss -lntu
                printf '%s\n' '--- /proc/net listeners ---'
                grep -E ':(13BD|13BE|13BF|13C0)[[:space:]]' /proc/net/tcp /proc/net/udp 2>&1 || :
            } >/tmp/vm-test-failure-detail
            fail "$doh_phase: DoH listener $doh_port is not bound"
        fi
    done
}

check_ap_interfaces() {
    wifi_phase=$1
    wifi_attempt=0
    while [ "$wifi_attempt" -lt 30 ]; do
        wifi_attempt=$((wifi_attempt + 1))
        ap_count=$(iw dev | awk '$1 == "type" && $2 == "AP" { count++ } END { print count + 0 }')
        [ "$ap_count" -eq 4 ] && return 0
        sleep 1
    done
    {
        printf 'phase: %s\n' "$wifi_phase"
        printf 'AP interface count: %s\n' "$ap_count"
        printf '%s\n' '--- wireless UCI (keys redacted) ---'
        uci show wireless | sed '/\.key=/d'
        printf '%s\n' '--- wireless ubus objects ---'
        ubus -v list 'network.wireless*' 2>&1 || :
        ubus call network.wireless status 2>&1 || :
        ubus -v list hostapd 2>&1 || :
        ubus -v list wpa_supplicant 2>&1 || :
        printf '%s\n' '--- wpad processes ---'
        for wifi_daemon in hostapd wpa_supplicant; do
            printf '%s: ' "$wifi_daemon"
            pidof "$wifi_daemon" || printf '%s\n' 'not running'
        done
        printf '%s\n' '--- radios ---'
        ls -1 /sys/class/ieee80211 2>&1 || :
        iw dev
        printf '%s\n' '--- wireless service log ---'
        logread -e netifd -e hostapd -e wpa_supplicant
    } >/tmp/vm-test-failure-detail 2>&1 || :
    fail "$wifi_phase: expected four AP interfaces, found $ap_count"
}

# QEMU user-net HTTPS to downloads.openwrt.org is flaky; retry the guest bootstrap.
apk_boot_attempt=0
while [ "$apk_boot_attempt" -lt 5 ]; do
    apk_boot_attempt=$((apk_boot_attempt + 1))
    apk update &&
        apk add diffutils ip-full kmod-veth kmod-nft-bridge tcpdump bind-dig \
            kmod-mac80211-hwsim iw-full wifi-scripts wpad-mesh-mbedtls wireguard-tools &&
        break
    [ "$apk_boot_attempt" -lt 5 ] || fail 'failed to install VM guest packages'
    sleep $((apk_boot_attempt * 2))
done
# The base image starts wpad-basic before this suite replaces it. The wpad ACL
# is also installed after ubusd loaded its startup ACL set, so a daemon jailed
# as user network cannot publish its global ubus objects in this disposable VM.
# Hide the capability file only while procd defines these test instances, which
# starts them unjailed as root without weakening any deployed router setting.
wpad_capabilities=/etc/capabilities/wpad.json
wpad_capabilities_saved=/tmp/wpad.json.vm-test
wpad_capabilities_hidden=0
if [ -e "$wpad_capabilities" ]; then
    mv "$wpad_capabilities" "$wpad_capabilities_saved"
    wpad_capabilities_hidden=1
fi
if ! /etc/init.d/wpad restart; then
    [ "$wpad_capabilities_hidden" = 0 ] || mv "$wpad_capabilities_saved" "$wpad_capabilities"
    fail 'failed to restart wpad after package replacement'
fi
[ "$wpad_capabilities_hidden" = 0 ] || mv "$wpad_capabilities_saved" "$wpad_capabilities"
wpad_ready=0
wpad_attempt=0
while [ "$wpad_attempt" -lt 30 ]; do
    wpad_attempt=$((wpad_attempt + 1))
    if ubus -S list hostapd >/dev/null 2>&1 && ubus -S list wpa_supplicant >/dev/null 2>&1; then
        wpad_ready=1
        break
    fi
    sleep 1
done
[ "$wpad_ready" = 1 ] || fail 'wpad global ubus objects did not appear'
# The package install auto-loads mac80211_hwsim with its two-radio default.
# Reload it with the six radios required for two APs and four isolated clients.
# OpenWrt's modprobe applet does not pass module parameters through, so use the
# parameter-aware insmod applet for this test-only reload.
if grep -qw mac80211_hwsim /proc/modules; then
    rmmod mac80211_hwsim || fail 'mac80211-hwsim failed to unload for radio configuration'
fi
insmod mac80211_hwsim radios=6 || fail 'mac80211-hwsim failed to load'
[ "$(find /sys/class/ieee80211 -mindepth 1 -maxdepth 1 | wc -l)" -ge 6 ] || fail 'hwsim radios were not created'
set -- /sys/class/ieee80211/phy*
[ "$#" -eq 6 ] || fail 'unexpected number of hwsim radios'
ap_5g_phy=${1##*/}
ap_2g_phy=${2##*/}
pixel_client_phy=${3##*/}
guest_client_phy=${4##*/}
iot_client_phy=${5##*/}
things_client_phy=${6##*/}

# Build five disposable DSA-like links before installer preflight.  The peer
# sides are later moved into isolated client namespaces.
for port in 1 2 3 4 5; do
    ip link del "lan$port" 2>/dev/null || :
    ip link add "lan$port" type veth peer name "peer$port"
    ip link set "lan$port" up
    ip link set "peer$port" up
done
ip link del br-lan 2>/dev/null || :
ip link add br-lan type bridge vlan_filtering 1
ip link set br-lan up

# Seed the upstream GL-MT6000 shape, including deliberately anonymous base
# firewall and dnsmasq sections.
: >/etc/config/network
uci -q batch <<'EOF'
set network.loopback='interface'
set network.loopback.device='lo'
set network.loopback.proto='static'
set network.loopback.ipaddr='127.0.0.1'
set network.loopback.netmask='255.0.0.0'
set network.globals='globals'
set network.globals.ula_prefix='fd12:3456:789a::/48'
set network.wan='interface'
set network.wan.device='eth0'
set network.wan.proto='dhcp'
set network.wan6='interface'
set network.wan6.device='@wan'
set network.wan6.proto='dhcpv6'
add network device
set network.@device[-1].name='br-lan'
set network.@device[-1].type='bridge'
add_list network.@device[-1].ports='lan1'
add_list network.@device[-1].ports='lan2'
add_list network.@device[-1].ports='lan3'
add_list network.@device[-1].ports='lan4'
add_list network.@device[-1].ports='lan5'
set network.lan='interface'
set network.lan.device='br-lan'
set network.lan.proto='static'
add_list network.lan.ipaddr='192.168.1.1/24'
set network.lan.ip6assign='60'
EOF
uci commit network

: >/etc/config/dhcp
uci -q batch <<'EOF'
add dhcp dnsmasq
set dhcp.@dnsmasq[-1].domainneeded='1'
set dhcp.@dnsmasq[-1].boguspriv='1'
set dhcp.lan='dhcp'
set dhcp.lan.interface='lan'
set dhcp.lan.start='100'
set dhcp.lan.limit='150'
set dhcp.lan.leasetime='12h'
EOF
uci commit dhcp

: >/etc/config/firewall
uci -q batch <<'EOF'
add firewall defaults
set firewall.@defaults[-1].synflood_protect='1'
set firewall.@defaults[-1].input='REJECT'
set firewall.@defaults[-1].output='ACCEPT'
set firewall.@defaults[-1].forward='REJECT'
add firewall zone
set firewall.@zone[-1].name='lan'
add_list firewall.@zone[-1].network='lan'
set firewall.@zone[-1].input='ACCEPT'
set firewall.@zone[-1].output='ACCEPT'
set firewall.@zone[-1].forward='ACCEPT'
add firewall zone
set firewall.@zone[-1].name='wan'
add_list firewall.@zone[-1].network='wan'
add_list firewall.@zone[-1].network='wan6'
set firewall.@zone[-1].input='REJECT'
set firewall.@zone[-1].output='ACCEPT'
set firewall.@zone[-1].forward='REJECT'
set firewall.@zone[-1].masq='1'
set firewall.@zone[-1].mtu_fix='1'
add firewall forwarding
set firewall.@forwarding[-1].src='lan'
set firewall.@forwarding[-1].dest='wan'
EOF
uci commit firewall

: >/etc/config/wireless
uci -q batch <<'EOF'
set wireless.radio0='wifi-device'
set wireless.radio0.type='mac80211'
set wireless.radio0.band='5g'
set wireless.radio0.channel='36'
set wireless.radio0.country='US'
set wireless.radio1='wifi-device'
set wireless.radio1.type='mac80211'
set wireless.radio1.band='2g'
set wireless.radio1.channel='6'
set wireless.radio1.country='US'
EOF
uci set "wireless.radio0.phy=$ap_5g_phy"
uci set "wireless.radio1.phy=$ap_2g_phy"
uci commit wireless

# The generic armsr image starts netifd without a wireless backend. Installing
# wifi-scripts adds that backend, but netifd discovers handlers only at startup.
# Restart only after replacing the auto-loaded hwsim PHYs and seeding their
# final mapping, then wait for the test uplink before setup.sh needs apk access.
/etc/init.d/network restart || fail 'failed to restart netifd after installing wifi-scripts'
uplink_ready=0
uplink_attempt=0
while [ "$uplink_attempt" -lt 30 ]; do
    uplink_attempt=$((uplink_attempt + 1))
    if ifstatus wan | grep -q '"up": true'; then
        uplink_ready=1
        break
    fi
    sleep 1
done
[ "$uplink_ready" = 1 ] || fail 'WAN did not recover after restarting netifd'
# Apply the seeded firewall explicitly. netifd can mark WAN up before fw4 has
# reloaded from the stock overlay, and apk's wget then fails with EPERM
# ("Operation not permitted") against downloads.openwrt.org.
/etc/init.d/firewall restart || fail 'failed to apply seeded firewall'
# Wait until apk can refresh indexes. QEMU user-net plus DNS/firewall hotplug
# can still flake briefly after WAN is up; setup.sh needs a working mirror.
apk_ready=0
apk_attempt=0
while [ "$apk_attempt" -lt 15 ]; do
    apk_attempt=$((apk_attempt + 1))
    if apk update >/tmp/vm-test-apk-update 2>&1; then
        apk_ready=1
        break
    fi
    sleep 2
done
if [ "$apk_ready" != 1 ]; then
    {
        printf 'apk update failed after %s attempts\n' "$apk_attempt"
        printf '%s\n' '--- apk update output ---'
        cat /tmp/vm-test-apk-update 2>&1 || :
        printf '%s\n' '--- WAN status ---'
        ifstatus wan || :
        printf '%s\n' '--- resolv.conf.auto ---'
        cat /tmp/resolv.conf.d/resolv.conf.auto 2>&1 || :
    } >/tmp/vm-test-failure-detail 2>&1 || :
    fail 'apk update failed after WAN recovery'
fi

server_private=$(wg genkey)
server_public=$(printf '%s' "$server_private" | wg pubkey)
client_private=$(wg genkey)
client_public=$(printf '%s' "$client_private" | wg pubkey)
preshared=$(wg genpsk)
export PIXEL_WIFI_PASSWORD='vm-pixel-password'
export THINGS_WIFI_PASSWORD='vm-things-password'
export GUEST_WIFI_PASSWORD='vm-guest-password'
export IOT_WIFI_PASSWORD='vm-iot-password'
export VPN_IF='wgserver'
export VPN_PORT='51820'
export VPN_KEY="$server_private"
export VPN_ADDR='10.10.0.1/24'
export VPN_PUB="$client_public"
export VPN_PSK="$preshared"

run_and_confirm() {
    ./setup.sh --recovery-ready >/tmp/setup.log 2>&1 &
    setup_pid=$!
    pending=
    attempts=0
    # Package install plus apply/reload (especially adblock-fast) can exceed three
    # minutes on the emulated AArch64 CI VM, so wait well beyond that.
    while [ "$attempts" -lt 900 ]; do
        attempts=$((attempts + 1))
        pending=$(find /root/router-config-backups -name pending -type f 2>/dev/null | sort | tail -n 1)
        [ -z "$pending" ] || break
        kill -0 "$setup_pid" 2>/dev/null || {
            setup_status=0
            wait "$setup_pid" || setup_status=$?
            {
                printf 'setup pid exited with status: %s\n' "$setup_status"
                printf '%s\n' '--- setup log ---'
                if [ -s /tmp/setup.log ]; then
                    tail -n 200 /tmp/setup.log
                else
                    printf '%s\n' '(empty or missing)'
                fi
            } >/tmp/vm-test-failure-detail 2>&1 || :
            fail 'setup exited before pending state'
        }
        sleep 1
    done
    [ -n "$pending" ] || fail 'setup did not create a pending transaction'
    attempts=0
    while [ "$attempts" -lt 900 ]; do
        attempts=$((attempts + 1))
        [ -f "$pending" ] || fail 'pending transaction disappeared before confirmation'
        kill -0 "$setup_pid" 2>/dev/null || {
            wait "$setup_pid" || :
            fail 'setup exited before releasing the transaction lock'
        }
        if [ ! -d /var/lock/router-config.lock ] &&
            grep -q 'candidate applied; confirm' /tmp/setup.log 2>/dev/null; then
            break
        fi
        sleep 1
    done
    [ ! -d /var/lock/router-config.lock ] || fail 'setup did not release the transaction lock'
    grep -q 'candidate applied; confirm' /tmp/setup.log 2>/dev/null ||
        fail 'setup did not report that the candidate was applied'
    transaction=${pending%/pending}
    transaction=${transaction##*/}
    [ -f "$pending" ] || fail 'pending transaction disappeared before confirmation'
    kill -0 "$setup_pid" 2>/dev/null || {
        wait "$setup_pid" || :
        fail 'setup exited before confirmation'
    }
    /usr/libexec/router-config confirm "$transaction" || fail 'transaction confirmation failed'
    wait "$setup_pid" || fail 'setup did not finish after confirmation'
    LAST_TX=$transaction
}

run_and_confirm
check_ap_interfaces 'after first installation'
export_normalized_uci >/tmp/first.export
fw4 check || fail 'fw4 rejected installed configuration'
[ "$(uci -q get network.lan || :)" = '' ] || fail 'stock LAN survived migration'
[ "$(uci -q get network.wan6 || :)" = '' ] || fail 'wan6 survived migration'
[ "$(uci -q get firewall.wan.network)" = wan ] || fail 'WAN zone was not normalized'
[ "$(uci -q get firewall.defaults.flow_offloading)" = 1 ] || fail 'software flow offloading is not enabled'
[ "$(uci -q get firewall.defaults.flow_offloading_hw)" = 1 ] || fail 'hardware flow offloading is not enabled'
grep -qx 'options mt7915e wed_enable=Y' /etc/modules.conf || fail 'WED is not enabled in modules.conf'
wed_count=$(grep -c 'wed_enable=' /etc/modules.conf || :)
[ "$wed_count" = 1 ] || fail 'modules.conf has duplicate WED options'
for port in lan1 lan2 lan3 lan4 lan5; do
    uci -q get network.br_lan.ports | tr ' ' '\n' | grep -qx "$port" || fail "$port is absent from bridge"
done
for net in pixel pixelguest pixeliot pixelthings; do
    uci -q get "firewall.divert_dns_$net.src" | grep -qx "$net" || fail "missing DNS interception for $net"
    uci -q get "firewall.reject_dot_$net.src" | grep -qx "$net" || fail "missing DoT rejection for $net"
done
uci -q get firewall.pixeliot_dhcp_reply.dest | grep -qx pixeliot || fail 'missing outbound IoT DHCP exception'
uci -q get firewall.pixeliot_dhcp_reply.src_port | grep -qx 67 || fail 'invalid IoT DHCP reply source port'
uci -q get firewall.pixeliot_dhcp_reply.dest_port | grep -qx 68 || fail 'invalid IoT DHCP reply destination port'

run_and_confirm
check_ap_interfaces 'after second installation'
export_normalized_uci >/tmp/second.export
if ! cmp -s /tmp/first.export /tmp/second.export; then
    diff -u /tmp/first.export /tmp/second.export >/tmp/vm-test-failure-detail 2>&1 || :
    fail 'second installation changed normalized UCI exports'
fi
check_doh_listeners 'before rollback'
/usr/libexec/router-config rollback "$LAST_TX"
[ "$(cat "/root/router-config-backups/$LAST_TX/state")" = rolledback ] || fail 'manual rollback did not complete'
check_doh_listeners 'after manual rollback'
check_ap_interfaces 'after manual rollback'

boot_prepare=$(./router-config.sh prepare --recovery-ready)
boot_tx=$(printf '%s\n' "$boot_prepare" | tail -n 1)
touch "/root/router-config-backups/$boot_tx/pending"
printf '%s\n' pending >"/root/router-config-backups/$boot_tx/state"
/etc/init.d/router-config-rollback start
[ "$(cat "/root/router-config-backups/$boot_tx/state")" = rolledback ] || fail 'early-boot service did not recover pending state'
check_doh_listeners 'after early-boot recovery'
check_ap_interfaces 'after early-boot recovery'

if [ "$profile" = live ]; then
    /etc/init.d/https-dns-proxy restart
    sleep 5
    for port in 5053 5054 5055 5056; do
        dig +time=10 +tries=1 @127.0.0.1 -p "$port" openwrt.org A | grep -q 'status: NOERROR' ||
            fail "live DoH query failed on $port"
    done
    # Do not re-download multi-megabyte blocklists here. Setup already fetched
    # them, and once dnsmasq.servers is active a source host that appears in any
    # list (or a slow QEMU user-net transfer) makes uclient-fetch fail spuriously.
    [ -s /var/run/adblock-fast/dnsmasq.servers ] ||
        fail 'adblock-fast dnsmasq.servers missing after live setup'
    blocklist_lines=$(wc -l </var/run/adblock-fast/dnsmasq.servers)
    [ "$blocklist_lines" -gt 1000 ] ||
        fail "adblock-fast dnsmasq.servers too small: $blocklist_lines lines"
    uci show adblock-fast | sed -n "s/.*\.url='\(.*\)'/\1/p" >/tmp/vm-test-blocklist-urls
    [ -s /tmp/vm-test-blocklist-urls ] || fail 'no adblock-fast source URLs configured'
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        case "$url" in
            https://* | http://*) ;;
            *) fail "adblock-fast source is not an http(s) URL: $url" ;;
        esac
    done </tmp/vm-test-blocklist-urls
fi

# Associate one isolated WPA3-SAE hwsim station with each managed SSID and
# obtain its lease through the real AP/netifd bridge path.
wifi_client() {
    client_phy=$1
    client_if=$2
    client_ns=$3
    client_ssid=$4
    client_password=$5
    ip netns del "$client_ns" 2>/dev/null || :
    ip netns add "$client_ns" || fail "failed to create Wi-Fi namespace $client_ns"
    ip -n "$client_ns" link set lo up || fail "failed to enable loopback in $client_ns"
    iw phy "$client_phy" set netns name "$client_ns" ||
        fail "failed to move $client_phy into $client_ns"
    ip netns exec "$client_ns" \
        iw phy "$client_phy" interface add "$client_if" type managed ||
        fail "failed to create $client_if from $client_phy in $client_ns"
    cat >"/tmp/$client_ns.conf" <<EOF
network={
    ssid="$client_ssid"
    psk="$client_password"
    key_mgmt=SAE
    ieee80211w=2
}
EOF
    chmod 600 "/tmp/$client_ns.conf"
    ip netns exec "$client_ns" wpa_supplicant -B -D nl80211 -i "$client_if" -c "/tmp/$client_ns.conf"
    associated=0
    attempts=0
    while [ "$attempts" -lt 30 ]; do
        attempts=$((attempts + 1))
        if ip netns exec "$client_ns" iw dev "$client_if" link | grep -q '^Connected'; then
            associated=1
            break
        fi
        sleep 1
    done
    if [ "$associated" != 1 ]; then
        {
            printf 'SSID: %s\n' "$client_ssid"
            printf '%s\n' '--- regulatory state ---'
            iw reg get
            printf '%s\n' '--- AP radios ---'
            iw dev
            printf '%s\n' '--- client radio ---'
            ip netns exec "$client_ns" iw dev
            printf '%s\n' '--- client link ---'
            ip netns exec "$client_ns" iw dev "$client_if" link
            printf '%s\n' '--- wireless service log ---'
            logread -e hostapd -e wpa_supplicant
        } >/tmp/vm-test-failure-detail 2>&1 || :
        fail "WPA3 association failed for $client_ssid"
    fi
    ip netns exec "$client_ns" udhcpc -q -n -t 8 -i "$client_if" || fail "Wi-Fi DHCP failed for $client_ssid"
}
wifi_client "$pixel_client_phy" wpixel wifi_pixel Pixel "$PIXEL_WIFI_PASSWORD"
wifi_client "$guest_client_phy" wguest wifi_guest PixelGuest "$GUEST_WIFI_PASSWORD"
wifi_client "$iot_client_phy" wiot wifi_iot PixelIoT "$IOT_WIFI_PASSWORD"
wifi_client "$things_client_phy" wthings wifi_things PixelThings "$THINGS_WIFI_PASSWORD"

# Move the five link peers into clients. lan1 carries native VLAN 1 plus the
# three tagged networks; lan2-lan5 are Pixel access links.
ip link add link peer1 name guest0 type vlan id 2
ip link add link peer1 name iot0 type vlan id 3
ip link add link peer1 name things0 type vlan id 4
for namespace in pixel1 pixel2 pixel3 pixel4 pixel5 guest iot things; do
    ip netns del "$namespace" 2>/dev/null || :
    ip netns add "$namespace"
    ip -n "$namespace" link set lo up
done
ip link set guest0 netns guest
ip link set iot0 netns iot
ip link set things0 netns things
ip link set peer1 netns pixel1
ip link set peer2 netns pixel2
ip link set peer3 netns pixel3
ip link set peer4 netns pixel4
ip link set peer5 netns pixel5

lease() {
    namespace=$1
    interface=$2
    ip -n "$namespace" link set "$interface" up
    ip netns exec "$namespace" udhcpc -q -n -t 8 -i "$interface" || fail "DHCP failed in $namespace"
    ip -n "$namespace" -4 address show dev "$interface" | grep -q 'inet ' || fail "no DHCP address in $namespace"
}
lease pixel1 peer1
lease pixel2 peer2
lease pixel3 peer3
lease pixel4 peer4
lease pixel5 peer5
lease guest guest0
lease iot iot0
lease things things0
pixel_address=$(ip -n pixel1 -o -4 address show dev peer1 | awk '{ sub(/\/.*/, "", $4); print $4 }')
guest_address=$(ip -n guest -o -4 address show dev guest0 | awk '{ sub(/\/.*/, "", $4); print $4 }')
ip netns exec pixel1 ping -c 1 -W 2 "$guest_address" >/dev/null || fail 'Pixel cannot reach Guest client'
! ip netns exec guest ping -c 1 -W 2 "$pixel_address" >/dev/null 2>&1 || fail 'Guest reached Pixel client'
ip netns exec pixel1 ping -c 1 -W 2 192.168.2.1 >/dev/null || fail 'Pixel cannot reach Guest gateway'
! ip netns exec guest ping -c 1 -W 2 192.168.1.1 >/dev/null 2>&1 || fail 'Guest reached Pixel gateway'
! ip netns exec iot ping -c 1 -W 2 192.168.1.1 >/dev/null 2>&1 || fail 'IoT reached Pixel gateway'
! ip netns exec things ping -c 1 -W 2 192.168.1.1 >/dev/null 2>&1 || fail 'Things reached Pixel gateway'

# A local deterministic answer proves that queries sent to a nonexistent
# external resolver are intercepted at port 53.
uci -q del_list dhcp.dnsmasq.address='/vm.test/203.0.113.7' 2>/dev/null || :
uci add_list dhcp.dnsmasq.address='/vm.test/203.0.113.7'
uci commit dhcp
/etc/init.d/dnsmasq restart
dns_ready=0
dns_attempt=0
while [ "$dns_attempt" -lt 30 ]; do
    dns_attempt=$((dns_attempt + 1))
    if dig +short +time=1 +tries=1 @127.0.0.1 vm.test A \
        >/tmp/vm-test-dns-local 2>&1 &&
        grep -qx 203.0.113.7 /tmp/vm-test-dns-local; then
        dns_ready=1
        break
    fi
    sleep 1
done
if [ "$dns_ready" != 1 ]; then
    {
        printf 'dnsmasq was not ready after %s attempts\n' "$dns_attempt"
        printf '%s\n' '--- local DNS query ---'
        cat /tmp/vm-test-dns-local 2>&1 || :
        printf '%s\n' '--- DNS listeners ---'
        ss -lnut 2>&1 || :
    } >/tmp/vm-test-failure-detail
    fail 'dnsmasq did not serve the interception test answer'
fi
dns_before=$(nft list ruleset |
    sed -n '/PixelGuest-Divert-DNS/s/.*counter packets \([0-9][0-9]*\).*/\1/p' |
    head -n 1)
[ -n "$dns_before" ] || fail 'Guest DNS interception rule has no nftables counter'
if ! ip netns exec guest dig +short +time=3 +tries=1 \
    @203.0.113.250 vm.test A >/tmp/vm-test-dns-intercepted 2>&1 ||
    ! grep -qx 203.0.113.7 /tmp/vm-test-dns-intercepted; then
    dns_after=$(nft list ruleset |
        sed -n '/PixelGuest-Divert-DNS/s/.*counter packets \([0-9][0-9]*\).*/\1/p' |
        head -n 1)
    {
        printf '%s\n' '--- intercepted DNS query ---'
        cat /tmp/vm-test-dns-intercepted 2>&1 || :
        printf 'PixelGuest-Divert-DNS packets before: %s\n' "$dns_before"
        printf 'PixelGuest-Divert-DNS packets after: %s\n' "${dns_after:-missing}"
        printf '%s\n' '--- PixelGuest DNS nftables rule ---'
        nft list ruleset | sed -n '/PixelGuest-Divert-DNS/p' || :
    } >/tmp/vm-test-failure-detail
    fail 'Guest DNS was not intercepted'
fi

# Build an isolated WAN peer, then establish a real WireGuard handshake through
# the installed WAN rule. This phase intentionally follows live-provider tests.
ip link add vmwan type veth peer name vmwanpeer
ip netns add wanclient 2>/dev/null || :
ip link set vmwanpeer netns wanclient
ip -n wanclient link set lo up
ip -n wanclient link set vmwanpeer up
ip -n wanclient addr add 198.18.0.2/24 dev vmwanpeer
uci set network.wan.device='vmwan'
uci set network.wan.proto='static'
uci set network.wan.ipaddr='198.18.0.1'
uci set network.wan.netmask='255.255.255.0'
uci commit network
/etc/init.d/network restart || fail 'failed to restart network for static VM WAN'
vm_wan_ready=0
vm_wan_attempt=0
while [ "$vm_wan_attempt" -lt 30 ]; do
    vm_wan_attempt=$((vm_wan_attempt + 1))
    if ifstatus wan >/tmp/vm-test-wan-status 2>&1 &&
        grep -q '"up": true' /tmp/vm-test-wan-status &&
        grep -q '"l3_device": "vmwan"' /tmp/vm-test-wan-status; then
        vm_wan_ready=1
        break
    fi
    sleep 1
done
if [ "$vm_wan_ready" != 1 ]; then
    cp /tmp/vm-test-wan-status /tmp/vm-test-failure-detail 2>/dev/null || :
    fail 'static VM WAN did not become ready'
fi
# netifd marks WAN up before fw4 has retargeted masquerade onto vmwan. Retry
# LAN->WAN probes first so the async firewall hotplug from the WAN device swap
# can finish. Reload only after connectivity works, so DoT nftables counters are
# not replaced mid-assertion by a late hotplug reload.
wan_probe_ready=0
wan_probe_attempt=0
wan_probe_failed=
while [ "$wan_probe_attempt" -lt 30 ]; do
    wan_probe_attempt=$((wan_probe_attempt + 1))
    wan_probe_ready=1
    wan_probe_failed=
    for namespace in pixel1 guest things; do
        if ! ip netns exec "$namespace" ping -c 1 -W 2 198.18.0.2 >/dev/null 2>&1; then
            wan_probe_ready=0
            wan_probe_failed=$namespace
            break
        fi
    done
    [ "$wan_probe_ready" = 1 ] && break
    sleep 1
done
if [ "$wan_probe_ready" != 1 ]; then
    {
        printf 'WAN probes failed after %s attempts (first failure: %s)\n' \
            "$wan_probe_attempt" "${wan_probe_failed:-unknown}"
        printf '%s\n' '--- WAN status ---'
        ifstatus wan || :
        printf '%s\n' '--- client routes ---'
        for namespace in pixel1 guest things; do
            printf 'namespace %s:\n' "$namespace"
            ip -n "$namespace" route || :
        done
        printf '%s\n' '--- nft masq / wan ---'
        nft list ruleset | sed -n '/masq\|vmwan\|oifname/p' || :
    } >/tmp/vm-test-failure-detail 2>&1 || :
    fail "$wan_probe_failed cannot reach WAN"
fi
! ip netns exec iot ping -c 1 -W 2 198.18.0.2 >/dev/null 2>&1 || fail 'IoT reached WAN'
/etc/init.d/firewall reload || fail 'firewall reload failed after static VM WAN activation'
dot_before=$(nft list ruleset | sed -n '/PixelGuest-Reject-DoT/s/.*counter packets \([0-9][0-9]*\).*/\1/p' | head -n 1)
[ -n "$dot_before" ] || fail 'DoT rule has no nftables counter'
# bind-dig is installed above and +tcp guarantees a TCP connection attempt.
# Do not rely on the image's optional BusyBox nc applet for this assertion.
ip netns exec guest dig +tcp +time=1 +tries=1 \
    @198.18.0.2 -p 853 vm.test A >/tmp/vm-test-dot-probe 2>&1 || :
dot_after=$(nft list ruleset | sed -n '/PixelGuest-Reject-DoT/s/.*counter packets \([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ -z "$dot_after" ] || [ "$dot_after" -le "$dot_before" ]; then
    {
        printf 'PixelGuest-Reject-DoT packets before: %s\n' "$dot_before"
        printf 'PixelGuest-Reject-DoT packets after: %s\n' "${dot_after:-missing}"
        printf '%s\n' '--- PixelGuest DoT nftables rule ---'
        nft list ruleset | sed -n '/PixelGuest-Reject-DoT/p' || :
        printf '%s\n' '--- WAN status ---'
        ifstatus wan || :
        printf '%s\n' '--- Guest routes ---'
        ip -n guest route || :
        printf '%s\n' '--- DoT probe output ---'
        cat /tmp/vm-test-dot-probe || :
    } >/tmp/vm-test-failure-detail 2>&1
    fail 'DoT rejection counter did not increase'
fi
uci set firewall.allow_wireguard.enabled='0'
uci commit firewall
/etc/init.d/firewall reload
ip netns exec wanclient ip link add wgtest type wireguard
printf '%s\n' "$client_private" >/tmp/client-private
printf '%s\n' "$preshared" >/tmp/client-psk
chmod 600 /tmp/client-private /tmp/client-psk
ip netns exec wanclient wg set wgtest private-key /tmp/client-private \
    peer "$server_public" preshared-key /tmp/client-psk allowed-ips 10.10.0.1/32 \
    endpoint 198.18.0.1:51820
ip -n wanclient address add 10.10.0.2/24 dev wgtest
ip -n wanclient link set wgtest up
! ip netns exec wanclient ping -c 2 -W 2 10.10.0.1 >/dev/null 2>&1 ||
    fail 'WireGuard succeeded while its WAN rule was disabled'
uci delete firewall.allow_wireguard.enabled
uci commit firewall
/etc/init.d/firewall reload
ip netns exec wanclient ping -c 3 -W 3 10.10.0.1 >/dev/null || fail 'WireGuard tunnel did not pass traffic'
ip netns exec wanclient wg show wgtest latest-handshakes | grep -Eq '[1-9][0-9]{8,}' ||
    fail 'WireGuard did not record a handshake'
fw4 print | grep -q 'Allow-WireGuard' || fail 'WAN WireGuard rule is absent from fw4 output'

# Exercise a real watchdog rollback and a missing-port preflight rejection.
prepare_output=$(./router-config.sh prepare --recovery-ready)
timeout_tx=$(printf '%s\n' "$prepare_output" | tail -n 1)
if ROUTER_CONFIG_TIMEOUT=2 ROUTER_CONFIG_POLL_INTERVAL=1 /usr/libexec/router-config apply "$timeout_tx"; then
    fail 'unconfirmed transaction unexpectedly succeeded'
fi
[ "$(cat "/root/router-config-backups/$timeout_tx/state")" = rolledback ] || fail 'watchdog did not roll back'
ip link del lan5
if ./router-config.sh prepare --recovery-ready >/tmp/missing-port.log 2>&1; then
    fail 'missing lan5 passed preflight'
fi
grep -q 'required DSA interface missing: lan5' /tmp/missing-port.log || fail 'missing-port rejection was unclear'

printf '%s\n' 'vm-test: stable acceptance suite passed'
