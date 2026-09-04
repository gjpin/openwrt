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
    for service in network firewall chronyd dnsmasq adguardhome; do
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
    for package in network firewall wireless dhcp system chrony adguardhome uhttpd dropbear attendedsysupgrade; do
        uci show "$package"
    done |
        sed \
            -e '/\.private_key=/d' \
            -e '/\.preshared_key=/d' \
            -e '/^wireless\.[^.]*\.key=/d' \
            -e '/^dhcp\.dnsmasq\.serversfile=/d' |
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

check_dns_listeners() {
    dns_phase=$1
    wireguard_dns_ip=${VPN_ADDR%/*}
    if ! ss -lntu | grep -Eq '(^|[.:])53[[:space:]]'; then
        fail "$dns_phase: AdGuard Home DNS port 53 is not bound"
    fi
    for dns_protocol in tcp udp; do
        ss -lntu | awk -v protocol="$dns_protocol" -v endpoint="$wireguard_dns_ip:53" '
            $1 == protocol && index($0, endpoint) { found = 1 }
            END { exit !found }
        ' || fail "$dns_phase: AdGuard Home $dns_protocol DNS is not bound to WireGuard"
    done
    if ! ss -lntu | grep -Eq '(^|[.:])54[[:space:]]'; then
        fail "$dns_phase: dnsmasq local DNS port 54 is not bound"
    fi
    if ! ss -lnt | grep -Eq '192\.168\.8\.1:3000[[:space:]]'; then
        fail "$dns_phase: AdGuard Home dashboard is not bound to Pixel"
    fi
    ! ss -lnt | grep -Eq '192\.168\.(9|10|11)\.1:3000[[:space:]]' ||
        fail "$dns_phase: AdGuard Home dashboard is exposed to a restricted VLAN"
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
set dhcp.lan.dhcpv4='server'
set dhcp.lan.dhcpv6='server'
set dhcp.lan.ra='server'
set dhcp.lan.ra_slaac='1'
add_list dhcp.lan.ra_flags='managed-config'
add_list dhcp.lan.ra_flags='other-config'
EOF
uci commit dhcp

: >/etc/config/firewall
uci -q batch <<'EOF'
add firewall defaults
set firewall.@defaults[-1].syn_flood='1'
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
set firewall.@zone[-1].forward='DROP'
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
# final mapping. The stock 192.168.1.0/24 LAN and emulated 192.168.2.0/24 ISP
# transit are deliberately distinct so package installation has working WAN
# connectivity before the candidate replaces the stock LAN.
/etc/init.d/network restart || fail 'failed to restart netifd after installing wifi-scripts'
stock_lan_ready=0
stock_lan_attempt=0
while [ "$stock_lan_attempt" -lt 30 ]; do
    stock_lan_attempt=$((stock_lan_attempt + 1))
    if ifstatus lan | grep -q '"up": true'; then
        stock_lan_ready=1
        break
    fi
    sleep 1
done
[ "$stock_lan_ready" = 1 ] || fail 'stock LAN did not start'
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
[ "$uplink_ready" = 1 ] || fail 'WAN did not start on the non-overlapping ISP transit'
# Apply the seeded firewall explicitly. netifd can mark WAN up before fw4 has
# reloaded from the stock overlay, and apk's wget then fails with EPERM
# ("Operation not permitted") against downloads.openwrt.org.
/etc/init.d/firewall restart || fail 'failed to apply seeded firewall'
# Wait until the QEMU uplink can reach the OpenWrt mirror, then refresh apk
# indexes. Probe with ping plus a bounded HTTPS fetch first so retries stay
# cheap; apk update itself is retried because parallel index fetches still hit
# transient wget EPERM after netifd/fw4 reloads.
egress_ready=0
egress_attempt=0
while [ "$egress_attempt" -lt 15 ]; do
    egress_attempt=$((egress_attempt + 1))
    printf 'vm-test: WAN egress probe attempt %s/15\n' "$egress_attempt" >&2
    if ping -c 1 -W 2 192.168.2.1 >/tmp/vm-test-ping-probe 2>&1 &&
        uclient-fetch -T 10 -O /dev/null https://downloads.openwrt.org/ \
            >/tmp/vm-test-wget-probe 2>&1; then
        egress_ready=1
        break
    fi
    sleep 2
done
apk_ready=0
apk_attempt=0
if [ "$egress_ready" = 1 ]; then
    while [ "$apk_attempt" -lt 5 ]; do
        apk_attempt=$((apk_attempt + 1))
        printf 'vm-test: WAN apk update attempt %s/5\n' "$apk_attempt" >&2
        if apk update >/tmp/vm-test-apk-update 2>&1; then
            apk_ready=1
            break
        fi
        sleep $((apk_attempt * 2))
    done
fi
if [ "$apk_ready" != 1 ]; then
    {
        printf 'apk update failed after %s egress / %s apk attempts\n' \
            "$egress_attempt" "$apk_attempt"
        printf '%s\n' '--- ping probe ---'
        cat /tmp/vm-test-ping-probe 2>&1 || :
        printf '%s\n' '--- wget probe ---'
        cat /tmp/vm-test-wget-probe 2>&1 || :
        printf '%s\n' '--- apk update output ---'
        cat /tmp/vm-test-apk-update 2>&1 || :
        printf '%s\n' '--- WAN status ---'
        ifstatus wan || :
        printf '%s\n' '--- resolv.conf.auto ---'
        cat /tmp/resolv.conf.d/resolv.conf.auto 2>&1 || :
        printf '%s\n' '--- ip route ---'
        ip -4 route || :
    } >/tmp/vm-test-failure-detail 2>&1 || :
    fail 'apk update failed after WAN recovery'
fi

# QEMU user networking exposes its synthetic ISP resolver at 192.168.2.3 but
# does not reliably pass direct public UDP/53, which AdGuard Home normally uses
# to bootstrap named DoH upstreams.  Seed only the stable VM's disposable hosts
# file so later HTTPS/idempotency checks exercise AdGuard without pretending to
# validate external bootstrap reachability.  The live profile deliberately
# keeps the production bootstrap path untouched.
if [ "$profile" = stable ]; then
    for upstream_spec in \
        '9.9.9.9|dns.quad9.net' \
        '1.1.1.2|security.cloudflare-dns.com' \
        '76.76.2.11|freedns.controld.com'; do
        upstream_address=${upstream_spec%%|*}
        upstream_host=${upstream_spec#*|}
        printf '%s %s\n' "$upstream_address" "$upstream_host" >>/etc/hosts
    done
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
export COUNTRY='US'
export CHANNEL='36'
export DNS_REBIND_DOMAIN='VM.Example'
export ADGUARD_USERNAME='admin'
# shellcheck disable=SC2016 # Literal bcrypt hash; dollar signs must not expand.
export ADGUARD_PASSWORD_HASH='$2y$04$B9b7J6M1xwkLCfIRfpm7S.c8T3EPROaz2EJ1/CM2IpkAMGI1euIcy'
export VPN_IF='wgserver'
export VPN_PORT='42451'
export VPN_KEY="$server_private"
export VPN_ADDR='10.10.0.1/24'

run_and_confirm() {
    setup_pass=${1:-unnamed}
    ./setup.sh --recovery-ready >/tmp/setup.log 2>&1 &
    setup_pid=$!
    pending=
    attempts=0
    # Package install plus AdGuard Home apply/reload can exceed three
    # minutes on the emulated AArch64 CI VM, so wait well beyond that.
    while [ "$attempts" -lt 900 ]; do
        attempts=$((attempts + 1))
        pending=$(find /root/router-config-backups -name pending -type f 2>/dev/null | sort | tail -n 1)
        [ -z "$pending" ] || break
        kill -0 "$setup_pid" 2>/dev/null || {
            setup_status=0
            wait "$setup_pid" || setup_status=$?
            {
                printf 'setup pass: %s\n' "$setup_pass"
                printf 'setup pid exited with status: %s\n' "$setup_status"
                printf '%s\n' '--- WAN UCI ---'
                uci -q show network.wan || :
                printf '%s\n' '--- ip route ---'
                ip -4 route || :
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

run_and_confirm first
check_ap_interfaces 'after first installation'
export_normalized_uci >/tmp/first.export
fw4 check || fail 'fw4 rejected installed configuration'
! uci -q show firewall | grep -Eq "\.name='(Allow-IPSec-ESP|Allow-ISAKMP)'" ||
    fail 'obsolete stock IPsec forwarding rules survived migration'
[ "$(uci -q get network.lan || :)" = '' ] || fail 'stock LAN survived migration'
[ "$(uci -q get network.wan6 || :)" = '' ] || fail 'wan6 survived migration'
[ "$(uci -q get network.wan.proto)" = static ] || fail 'WAN was not pinned static'
[ "$(uci -q get network.wan.ipaddr)" = 192.168.2.2 ] || fail 'WAN address was not set to 192.168.2.2'
[ "$(uci -q get network.wan.netmask)" = 255.255.255.0 ] || fail 'WAN netmask was not set'
[ "$(uci -q get network.wan.gateway)" = 192.168.2.1 ] || fail 'WAN gateway was not set to 192.168.2.1'
[ "$(uci -q get firewall.wan.network)" = wan ] || fail 'WAN zone was not normalized'
[ "$(uci -q get firewall.defaults.flow_offloading)" = 1 ] || fail 'software flow offloading is not enabled'
[ "$(uci -q get firewall.defaults.flow_offloading_hw)" = 1 ] || fail 'hardware flow offloading is not enabled'
[ "$(uci -q get attendedsysupgrade.client.login_check_for_upgrades)" = 1 ] ||
    fail 'LuCI login upgrade check is not enabled'
[ "$(uci -q get dhcp.dnsmasq.port)" = 54 ] || fail 'dnsmasq is not on port 54'
[ "$(uci -q get dhcp.dnsmasq.cachesize)" = 0 ] || fail 'dnsmasq cache is not disabled'
[ -z "$(uci -q get dhcp.dnsmasq.server || :)" ] || fail 'dnsmasq retained a public upstream'
for dhcp_dns_spec in \
    pixel:192.168.8.1 pixelguest:192.168.9.1 \
    pixeliot:192.168.10.1 pixelthings:192.168.11.1; do
    dhcp_section=${dhcp_dns_spec%%:*}
    dhcp_gateway=${dhcp_dns_spec#*:}
    [ "$(uci -q get "dhcp.$dhcp_section.dhcp_option")" = "6,$dhcp_gateway" ] ||
        fail "DHCP does not advertise AdGuard Home on $dhcp_section"
done
[ "$(uci -q get adguardhome.config.config_file)" = /etc/adguardhome/adguardhome.yaml ] ||
    fail 'AdGuard Home UCI config path is incorrect'
[ "$(uci -q get adguardhome.config.work_dir)" = /opt/adguardhome ] ||
    fail 'AdGuard Home work directory is not persistent'
/etc/init.d/adguardhome enabled >/dev/null 2>&1 || fail 'AdGuard Home is not enabled after confirmation'
/usr/bin/AdGuardHome --check-config --config /etc/adguardhome/adguardhome.yaml --no-check-update ||
    fail 'installed AdGuard Home configuration is invalid'
grep -Fq -- '@@||vm.example^' /etc/adguardhome/adguardhome.yaml ||
    fail 'AdGuard Home DNS rebind exception is missing'
for adguard_user_rule in \
    '@@||steamconnecttest.com^' \
    '@@||ipv6check-udp.steamserver.net^' \
    '@@||ipv6check-http.steamserver.net^' \
    '@@||suggestqueries*.youtube.com^' \
    '@@||suggestqueries.google.com^' \
    '@@||clients1.google.com^' \
    '@@||clients2.google.com^' \
    '@@||clients3.google.com^' \
    '@@||clients.l.google.com^' \
    '@@||script.google.com^' \
    '@@||script.googleusercontent.com^' \
    '@@||doc-*-docstext.googleusercontent.com^'; do
    grep -Fq -- "'$adguard_user_rule'" /etc/adguardhome/adguardhome.yaml ||
        fail "AdGuard Home default whitelist rule is missing: $adguard_user_rule"
done
grep -Eq "^[[:space:]]*-[[:space:]]*${VPN_ADDR%/*}[[:space:]]*$" \
    /etc/adguardhome/adguardhome.yaml ||
    fail 'AdGuard Home WireGuard DNS listener is missing'
grep -Fqx '  blocking_mode: nxdomain' /etc/adguardhome/adguardhome.yaml ||
    fail 'AdGuard Home blocking mode is not NXDOMAIN'
enabled_filter_count=$(awk '
    /^filters:/ { in_filters = 1; next }
    /^whitelist_filters:/ { in_filters = 0 }
    in_filters && /^[[:space:]]*-?[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$/ { count++ }
    END { print count + 0 }
' /etc/adguardhome/adguardhome.yaml)
[ "$enabled_filter_count" = 26 ] ||
    fail 'AdGuard Home does not contain exactly 26 enabled filters'
grep -Eq '^[[:space:]]*name:[[:space:]]*AdGuard DNS filter[[:space:]]*$' \
    /etc/adguardhome/adguardhome.yaml ||
    fail 'AdGuard DNS filter is not enabled'
grep -Eq '^[[:space:]]*name:[[:space:]]*AdAway Default Blocklist[[:space:]]*$' \
    /etc/adguardhome/adguardhome.yaml ||
    fail 'AdAway Default Blocklist is not enabled'
grep -Eq '^[[:space:]]*name:[[:space:]]*HaGeZi DNS Rebind Protection[[:space:]]*$' \
    /etc/adguardhome/adguardhome.yaml ||
    fail 'HaGeZi DNS Rebind Protection is not enabled'
[ "$(grep -Ec '^[[:space:]]*interval:[[:space:]]*7d[[:space:]]*$' \
    /etc/adguardhome/adguardhome.yaml)" = 2 ] ||
    fail 'AdGuard Home retention is not seven days'
check_dns_listeners 'after first installation'
[ -z "$(uci -q show network | sed -n "/=wireguard_${VPN_IF}$/p")" ] ||
    fail 'fresh installation created a WireGuard peer'
[ "$(uci -q get "network.${VPN_IF}.addresses")" = "$VPN_ADDR" ] ||
    fail 'WireGuard server address is not installed'
wg show "$VPN_IF" >/dev/null || fail 'WireGuard server interface is not available'
[ -z "$(wg show "$VPN_IF" peers)" ] || fail 'fresh WireGuard server has a runtime peer'
grep -qx 'options mt7915e wed_enable=Y' /etc/modules.conf || fail 'WED is not enabled in modules.conf'
wed_count=$(grep -c 'wed_enable=' /etc/modules.conf || :)
[ "$wed_count" = 1 ] || fail 'modules.conf has duplicate WED options'
[ "$(uci -q get chrony.cloudflare.nts)" = 1 ] || fail 'Cloudflare NTS server is missing'
[ "$(uci -q get chrony.netnod.nts)" = 1 ] || fail 'Netnod NTS server is missing'
[ "$(uci -q get chrony.time_nl.nts)" = 1 ] || fail 'time.nl NTS server is missing'
[ "$(uci -q get chrony.cloudflare.prefer)" = 1 ] || fail 'Cloudflare NTS server is not preferred'
[ "$(uci -q get chrony.netnod.prefer)" = 1 ] || fail 'Netnod NTS server is not preferred'
[ "$(uci -q get chrony.time_nl.prefer)" = 1 ] || fail 'time.nl NTS server is not preferred'
[ "$(uci -q get chrony.bootstrap_1.nts)" = 0 ] || fail 'NTP bootstrap source is missing'
[ -z "$(uci -q get chrony.bootstrap_1.prefer || :)" ] || fail 'NTP bootstrap source is preferred'
[ "$(uci -q get chrony.dhcp_ntp_server.disabled)" = 1 ] || fail 'DHCP NTP sources are still enabled'
/etc/init.d/sysntpd enabled >/dev/null 2>&1 && fail 'sysntpd is still enabled'
/etc/init.d/chronyd enabled >/dev/null 2>&1 || fail 'chronyd is not enabled'
auth_policy_count=$(
    awk '
        previous == "authselectmode ignore" &&
            $0 == "confdir /var/etc/chrony.d" { count++ }
        { previous = $0 }
        END { print count + 0 }
    ' /etc/chrony/chrony.conf
)
[ "$auth_policy_count" = 1 ] ||
    fail 'Chrony authselectmode policy is missing or incorrectly ordered'
for nts_host in time.cloudflare.com nts.netnod.se ntppool1.time.nl; do
    grep -Eq "^server ${nts_host}([[:space:]].*)?[[:space:]]nts[[:space:]]prefer([[:space:]]|$)" \
        /var/etc/chrony.d/10-uci.conf ||
        fail "generated Chrony config lacks nts prefer for $nts_host"
done
for bootstrap_ip in 194.177.4.1 213.222.217.11 80.50.102.114 193.219.28.60; do
    bootstrap_line=$(grep -E "^server ${bootstrap_ip}([[:space:]]|$)" /var/etc/chrony.d/10-uci.conf || :)
    [ -n "$bootstrap_line" ] || fail "generated Chrony config lacks bootstrap $bootstrap_ip"
    case $bootstrap_line in
        *" nts"* | *" prefer"*) fail "bootstrap $bootstrap_ip has nts or prefer in generated config" ;;
    esac
done
chrony_selectdata=$(chronyc -n selectdata -a 2>/dev/null) ||
    fail 'chronyc selectdata failed'
preferred_source_count=$(
    printf '%s\n' "$chrony_selectdata" |
        awk 'NR > 2 && $4 ~ /P/ && $5 !~ /[RT]/ { count++ } END { print count + 0 }'
)
[ "$preferred_source_count" -ge 3 ] ||
    fail 'NTS sources lack effective preference without implicit require/trust'
for bootstrap_ip in 194.177.4.1 213.222.217.11 80.50.102.114 193.219.28.60; do
    printf '%s\n' "$chrony_selectdata" |
        awk -v ip="$bootstrap_ip" '
            $2 == ip && $4 !~ /P/ && $5 !~ /[RT]/ { found = 1 }
            END { exit(found ? 0 : 1) }
        ' || fail "bootstrap $bootstrap_ip is preferred or waiting on authenticated selection"
done
for port in lan1 lan2 lan3 lan4 lan5; do
    uci -q get network.br_lan.ports | tr ' ' '\n' | grep -qx "$port" || fail "$port is absent from bridge"
done
for net in pixel pixelguest pixeliot pixelthings; do
    uci -q get "firewall.divert_dns_$net.src" | grep -qx "$net" || fail "missing DNS interception for $net"
    uci -q get "firewall.reject_dot_$net.src" | grep -qx "$net" || fail "missing DoT rejection for $net"
    uci -q get "firewall.reject_doq_$net.src" | grep -qx "$net" || fail "missing DoQ rejection for $net"
    [ "$(uci -q get "firewall.reject_dot_$net.dest")" = '*' ] || fail "DoT rejection is not destination-independent for $net"
    [ "$(uci -q get "firewall.reject_dot_$net.dest_port")" = 853 ] || fail "invalid DoT/standard DoQ port for $net"
    [ "$(uci -q get "firewall.reject_dot_$net.proto")" = 'tcp udp' ] || fail "invalid DoT/standard DoQ protocols for $net"
    [ "$(uci -q get "firewall.reject_doq_$net.dest")" = '*' ] || fail "alternate DoQ rejection is not destination-independent for $net"
    [ "$(uci -q get "firewall.reject_doq_$net.dest_port")" = 8853 ] || fail "invalid alternate DoQ port for $net"
    [ "$(uci -q get "firewall.reject_doq_legacy_$net.src")" = "$net" ] || fail "missing legacy DoQ rejection for $net"
    [ "$(uci -q get "firewall.reject_doq_legacy_$net.dest")" = '*' ] || fail "legacy DoQ rejection is not destination-independent for $net"
    [ "$(uci -q get "firewall.reject_doq_legacy_$net.dest_port")" = 784 ] || fail "invalid legacy DoQ port for $net"
done
uci -q get firewall.pixel.forward | grep -qx ACCEPT ||
    fail 'Pixel zone does not accept intra-zone forwarding'
for net in pixelguest pixelthings pixeliot; do
    uci -q get "firewall.$net.forward" | grep -qx REJECT ||
        fail "$net zone does not reject intra-zone forwarding"
    rule="firewall.reject_isp_transit_$net"
    [ "$(uci -q get "$rule")" = rule ] || fail "missing ISP transit rejection for $net"
    [ "$(uci -q get "$rule.src")" = "$net" ] || fail "invalid ISP transit rejection source for $net"
    [ "$(uci -q get "$rule.dest")" = wan ] || fail "invalid ISP transit rejection zone for $net"
    [ "$(uci -q get "$rule.dest_ip")" = 192.168.2.0/24 ] || fail "invalid ISP transit rejection subnet for $net"
    [ "$(uci -q get "$rule.family")" = ipv4 ] || fail "invalid ISP transit rejection family for $net"
    [ "$(uci -q get "$rule.proto")" = all ] || fail "invalid ISP transit rejection protocol for $net"
    [ "$(uci -q get "$rule.target")" = REJECT ] || fail "invalid ISP transit rejection target for $net"
done
uci -q get firewall.pixeliot_dhcp_reply.dest | grep -qx pixeliot || fail 'missing outbound IoT DHCP exception'
uci -q get firewall.pixeliot_dhcp_reply.src_port | grep -qx 67 || fail 'invalid IoT DHCP reply source port'
uci -q get firewall.pixeliot_dhcp_reply.dest_port | grep -qx 68 || fail 'invalid IoT DHCP reply destination port'

run_and_confirm second
check_ap_interfaces 'after second installation'
export_normalized_uci >/tmp/second.export
if ! cmp -s /tmp/first.export /tmp/second.export; then
    diff -u /tmp/first.export /tmp/second.export >/tmp/vm-test-failure-detail 2>&1 || :
    fail 'second installation changed normalized UCI exports'
fi

# Live upstream checks belong on the just-applied managed config, before
# rollback churn. Package install already proved WAN HTTPS works; wait for the
# same egress path again because netifd/fw4 reloads can briefly EPERM outbound
# sockets the way apk's wget does.
if [ "$profile" = live ]; then
    /etc/init.d/chronyd stop || fail 'failed to stop chronyd for cold-boot test'
    /etc/init.d/adguardhome stop || :
    /etc/init.d/dnsmasq stop || fail 'failed to stop dnsmasq for cold-boot test'
    rm -f /var/run/chrony/* /var/run/chrony-dhcp/*
    date -s '2020-01-01 00:00:00' >/dev/null ||
        fail 'failed to set disposable VM clock for cold-boot test'
    cold_boot_epoch=$(date +%s)
    /etc/init.d/chronyd start || fail 'failed to start chronyd for cold-boot test'
    cold_boot_synced=0
    cold_boot_attempt=0
    while [ "$cold_boot_attempt" -lt 90 ]; do
        cold_boot_attempt=$((cold_boot_attempt + 1))
        cold_boot_source=$(
            chronyc -n sources 2>/dev/null |
                awk '
                    $1 == "^*" &&
                        ($2 == "194.177.4.1" ||
                         $2 == "213.222.217.11" ||
                         $2 == "80.50.102.114" ||
                         $2 == "193.219.28.60") {
                        print $2
                        exit
                    }
                '
        )
        if [ -n "$cold_boot_source" ] &&
            [ "$(date +%s)" -gt "$((cold_boot_epoch + 86400))" ]; then
            cold_boot_synced=1
            break
        fi
        sleep 2
    done
    if [ "$cold_boot_synced" != 1 ]; then
        {
            printf 'cold-boot source: %s\n' "${cold_boot_source:-none}"
            printf 'cold-boot start epoch: %s\n' "$cold_boot_epoch"
            printf 'current epoch: %s\n' "$(date +%s)"
            printf '%s\n' '--- chronyc tracking ---'
            chronyc -n tracking 2>&1 || :
            printf '%s\n' '--- chronyc sources ---'
            chronyc -n sources -v 2>&1 || :
            printf '%s\n' '--- chronyc selectdata ---'
            chronyc -n selectdata -a 2>&1 || :
        } >/tmp/vm-test-failure-detail
        fail 'plain numeric NTP did not step the bad clock while DNS was unavailable'
    fi
    /etc/init.d/dnsmasq start || fail 'failed to restore dnsmasq after cold-boot test'
    /etc/init.d/adguardhome start || fail 'failed to restore AdGuard Home after cold-boot test'
    chronyc refresh >/dev/null 2>&1 || fail 'failed to refresh Chrony source resolution'
    nts_authenticated=0
    nts_attempt=0
    while [ "$nts_attempt" -lt 60 ]; do
        nts_attempt=$((nts_attempt + 1))
        if chronyc -N authdata -a >/tmp/vm-test-chrony-authdata 2>&1 &&
            grep -Eq '[[:space:]]NTS[[:space:]]' /tmp/vm-test-chrony-authdata; then
            nts_authenticated=1
            break
        fi
        sleep 2
    done
    if [ "$nts_authenticated" != 1 ]; then
        {
            printf '%s\n' '--- chronyc authdata ---'
            cat /tmp/vm-test-chrony-authdata 2>&1 || :
            printf '%s\n' '--- chronyc sources ---'
            chronyc -n sources -v 2>&1 || :
        } >/tmp/vm-test-failure-detail
        fail 'NTS did not authenticate after DNS recovery'
    fi
    check_dns_listeners 'before live AdGuard Home checks'
    live_egress_ready=0
    live_egress_attempt=0
    while [ "$live_egress_attempt" -lt 15 ]; do
        live_egress_attempt=$((live_egress_attempt + 1))
        printf 'vm-test: live DNS egress probe attempt %s/15\n' "$live_egress_attempt" >&2
        if ping -c 1 -W 2 192.168.2.1 >/tmp/vm-test-live-doh-ping 2>&1 &&
            uclient-fetch -T 10 -O /dev/null https://downloads.openwrt.org/ \
                >/tmp/vm-test-live-doh-wget 2>&1; then
            live_egress_ready=1
            break
        fi
        # Explicit fw4 refresh absorbs the same post-reload EPERM race seen by
        # apk; keep the managed candidate intact.
        /etc/init.d/firewall reload >/tmp/vm-test-live-doh-fw 2>&1 || :
        sleep 2
    done
    if [ "$live_egress_ready" != 1 ]; then
        {
            printf 'live DNS egress failed after %s attempts\n' "$live_egress_attempt"
            printf '%s\n' '--- ping probe ---'
            cat /tmp/vm-test-live-doh-ping 2>&1 || :
            printf '%s\n' '--- wget probe ---'
            cat /tmp/vm-test-live-doh-wget 2>&1 || :
            printf '%s\n' '--- firewall reload ---'
            cat /tmp/vm-test-live-doh-fw 2>&1 || :
            printf '%s\n' '--- WAN status ---'
            ifstatus wan || :
            printf '%s\n' '--- ip route ---'
            ip -4 route || :
        } >/tmp/vm-test-failure-detail 2>&1 || :
        fail 'live DNS egress was not ready'
    fi
    /etc/init.d/adguardhome restart || fail 'failed to restart AdGuard Home for live DNS'
    check_dns_listeners 'after live AdGuard Home restart'
    dns_ok=0
    dns_attempt=0
    while [ "$dns_attempt" -lt 12 ]; do
        dns_attempt=$((dns_attempt + 1))
        if dig +time=5 +tries=1 @127.0.0.1 -p 53 example.com A \
            >/tmp/vm-test-live-dns-dig 2>&1 &&
            grep -q 'status: NOERROR' /tmp/vm-test-live-dns-dig; then
            dns_ok=1
            break
        fi
        sleep 2
    done
    [ "$dns_ok" = 1 ] || fail 'live AdGuard Home DNS query failed'
    filter_ready=0
    filter_attempt=0
    while [ "$filter_attempt" -lt 90 ]; do
        filter_attempt=$((filter_attempt + 1))
        filter_count=$(find /opt/adguardhome/data/filters -type f -name '*.txt' 2>/dev/null | wc -l)
        [ "$filter_count" -ge 26 ] && {
            filter_ready=1
            break
        }
        sleep 2
    done
    [ "$filter_ready" = 1 ] || fail 'AdGuard Home did not download all enabled filters'
fi

check_dns_listeners 'before rollback'
/usr/libexec/router-config rollback "$LAST_TX"
[ "$(cat "/root/router-config-backups/$LAST_TX/state")" = rolledback ] || fail 'manual rollback did not complete'
check_dns_listeners 'after manual rollback'
check_ap_interfaces 'after manual rollback'

boot_prepare=$(./router-config.sh prepare --recovery-ready)
boot_tx=$(printf '%s\n' "$boot_prepare" | tail -n 1)
touch "/root/router-config-backups/$boot_tx/pending"
printf '%s\n' pending >"/root/router-config-backups/$boot_tx/state"
/etc/init.d/router-config-rollback start
[ "$(cat "/root/router-config-backups/$boot_tx/state")" = rolledback ] || fail 'early-boot service did not recover pending state'
/etc/init.d/adguardhome enabled >/dev/null 2>&1 ||
    fail 'early-boot recovery did not restore AdGuard Home enablement'
# The rollback hook runs at START=05 and deliberately leaves service startup to
# the later normal boot sequence.  This VM invokes the hook after boot, so
# emulate those later init stages before checking runtime listeners.
/etc/init.d/dnsmasq restart || fail 'dnsmasq failed after early-boot recovery'
/etc/init.d/adguardhome start || fail 'AdGuard Home failed after early-boot recovery'
recovery_dns_ready=0
recovery_dns_attempt=0
while [ "$recovery_dns_attempt" -lt 15 ]; do
    recovery_dns_attempt=$((recovery_dns_attempt + 1))
    if ss -lntu | grep -Eq '(^|[.:])53[[:space:]]' &&
        ss -lntu | grep -Eq '(^|[.:])54[[:space:]]' &&
        ss -lnt | grep -Eq '192\.168\.8\.1:3000[[:space:]]'; then
        recovery_dns_ready=1
        break
    fi
    sleep 1
done
[ "$recovery_dns_ready" = 1 ] || fail 'DNS services did not become ready after early-boot recovery'
check_dns_listeners 'after early-boot recovery'
check_ap_interfaces 'after early-boot recovery'

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
ip netns exec pixel1 ping -c 1 -W 2 192.168.9.1 >/dev/null || fail 'Pixel cannot reach Guest gateway'
! ip netns exec guest ping -c 1 -W 2 192.168.8.1 >/dev/null 2>&1 || fail 'Guest reached Pixel gateway'
! ip netns exec iot ping -c 1 -W 2 192.168.8.1 >/dev/null 2>&1 || fail 'IoT reached Pixel gateway'
! ip netns exec things ping -c 1 -W 2 192.168.8.1 >/dev/null 2>&1 || fail 'Things reached Pixel gateway'

[ "$(uci get uhttpd.main.listen_http)" = '192.168.8.1:80' ] ||
    fail 'uhttpd HTTP listen is not bound to Pixel'
[ "$(uci get uhttpd.main.listen_https)" = '192.168.8.1:443' ] ||
    fail 'uhttpd HTTPS listen is not bound to Pixel'
[ "$(uci get dropbear.main.DirectInterface)" = pixel ] ||
    fail 'dropbear DirectInterface is not pixel'
! uci -q get dropbear.main.Interface >/dev/null || fail 'dropbear Interface must remain unset'

ss -ltn >/tmp/vm-test-admin-listeners 2>&1 || fail 'ss failed while checking admin listeners'
grep -E '192\.168\.8\.1:80\b' /tmp/vm-test-admin-listeners >/dev/null ||
    fail 'uhttpd is not listening on 192.168.8.1:80'
grep -E '192\.168\.8\.1:443\b' /tmp/vm-test-admin-listeners >/dev/null ||
    fail 'uhttpd is not listening on 192.168.8.1:443'
! grep -E '192\.168\.(9|10|11)\.1:(22|80|443)\b' /tmp/vm-test-admin-listeners >/dev/null ||
    fail 'admin service is still listening on a restricted VLAN gateway'
grep -E '(:22\b|192\.168\.8\.1:22\b)' /tmp/vm-test-admin-listeners >/dev/null ||
    fail 'dropbear is not listening on port 22'

http_probe() {
    ip netns exec "$1" wget -q -T 2 -O /dev/null "http://$2/" >/dev/null 2>&1
}

# Pixel reachability is covered by the 192.168.8.1 ss listeners above.
# Restricted VLANs must not answer HTTP on their own gateway addresses.
! http_probe guest 192.168.9.1 || fail 'Guest reached LuCI HTTP on its own gateway'
! http_probe iot 192.168.10.1 || fail 'IoT reached LuCI HTTP on its own gateway'
! http_probe things 192.168.11.1 || fail 'Things reached LuCI HTTP on its own gateway'
! http_probe guest 192.168.9.1:3000 || fail 'Guest reached AdGuard Home on its own gateway'
! http_probe iot 192.168.10.1:3000 || fail 'IoT reached AdGuard Home on its own gateway'
! http_probe things 192.168.11.1:3000 || fail 'Things reached AdGuard Home on its own gateway'

# A local deterministic answer proves that queries sent to a nonexistent
# external resolver are intercepted at port 53.
uci -q del_list dhcp.dnsmasq.address='/vm.lan/203.0.113.7' 2>/dev/null || :
uci add_list dhcp.dnsmasq.address='/vm.lan/203.0.113.7'
uci commit dhcp
/etc/init.d/dnsmasq restart
dns_ready=0
dns_attempt=0
while [ "$dns_attempt" -lt 30 ]; do
    dns_attempt=$((dns_attempt + 1))
    if dig +short +time=1 +tries=1 @127.0.0.1 -p 54 vm.lan A \
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
! ip netns exec pixel1 dig +short +time=1 +tries=1 \
    @192.168.8.1 -p 54 vm.lan A >/dev/null 2>&1 ||
    fail 'Pixel bypassed AdGuard Home through dnsmasq port 54'

isp_transit_counter() {
    nft list chain inet fw4 "forward_$1" 2>/dev/null |
        sed -n "/Reject-ISP-Transit-$2/s/.*counter packets \\([0-9][0-9]*\\).*/\\1/p" |
        head -n 1
}

ip netns exec pixel1 ping -c 1 -W 2 192.168.2.1 >/dev/null ||
    fail 'Pixel cannot reach the ISP transit gateway'
for client in guest things iot; do
    case $client in
        guest)
            transit_zone=pixelguest
            transit_label=PixelGuest
            ;;
        things)
            transit_zone=pixelthings
            transit_label=PixelThings
            ;;
        iot)
            transit_zone=pixeliot
            transit_label=PixelIoT
            ;;
    esac
    transit_before=$(isp_transit_counter "$transit_zone" "$transit_label")
    [ -n "$transit_before" ] || fail "$transit_label ISP transit rejection has no nftables counter"
    ! ip netns exec "$client" ping -c 1 -W 2 192.168.2.1 >/dev/null 2>&1 ||
        fail "$transit_label reached the ISP transit gateway"
    transit_after=$(isp_transit_counter "$transit_zone" "$transit_label")
    if [ -z "$transit_after" ] || [ "$transit_after" -le "$transit_before" ]; then
        {
            printf '%s ISP transit reject packets before: %s\n' "$transit_label" "$transit_before"
            printf '%s ISP transit reject packets after: %s\n' "$transit_label" "${transit_after:-missing}"
            printf '%s\n' "--- $transit_label forward nftables chain ---"
            nft list chain inet fw4 "forward_$transit_zone" || :
            printf '%s\n' "--- $transit_label routes ---"
            ip -n "$client" route || :
        } >/tmp/vm-test-failure-detail 2>&1
        fail "$transit_label ISP transit rejection counter did not increase"
    fi
done

dns_before=$(nft list ruleset |
    sed -n '/PixelGuest-Divert-DNS/s/.*counter packets \([0-9][0-9]*\).*/\1/p' |
    head -n 1)
[ -n "$dns_before" ] || fail 'Guest DNS interception rule has no nftables counter'
if ! ip netns exec guest dig +short +time=3 +tries=1 \
    @203.0.113.250 vm.lan A >/tmp/vm-test-dns-intercepted 2>&1 ||
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
# Drop the production ISP gateway; the isolated WireGuard/DoT peer is on-link.
uci -q delete network.wan.gateway
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
# Count every Guest TCP/853 forward reject.
guest_dot_counter() {
    nft list chain inet fw4 forward_pixelguest 2>/dev/null |
        sed -n 's/.*tcp dport 853 counter packets \([0-9][0-9]*\).*/\1/p' |
        awk '{ total += $1 } END { print total + 0 }'
}
dot_before=$(guest_dot_counter)
dot_rule_count=$(
    nft list chain inet fw4 forward_pixelguest 2>/dev/null |
        grep -c 'tcp dport 853' || :
)
[ "$dot_rule_count" -ge 1 ] || fail 'DoT rule has no nftables counter'
# bind-dig is installed above and +tcp guarantees a TCP connection attempt.
# Do not rely on the image's optional BusyBox nc applet for this assertion.
ip netns exec guest dig +tcp +time=1 +tries=1 \
    @198.18.0.2 -p 853 vm.test A >/tmp/vm-test-dot-probe 2>&1 || :
dot_after=$(guest_dot_counter)
if [ "$dot_after" -le "$dot_before" ]; then
    {
        printf 'Guest TCP/853 reject packets before: %s\n' "$dot_before"
        printf 'Guest TCP/853 reject packets after: %s\n' "$dot_after"
        printf '%s\n' '--- PixelGuest forward DoT nftables rules ---'
        nft list chain inet fw4 forward_pixelguest |
            sed -n '/tcp dport 853/p' || :
        printf '%s\n' '--- WAN status ---'
        ifstatus wan || :
        printf '%s\n' '--- Guest routes ---'
        ip -n guest route || :
        printf '%s\n' '--- DoT probe output ---'
        cat /tmp/vm-test-dot-probe || :
    } >/tmp/vm-test-failure-detail 2>&1
    fail 'DoT rejection counter did not increase'
fi
# Count Guest UDP/8853 forward rejects (DoQ alternate port; RFC DoQ on UDP/853
# is already covered by the DoT tcp/udp 853 rules above).
guest_doq_counter() {
    nft list chain inet fw4 forward_pixelguest 2>/dev/null |
        sed -n 's/.*udp dport 8853 counter packets \([0-9][0-9]*\).*/\1/p' |
        awk '{ total += $1 } END { print total + 0 }'
}
doq_before=$(guest_doq_counter)
doq_rule_count=$(
    nft list chain inet fw4 forward_pixelguest 2>/dev/null |
        grep -c 'udp dport 8853' || :
)
[ "$doq_rule_count" -ge 1 ] || fail 'DoQ rule has no nftables counter'
ip netns exec guest dig +time=1 +tries=1 \
    @198.18.0.2 -p 8853 vm.test A >/tmp/vm-test-doq-probe 2>&1 || :
doq_after=$(guest_doq_counter)
if [ "$doq_after" -le "$doq_before" ]; then
    {
        printf 'Guest UDP/8853 reject packets before: %s\n' "$doq_before"
        printf 'Guest UDP/8853 reject packets after: %s\n' "$doq_after"
        printf '%s\n' '--- PixelGuest forward DoQ nftables rules ---'
        nft list chain inet fw4 forward_pixelguest |
            sed -n '/udp dport 8853/p' || :
        printf '%s\n' '--- WAN status ---'
        ifstatus wan || :
        printf '%s\n' '--- Guest routes ---'
        ip -n guest route || :
        printf '%s\n' '--- DoQ probe output ---'
        cat /tmp/vm-test-doq-probe || :
    } >/tmp/vm-test-failure-detail 2>&1
    fail 'DoQ rejection counter did not increase'
fi
# Count Guest UDP/784 forward rejects for legacy DoQ deployments.
guest_doq_legacy_counter() {
    nft list chain inet fw4 forward_pixelguest 2>/dev/null |
        sed -n 's/.*udp dport 784 counter packets \([0-9][0-9]*\).*/\1/p' |
        awk '{ total += $1 } END { print total + 0 }'
}
doq_legacy_before=$(guest_doq_legacy_counter)
doq_legacy_rule_count=$(
    nft list chain inet fw4 forward_pixelguest 2>/dev/null |
        grep -c 'udp dport 784' || :
)
[ "$doq_legacy_rule_count" -ge 1 ] || fail 'legacy DoQ rule has no nftables counter'
ip netns exec guest dig +time=1 +tries=1 \
    @198.18.0.2 -p 784 vm.test A >/tmp/vm-test-doq-legacy-probe 2>&1 || :
doq_legacy_after=$(guest_doq_legacy_counter)
if [ "$doq_legacy_after" -le "$doq_legacy_before" ]; then
    {
        printf 'Guest UDP/784 reject packets before: %s\n' "$doq_legacy_before"
        printf 'Guest UDP/784 reject packets after: %s\n' "$doq_legacy_after"
        printf '%s\n' '--- PixelGuest forward legacy DoQ nftables rules ---'
        nft list chain inet fw4 forward_pixelguest |
            sed -n '/udp dport 784/p' || :
        printf '%s\n' '--- WAN status ---'
        ifstatus wan || :
        printf '%s\n' '--- Guest routes ---'
        ip -n guest route || :
        printf '%s\n' '--- legacy DoQ probe output ---'
        cat /tmp/vm-test-doq-legacy-probe || :
    } >/tmp/vm-test-failure-detail 2>&1
    fail 'legacy DoQ rejection counter did not increase'
fi
printf '%s\n' "$preshared" >/tmp/client-psk
chmod 600 /tmp/client-psk
wg set "$VPN_IF" peer "$client_public" preshared-key /tmp/client-psk \
    allowed-ips 10.10.0.2/32
uci set firewall.allow_wireguard.enabled='0'
uci commit firewall
/etc/init.d/firewall reload
ip netns exec wanclient ip link add wgtest type wireguard
printf '%s\n' "$client_private" >/tmp/client-private
chmod 600 /tmp/client-private
ip netns exec wanclient wg set wgtest private-key /tmp/client-private \
    peer "$server_public" preshared-key /tmp/client-psk allowed-ips 10.10.0.0/24 \
    endpoint 198.18.0.1:42451
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
ip netns exec wanclient dig +short +time=2 +tries=2 \
    @10.10.0.1 vm.lan A >/tmp/vm-test-wireguard-dns 2>&1 ||
    fail 'WireGuard client could not query AdGuard Home directly'
grep -qx 203.0.113.7 /tmp/vm-test-wireguard-dns ||
    fail 'WireGuard direct DNS query returned an unexpected answer'
ip netns exec wanclient dig +short +time=2 +tries=2 \
    @10.10.0.99 vm.lan A >/tmp/vm-test-wireguard-hijack 2>&1 ||
    fail 'WireGuard DNS interception did not answer a diverted query'
grep -qx 203.0.113.7 /tmp/vm-test-wireguard-hijack ||
    fail 'WireGuard diverted DNS query returned an unexpected answer'
! ip netns exec wanclient dig +short +time=1 +tries=1 \
    @10.10.0.1 -p 54 vm.lan A >/dev/null 2>&1 ||
    fail 'WireGuard client bypassed AdGuard Home through dnsmasq port 54'

# Exercise a real watchdog rollback and a missing-port preflight rejection.
prepare_output=$(./router-config.sh prepare --recovery-ready)
timeout_tx=$(printf '%s\n' "$prepare_output" | tail -n 1)
export_normalized_uci >/tmp/timeout-before.uci
cp /etc/modules.conf /tmp/timeout-before.modules.conf
cp /etc/chrony/chrony.conf /tmp/timeout-before.chrony.conf
rm -f /tmp/timeout-apply.pid /tmp/timeout-apply.log
# shellcheck disable=SC2016 # Expanded by the inner shell after setsid.
setsid sh -c '
    printf "%s\n" "$$" >/tmp/timeout-apply.pid
    exec env ROUTER_CONFIG_TIMEOUT=5 ROUTER_CONFIG_POLL_INTERVAL=1 \
        /usr/libexec/router-config apply "$1"
' sh "$timeout_tx" >/tmp/timeout-apply.log 2>&1 &
timeout_launcher_pid=$!
timeout_ready=0
timeout_attempt=0
while [ "$timeout_attempt" -lt 120 ]; do
    timeout_attempt=$((timeout_attempt + 1))
    timeout_pid_file=/root/router-config-backups/$timeout_tx/watchdog.pid
    if [ -s /tmp/timeout-apply.pid ] &&
        [ -s "$timeout_pid_file" ] &&
        [ ! -e /var/lock/router-config.lock ]; then
        timeout_ready=1
        break
    fi
    sleep 1
done
[ "$timeout_ready" = 1 ] || fail 'watchdog did not become ready for session-loss test'
timeout_apply_pid=$(sed -n '1p' /tmp/timeout-apply.pid)
timeout_watchdog_pid=$(sed -n '1p' "$timeout_pid_file")
timeout_apply_sid=$(awk '{ print $6 }' "/proc/$timeout_apply_pid/stat")
timeout_watchdog_sid=$(awk '{ print $6 }' "/proc/$timeout_watchdog_pid/stat")
[ "$timeout_watchdog_sid" != "$timeout_apply_sid" ] ||
    fail 'watchdog remained in the apply session'
kill -HUP -"$timeout_apply_pid"
wait "$timeout_launcher_pid" 2>/dev/null || :
if kill -0 "$timeout_apply_pid" 2>/dev/null; then
    fail 'foreground apply survived session hangup'
fi
kill -0 "$timeout_watchdog_pid" 2>/dev/null ||
    fail 'watchdog did not survive session hangup'
timeout_attempt=0
while [ "$timeout_attempt" -lt 180 ]; do
    timeout_attempt=$((timeout_attempt + 1))
    [ "$(cat "/root/router-config-backups/$timeout_tx/state")" = rolledback ] && break
    sleep 1
done
[ "$(cat "/root/router-config-backups/$timeout_tx/state")" = rolledback ] || fail 'watchdog did not roll back'
export_normalized_uci >/tmp/timeout-after.uci
if ! cmp -s /tmp/timeout-before.uci /tmp/timeout-after.uci; then
    diff -u /tmp/timeout-before.uci /tmp/timeout-after.uci \
        >/tmp/vm-test-failure-detail 2>&1 || :
    fail 'watchdog did not restore every configuration file'
fi
cmp -s /tmp/timeout-before.modules.conf /etc/modules.conf ||
    fail 'watchdog did not restore modules.conf'
cmp -s /tmp/timeout-before.chrony.conf /etc/chrony/chrony.conf ||
    fail 'watchdog did not restore chrony.conf'
[ ! -e "/root/router-config-backups/$timeout_tx/pending" ] ||
    fail 'watchdog left the pending marker behind'
[ ! -e "$timeout_pid_file" ] || fail 'watchdog left its PID marker behind'
ip link del lan5
if ./router-config.sh prepare --recovery-ready >/tmp/missing-port.log 2>&1; then
    fail 'missing lan5 passed preflight'
fi
grep -q 'required DSA interface missing: lan5' /tmp/missing-port.log || fail 'missing-port rejection was unclear'

printf '%s\n' 'vm-test: stable acceptance suite passed'
