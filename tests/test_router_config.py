import json
import os
import signal
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import pytest


REPO = Path(__file__).parents[1]


UCI_STUB = r'''#!/usr/bin/env python3
import json, os, shlex, sys

args = sys.argv[1:]
quiet = False
config_dir = os.environ.get("UCI_STUB_CONFIG_DIR", "/etc/config")
while args and args[0].startswith("-"):
    if args[0] == "-q":
        quiet = True; args.pop(0)
    elif args[0] == "-c":
        args.pop(0); config_dir = args.pop(0)
    else:
        sys.exit(2)

def load(package):
    with open(os.path.join(config_dir, package), encoding="utf-8") as f:
        content = f.read()
        return json.loads(content) if content.strip() else {}

def save(package, data):
    with open(os.path.join(config_dir, package), "w", encoding="utf-8") as f:
        json.dump(data, f, sort_keys=True)

def split_target(target):
    pieces = target.split(".")
    return pieces[0], pieces[1], ".".join(pieces[2:]) if len(pieces) > 2 else None

def mutate(words):
    command = words[0]
    expression = words[1]
    if command in ("set", "add_list", "del_list"):
        target, value = expression.split("=", 1)
        package, section, option = split_target(target)
        data = load(package)
        if command == "set":
            if option is None:
                old = data.get(section, {})
                data[section] = {".type": value, **{k: v for k, v in old.items() if k != ".type"}}
            else:
                data.setdefault(section, {})[option] = value
        elif command == "add_list":
            current = data.setdefault(section, {}).setdefault(option, [])
            if not isinstance(current, list): current = [current]
            current.append(value); data[section][option] = current
        else:
            current = data.get(section, {}).get(option, [])
            if not isinstance(current, list): current = [current]
            data.get(section, {})[option] = [item for item in current if item != value]
        save(package, data); return 0
    if command == "delete":
        package, section, option = split_target(expression)
        data = load(package)
        if section not in data: return 1
        if option is None: del data[section]
        elif option in data[section]: del data[section][option]
        else: return 1
        save(package, data); return 0
    return 2

command = args.pop(0)
if command == "batch":
    for line in sys.stdin:
        line = line.strip()
        if not line or line.startswith("#"): continue
        if mutate(shlex.split(line)) != 0: sys.exit(1)
    sys.exit(0)
if command == "export":
    package = args[0]
    data = load(package)
    print(f"package {package}")
    for name, section_data in data.items():
        section_type = section_data[".type"]
        if name.startswith("@"): print(f"config {section_type}")
        else: print(f"config {section_type} '{name}'")
        for key, value in section_data.items():
            if key == ".type": continue
            values = value if isinstance(value, list) else [value]
            keyword = "list" if isinstance(value, list) else "option"
            for item in values: print(f"\t{keyword} {key} {shlex.quote(str(item))}")
    sys.exit(0)
if command == "import":
    package = args[0]
    data = {}
    current = None
    anonymous_counts = {}
    for raw in sys.stdin:
        words = shlex.split(raw, comments=True)
        if not words or words[0] == "package": continue
        if words[0] == "config":
            section_type = words[1]
            if len(words) > 2: current = words[2]
            else:
                index = anonymous_counts.get(section_type, 0)
                anonymous_counts[section_type] = index + 1
                current = f"@{section_type}[{index}]"
            data[current] = {".type": section_type}
        elif words[0] in ("option", "list") and current:
            key, value = words[1], words[2]
            if words[0] == "option": data[current][key] = value
            else: data[current].setdefault(key, []).append(value)
    save(package, data)
    sys.exit(0)
if command == "commit": sys.exit(0)
if command == "rename":
    expression = args[0]
    target, new_name = expression.split("=", 1)
    package, section, option = split_target(target)
    if option is not None: sys.exit(2)
    data = load(package)
    if section not in data or new_name in data: sys.exit(1)
    renamed = {}
    for name, value in data.items():
        renamed[new_name if name == section else name] = value
    save(package, renamed); sys.exit(0)
if command in ("set", "add_list", "del_list", "delete"):
    sys.exit(mutate([command, args[0]]))
target = args[0]
if command == "show" and "." not in target:
    package = target
    data = load(package)
    for name, section_data in data.items():
        section_type = section_data['.type']
        print(f"{package}.{name}={section_type}")
        for key, value in section_data.items():
            if key == ".type": continue
            values = value if isinstance(value, list) else [value]
            for item in values: print(f"{package}.{name}.{key}='{item}'")
    sys.exit(0)
package, section, option = split_target(target)
data = load(package)
if command == "get":
    if section.startswith("@defaults["):
        matches = [value for value in data.values() if value.get(".type") == "defaults"]
        if not matches: sys.exit(1)
        value = matches[0].get(option) if option else "defaults"
    elif section not in data: sys.exit(1)
    else: value = data[section].get(option) if option else data[section].get(".type")
    if value is None: sys.exit(1)
    print(" ".join(value) if isinstance(value, list) else value); sys.exit(0)
sys.exit(2)
'''


def write_executable(path: Path, text: str):
    path.write_text(text)
    path.chmod(0o755)


@pytest.fixture
def router():
    # /tmp is mounted noexec in the Codex development container, so command
    # stubs must live on the executable workspace mount.
    tmp_path = Path(tempfile.mkdtemp(prefix=".router-test-", dir=REPO / "tests"))
    config = tmp_path / "config"
    bin_dir = tmp_path / "bin"
    sys_net = tmp_path / "sys" / "class" / "net"
    proc_net = tmp_path / "proc" / "net"
    backups = tmp_path / "backups"
    runtime = tmp_path / "libexec" / "router-config"
    init = tmp_path / "init.d" / "router-config-rollback"
    overlays = tmp_path / "overlays"
    modules = tmp_path / "modules"
    modules_conf = tmp_path / "etc-modules.conf"
    chrony_conf = tmp_path / "chrony.conf"
    adguardhome_config = tmp_path / "adguardhome.yaml"
    config.mkdir(); bin_dir.mkdir(); overlays.mkdir(); modules.mkdir(); proc_net.mkdir(parents=True)
    modules_conf.write_text("# test modules.conf\n")
    chrony_conf.write_text(
        "driftfile /var/run/chrony/chrony.drift\n"
        "confdir /var/etc/chrony.d\n"
    )
    socket_lines = "".join(
        f"   {index}: 0100007F:{port:04X} 00000000:0000 0A\n"
        for index, port in enumerate((53, 54, 3000))
    )
    (proc_net / "tcp").write_text(socket_lines)
    (proc_net / "udp").write_text("".join(
        f"   {index}: 0100007F:{port:04X} 00000000:0000 07\n"
        for index, port in enumerate((53, 54))
    ))
    for name in ("br-lan", "lan1", "lan2", "lan3", "lan4", "lan5"):
        (sys_net / name).mkdir(parents=True)
    for name in ("network", "firewall", "wireless", "admin-access", "attendedsysupgrade", "nts", "adguard-home", "wireguard"):
        shutil.copy(REPO / "uci" / name, overlays / name)
    for name in ("network", "firewall", "wireless", "admin-access", "attendedsysupgrade", "nts", "adguard-home", "wireguard"):
        shutil.copy(REPO / "modules" / f"{name}.sh", modules / f"{name}.sh")

    network = {
        "loopback": {".type": "interface", "proto": "static"},
        "globals": {".type": "globals"},
        "wan": {".type": "interface", "proto": "dhcp"},
        "br_lan": {".type": "device", "name": "br-lan", "type": "bridge", "ports": ["lan1", "lan2", "lan3", "lan4", "lan5"], "stp": "1"},
        "unrelated": {".type": "interface", "proto": "none"},
    }
    firewall = {
        "defaults": {".type": "defaults", "syn_flood": "1", "input": "REJECT", "output": "ACCEPT", "forward": "REJECT"},
        "wan": {".type": "zone", "name": "wan", "network": ["wan"], "input": "REJECT", "output": "ACCEPT", "forward": "DROP"},
        "unrelated": {".type": "rule", "name": "Keep me"},
    }
    wireless = {
        "radio0": {".type": "wifi-device", "type": "mac80211", "band": "5g", "channel": "auto"},
        "radio1": {".type": "wifi-device", "type": "mac80211", "band": "2g", "channel": "auto"},
    }
    dhcp = {
        "dnsmasq": {".type": "dnsmasq", "server": ["old"], "domainneeded": "1"},
        "unrelated": {".type": "dhcp", "interface": "unrelated", "ignore": "1"},
    }
    system = {"ntp": {".type": "timeserver", "server": ["old"]}, "unrelated": {".type": "system", "hostname": "keep"}}
    adguardhome = {
        "config": {
            ".type": "adguardhome",
            "config_file": "/etc/adguardhome/adguardhome.yaml",
            "work_dir": "/var/lib/adguardhome",
            "user": "adguardhome",
            "group": "adguardhome",
            "verbose": "0",
        },
    }
    chrony = {
        "@pool[0]": {".type": "pool", "hostname": "2.openwrt.pool.ntp.org", "iburst": "1"},
        "dhcp_ntp_server": {".type": "dhcp_ntp_server", "iburst": "1", "disabled": "0"},
        "allow": {".type": "allow", "interface": "lan"},
        "makestep": {".type": "makestep", "threshold": "1.0", "limit": "3"},
        "nts": {".type": "nts", "rtccheck": "1", "systemcerts": "1"},
    }
    uhttpd = {
        "main": {
            ".type": "uhttpd",
            "listen_http": ["0.0.0.0:80", "[::]:80"],
            "listen_https": ["0.0.0.0:443", "[::]:443"],
            "redirect_https": "0",
        },
    }
    dropbear = {
        "@dropbear[0]": {
            ".type": "dropbear",
            "PasswordAuth": "on",
            "RootPasswordAuth": "on",
            "Port": "22",
            "enable": "1",
        },
    }
    attendedsysupgrade = {
        "server": {".type": "server", "url": "https://sysupgrade.openwrt.org"},
        "client": {
            ".type": "client",
            "upgrade_packages": "1",
            "auto_search": "0",
            "advanced_mode": "0",
            "login_check_for_upgrades": "0",
        },
    }
    for name, value in (
        ("network", network),
        ("firewall", firewall),
        ("wireless", wireless),
        ("dhcp", dhcp),
        ("system", system),
        ("adguardhome", adguardhome),
        ("chrony", chrony),
        ("uhttpd", uhttpd),
        ("dropbear", dropbear),
        ("attendedsysupgrade", attendedsysupgrade),
    ):
        (config / name).write_text(json.dumps(value))

    write_executable(bin_dir / "uci", UCI_STUB)
    write_executable(bin_dir / "ubus", "#!/bin/sh\nexit 0\n")
    write_executable(bin_dir / "setsid", '''#!/usr/bin/env python3
import os
import sys

if os.environ.get("SETSID_FAIL") == "1":
    sys.exit(1)
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
''')
    write_executable(bin_dir / "wifi", '''#!/bin/sh
if [ -e "${WIFI_FAIL_ONCE:-/nonexistent}" ]; then
    rm -f "$WIFI_FAIL_ONCE"
    exit 1
fi
exit 0
''')
    write_executable(bin_dir / "fw4", "#!/bin/sh\n[ ! -e \"${FW4_FAIL_FILE:-/nonexistent}\" ]\n")
    write_executable(bin_dir / "AdGuardHome", "#!/bin/sh\nexit 0\n")
    service_source = '''#!/bin/sh
service_name=${0##*/}
if [ "$service_name" = adguardhome-init ]; then
    case ${1-} in
        enabled) [ -e "$ADGUARDHOME_ENABLED_STATE" ]; exit ;;
        enable) : >"$ADGUARDHOME_ENABLED_STATE"; exit 0 ;;
        disable) rm -f "$ADGUARDHOME_ENABLED_STATE"; exit 0 ;;
    esac
fi
if [ -e "${STOPPED_WITH_NONZERO_ONCE:-/nonexistent}" ] &&
    [ "${1-}" = stop ] &&
    [ "${STOP_FAIL_NAME:-}" = "$service_name" ]; then
    rm -f "$STOPPED_WITH_NONZERO_ONCE"
    cp "$ROUTER_CONFIG_PROC_NET_DIR/tcp" "$ROUTER_CONFIG_PROC_NET_DIR/tcp.before-stop"
    : >"$ROUTER_CONFIG_PROC_NET_DIR/tcp"
    exit 1
fi
if [ "${1-}" = restart ] &&
    [ "${STOP_FAIL_NAME:-}" = "$service_name" ] &&
    [ -f "$ROUTER_CONFIG_PROC_NET_DIR/tcp.before-stop" ]; then
    mv "$ROUTER_CONFIG_PROC_NET_DIR/tcp.before-stop" "$ROUTER_CONFIG_PROC_NET_DIR/tcp"
fi
if [ -e "${STOP_FAIL_ONCE:-/nonexistent}" ] &&
    [ "${1-}" = stop ] &&
    [ "${STOP_FAIL_NAME:-}" = "$service_name" ]; then
    rm -f "$STOP_FAIL_ONCE"
    exit 1
fi
if [ -e "${SERVICE_FAIL_ONCE:-/nonexistent}" ] &&
    [ "${1-}" != stop ] &&
    { [ -z "${SERVICE_FAIL_NAME:-}" ] || [ "$SERVICE_FAIL_NAME" = "$service_name" ]; } &&
    { [ -z "${SERVICE_FAIL_ACTION:-}" ] || [ "$SERVICE_FAIL_ACTION" = "${1-}" ]; }; then
    rm -f "$SERVICE_FAIL_ONCE"
    exit 1
fi
exit 0
'''
    services = {}
    for name in (
        "network-init",
        "firewall-init",
        "uhttpd-init",
        "dropbear-init",
        "sysntpd-init",
        "chronyd-init",
        "dnsmasq-init",
        "adguardhome-init",
    ):
        services[name] = bin_dir / name
        write_executable(services[name], service_source)

    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "ROUTER_CONFIG_TESTING": "1",
        "ROUTER_CONFIG_CONFIG_DIR": str(config),
        "ROUTER_CONFIG_BACKUP_DIR": str(backups),
        "ROUTER_CONFIG_LOCK_DIR": str(tmp_path / "lock"),
        "ROUTER_CONFIG_SYS_CLASS_NET": str(sys_net),
        "ROUTER_CONFIG_PROC_NET_DIR": str(proc_net),
        "ROUTER_CONFIG_INIT_SCRIPT": str(init),
        "ROUTER_CONFIG_LIBEXEC": str(runtime),
        "ROUTER_CONFIG_UCI_DIR": str(overlays),
        "ROUTER_CONFIG_MODULE_DIR": str(modules),
        "ROUTER_CONFIG_MODULES_CONF": str(modules_conf),
        "ROUTER_CONFIG_CHRONY_CONF": str(chrony_conf),
        "ROUTER_CONFIG_ADGUARDHOME_CONFIG": str(adguardhome_config),
        "ROUTER_CONFIG_ADGUARDHOME_BIN": str(bin_dir / "AdGuardHome"),
        "ROUTER_CONFIG_NETWORK_INIT": str(services["network-init"]),
        "ROUTER_CONFIG_FIREWALL_INIT": str(services["firewall-init"]),
        "ROUTER_CONFIG_UHTTPD_INIT": str(services["uhttpd-init"]),
        "ROUTER_CONFIG_DROPBEAR_INIT": str(services["dropbear-init"]),
        "ROUTER_CONFIG_SYSNTPD_INIT": str(services["sysntpd-init"]),
        "ROUTER_CONFIG_CHRONYD_INIT": str(services["chronyd-init"]),
        "ROUTER_CONFIG_DNSMASQ_INIT": str(services["dnsmasq-init"]),
        "ROUTER_CONFIG_ADGUARDHOME_INIT": str(services["adguardhome-init"]),
        "ADGUARDHOME_ENABLED_STATE": str(tmp_path / "adguardhome.enabled"),
        "ROUTER_CONFIG_TIMEOUT": "2",
        "ROUTER_CONFIG_POLL_INTERVAL": "0.05",
        "ROUTER_CONFIG_WATCHDOG_READY_ATTEMPTS": "500",
        "ROUTER_CONFIG_WATCHDOG_READY_INTERVAL": "0.01",
        "PIXEL_WIFI_PASSWORD": "pixel-secret-123",
        "THINGS_WIFI_PASSWORD": "things-secret-123",
        "GUEST_WIFI_PASSWORD": "guest-secret-123",
        "IOT_WIFI_PASSWORD": "iot-secret-123",
        "COUNTRY": "US",
        "VPN_IF": "wgserver",
        "VPN_PORT": "42451",
        "VPN_KEY": "private-secret",
        "VPN_ADDR": "10.10.0.1/24",
        "ADGUARD_USERNAME": "admin",
        "ADGUARD_PASSWORD_HASH": "$2y$04$B9b7J6M1xwkLCfIRfpm7S.c8T3EPROaz2EJ1/CM2IpkAMGI1euIcy",
    }
    env.pop("DNS_REBIND_DOMAIN", None)
    try:
        yield tmp_path, config, backups, overlays, env
    finally:
        shutil.rmtree(tmp_path)


def run_router(env, *args, check=True):
    return subprocess.run(
        [str(REPO / "router-config.sh"), *args], env=env,
        text=True, capture_output=True, check=check,
    )


def prepare(env):
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode == 0, result.stderr
    return result, result.stdout.strip().splitlines()[-1]


def test_prepare_preserves_base_and_is_secret_safe(router):
    _, _, backups, _, env = router
    result, transaction = prepare(env)
    candidate = json.loads((backups / transaction / "candidate" / "network").read_text())
    assert candidate["br_lan"]["stp"] == "1"
    assert candidate["unrelated"] == {".type": "interface", "proto": "none"}
    assert set(name for name in candidate if name == "pixel") == {"pixel"}
    assert candidate["wan"]["proto"] == "static"
    assert candidate["wan"]["ipaddr"] == "192.168.2.2"
    assert candidate["wan"]["netmask"] == "255.255.255.0"
    assert candidate["wan"]["gateway"] == "192.168.2.1"
    assert candidate["wan"]["ipv6"] == "0"
    assert candidate["pixel"]["ipaddr"] == "192.168.8.1"
    assert candidate["pixelguest"]["ipaddr"] == "192.168.9.1"
    assert candidate["pixeliot"]["ipaddr"] == "192.168.10.1"
    assert candidate["pixelthings"]["ipaddr"] == "192.168.11.1"
    assert "pixel-secret-123" not in result.stdout + result.stderr
    assert (backups / transaction).stat().st_mode & 0o777 == 0o700
    transaction_dir = backups / transaction
    dhcp = json.loads((transaction_dir / "candidate" / "dhcp").read_text())
    gateways = {
        "pixel": "192.168.8.1",
        "pixelguest": "192.168.9.1",
        "pixeliot": "192.168.10.1",
        "pixelthings": "192.168.11.1",
    }
    for name, gateway in gateways.items():
        assert dhcp[name] == {
            ".type": "dhcp", "interface": name, "ignore": "0",
            "start": "100", "limit": "150", "leasetime": "12h",
            "ra": "disabled", "dhcpv6": "disabled", "ndp": "disabled",
            "dhcp_option": [f"6,{gateway}"],
        }
    wireless = json.loads((transaction_dir / "candidate" / "wireless").read_text())
    assert wireless["pixel"]["device"] == "radio0"
    assert wireless["pixelthings"]["device"] == "radio0"
    assert wireless["pixelguest"]["device"] == "radio0"
    assert wireless["pixeliot"]["device"] == "radio1"
    assert wireless["pixel"].get("isolate") in (None, "0")
    assert wireless["pixelthings"]["isolate"] == "1"
    assert wireless["pixelguest"]["isolate"] == "1"
    assert wireless["pixeliot"]["isolate"] == "1"
    assert wireless["radio0"]["country"] == "US"
    assert wireless["radio1"]["country"] == "US"
    assert wireless["radio0"]["channel"] == "36"
    assert wireless["radio0"]["htmode"] == "HE80"
    assert wireless["radio0"]["hostapd_options"] == ["he_twt_responder=0"]
    assert wireless["radio1"].get("channel") == "auto"
    assert "htmode" not in wireless["radio1"]
    assert wireless["radio1"].get("hostapd_options") is None
    firewall = json.loads((transaction_dir / "candidate" / "firewall").read_text())
    assert firewall["defaults"]["flow_offloading"] == "1"
    assert firewall["defaults"]["flow_offloading_hw"] == "1"
    assert firewall["pixel"]["forward"] == "ACCEPT"
    for restricted_zone in ("pixelguest", "pixeliot", "pixelthings"):
        assert firewall[restricted_zone]["forward"] == "REJECT"
    for network, label in (
        ("pixel", "Pixel"),
        ("pixelguest", "PixelGuest"),
        ("pixeliot", "PixelIoT"),
        ("pixelthings", "PixelThings"),
    ):
        assert firewall[f"reject_dot_{network}"] == {
            ".type": "rule", "name": f"{label}-Reject-DoT", "src": network,
            "dest": "*", "dest_port": "853", "proto": "tcp udp",
            "target": "REJECT",
        }
        assert firewall[f"reject_doq_{network}"] == {
            ".type": "rule", "name": f"{label}-Reject-DoQ", "src": network,
            "dest": "*", "dest_port": "8853", "proto": "udp",
            "target": "REJECT",
        }
        assert firewall[f"reject_doq_legacy_{network}"] == {
            ".type": "rule", "name": f"{label}-Reject-DoQ-Legacy",
            "src": network, "dest": "*", "dest_port": "784",
            "proto": "udp", "target": "REJECT",
        }
    assert firewall["pixeliot_dhcp_reply"] == {
        ".type": "rule", "name": "PixelIoT-DHCP-Reply", "dest": "pixeliot",
        "src_port": "67", "dest_port": "68", "proto": "udp",
        "family": "ipv4", "target": "ACCEPT",
    }
    for network, label in (
        ("pixelguest", "PixelGuest"),
        ("pixelthings", "PixelThings"),
        ("pixeliot", "PixelIoT"),
    ):
        assert firewall[f"reject_isp_transit_{network}"] == {
            ".type": "rule",
            "name": f"Reject-ISP-Transit-{label}",
            "src": network,
            "dest": "wan",
            "dest_ip": "192.168.2.0/24",
            "family": "ipv4",
            "proto": "all",
            "target": "REJECT",
        }
    modules_conf = (transaction_dir / "candidate" / "modules.conf").read_text()
    assert modules_conf.count("options mt7915e wed_enable=Y") == 1
    assert "wed_enable=N" not in modules_conf
    assert "# test modules.conf" in modules_conf
    assert dhcp["unrelated"]["ignore"] == "1"
    assert "server" not in dhcp["dnsmasq"]
    assert dhcp["dnsmasq"]["port"] == "54"
    assert dhcp["dnsmasq"]["noresolv"] == "1"
    assert dhcp["dnsmasq"]["cachesize"] == "0"
    assert dhcp["dnsmasq"]["domain"] == "lan"
    assert dhcp["dnsmasq"]["local"] == "/lan/"
    adguard_uci = json.loads((transaction_dir / "candidate" / "adguardhome").read_text())
    assert adguard_uci == {
        "config": {
            ".type": "adguardhome",
            "config_file": "/etc/adguardhome/adguardhome.yaml",
            "work_dir": "/opt/adguardhome",
            "user": "adguardhome",
            "group": "adguardhome",
            "verbose": "0",
        }
    }
    adguard_yaml = (transaction_dir / "candidate" / "adguardhome.yaml").read_text()
    assert "  address: 192.168.8.1:3000\n" in adguard_yaml
    assert "  - 10.10.0.1\n" in adguard_yaml
    assert "  - 192.168.11.1\n" in adguard_yaml
    assert "  port: 53\n" in adguard_yaml
    assert "  blocking_mode: nxdomain\n" in adguard_yaml
    assert "  - '[/lan/]127.0.0.1:54'\n" in adguard_yaml
    for upstream in (
        "https://dns.quad9.net/dns-query",
        "https://security.cloudflare-dns.com/dns-query",
        "https://freedns.controld.com/p2",
        "https://base.dns.mullvad.net/dns-query",
    ):
        assert adguard_yaml.count(upstream) == 1
    assert adguard_yaml.count("  interval: 7d\n") == 2
    assert adguard_yaml.count("- enabled: true\n") == 26
    assert "  name: AdGuard DNS filter\n" in adguard_yaml
    assert "  name: AdAway Default Blocklist\n" in adguard_yaml
    assert "  name: HaGeZi DNS Rebind Protection\n" in adguard_yaml
    assert "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt" not in adguard_yaml
    assert env["ADGUARD_PASSWORD_HASH"] in adguard_yaml
    assert env["ADGUARD_PASSWORD_HASH"] not in result.stdout + result.stderr
    chrony = json.loads((transaction_dir / "candidate" / "chrony").read_text())
    assert chrony["cloudflare"] == {
        ".type": "server", "hostname": "time.cloudflare.com", "iburst": "1",
        "nts": "1", "prefer": "1",
    }
    assert chrony["netnod"] == {
        ".type": "server", "hostname": "nts.netnod.se", "iburst": "1",
        "nts": "1", "prefer": "1",
    }
    assert chrony["time_nl"] == {
        ".type": "server", "hostname": "ntppool1.time.nl", "iburst": "1",
        "nts": "1", "prefer": "1",
    }
    assert chrony["bootstrap_1"] == {
        ".type": "server", "hostname": "194.177.4.1", "iburst": "1", "nts": "0",
    }
    assert chrony["dhcp_ntp_server"]["disabled"] == "1"
    assert "@pool[0]" not in chrony
    assert "allow" not in chrony
    assert chrony["nts"]["rtccheck"] == "1"
    assert chrony["nts"]["systemcerts"] == "1"
    chrony_conf = (transaction_dir / "candidate" / "chrony.conf").read_text()
    assert chrony_conf.count("authselectmode ignore") == 1
    assert "authselectmode ignore\nconfdir /var/etc/chrony.d\n" in chrony_conf
    uhttpd = json.loads((transaction_dir / "candidate" / "uhttpd").read_text())
    assert uhttpd["main"]["listen_http"] == ["192.168.8.1:80"]
    assert uhttpd["main"]["listen_https"] == ["192.168.8.1:443"]
    assert uhttpd["main"]["redirect_https"] == "1"
    dropbear = json.loads((transaction_dir / "candidate" / "dropbear").read_text())
    assert "@dropbear[0]" not in dropbear
    assert dropbear["main"]["DirectInterface"] == "pixel"
    assert dropbear["main"]["Port"] == "22"
    assert dropbear["main"]["enable"] == "1"
    assert "Interface" not in dropbear["main"]
    attendedsysupgrade = json.loads(
        (transaction_dir / "candidate" / "attendedsysupgrade").read_text()
    )
    assert attendedsysupgrade["client"]["login_check_for_upgrades"] == "1"
    assert "login_check_for_upgrade" not in attendedsysupgrade["client"]
    system = json.loads((transaction_dir / "candidate" / "system").read_text())
    assert system["ntp"]["server"] == ["old"]
    assert {
        "HaGeZi - Multi PRO", "OISD", "Steven Black", "Peter Lowe",
        "NextDNS - Windows", "NextDNS - Samsung", "NextDNS - Apple",
        "HaGeZi - Samsung native tracking", "HaGeZi - Prevent DNS bypass",
        "Smart TV", "HaGeZi - LG webOS", "Smart TV blocklist",
        "Block List Project - Smart TV", "Perflyst - Android tracking",
        "Divested - LG", "Divested - Mobile", "GameIndustry - Gaming hosts",
        "AdGuard CNAME trackers", "CERT Polska", "HaGeZi - Apple native tracking",
        "HaGeZi - Windows/Office native tracking", "HaGeZi - TikTok native tracking",
        "HaGeZi - Threat Intelligence Feeds",
    } <= {
        line.removeprefix("  name: ")
        for line in adguard_yaml.splitlines()
        if line.startswith("  name: ")
    }
    manifest = (transaction_dir / "manifest.sha256").read_text()
    assert "backup/adguardhome" in manifest
    assert "candidate/adguardhome" in manifest
    assert "backup/uhttpd" in manifest
    assert "candidate/uhttpd" in manifest
    assert "backup/dropbear" in manifest
    assert "candidate/dropbear" in manifest
    assert "backup/attendedsysupgrade" in manifest
    assert "candidate/attendedsysupgrade" in manifest
    assert "backup/chrony.conf" in manifest
    assert "candidate/chrony.conf" in manifest
    assert "backup/adguardhome.yaml" in manifest
    assert "candidate/adguardhome.yaml" in manifest
    assert "backup/adguardhome.enabled" in manifest
    assert "candidate/adguardhome.enabled" in manifest
    assert (transaction_dir / "candidate" / "wireless").stat().st_mode & 0o777 == 0o600
    assert (transaction_dir / "candidate" / "chrony.conf").stat().st_mode & 0o777 == 0o600
    assert (transaction_dir / "candidate" / "adguardhome.yaml").stat().st_mode & 0o777 == 0o600
    rendered = (transaction_dir / "overlay" / "wireguard").read_text()
    assert env["VPN_KEY"] not in rendered
    assert "${" not in rendered
    assert candidate["wan"]["ipv6"] == "0"
    assert "wan6" not in candidate
    assert "ula_prefix" not in candidate["globals"]
    assert candidate["wgserver"]["addresses"] == ["10.10.0.1/24"]
    assert "wgclient" not in candidate
    assert not any(
        section.get(".type") == "wireguard_wgserver"
        for section in candidate.values()
    )
    firewall = json.loads((transaction_dir / "candidate" / "firewall").read_text())
    assert firewall["wan"]["network"] == ["wan"]


def test_repeated_prepare_is_idempotent(router):
    _, config, backups, _, env = router
    _, first = prepare(env)
    first_firewall = json.loads(
        (backups / first / "candidate" / "firewall").read_text()
    )
    for name in (
        "network",
        "firewall",
        "wireless",
        "dhcp",
        "system",
        "adguardhome",
        "chrony",
        "uhttpd",
        "dropbear",
        "attendedsysupgrade",
    ):
        shutil.copy(backups / first / "candidate" / name, config / name)
    _, second = prepare(env)
    for name in (
        "network",
        "firewall",
        "wireless",
        "dhcp",
        "system",
        "adguardhome",
        "chrony",
        "uhttpd",
        "dropbear",
        "attendedsysupgrade",
    ):
        data = json.loads((backups / second / "candidate" / name).read_text())
        assert len(data) == len(set(data))
    second_firewall = json.loads(
        (backups / second / "candidate" / "firewall").read_text()
    )
    second_wireless = json.loads(
        (backups / second / "candidate" / "wireless").read_text()
    )
    assert second_wireless["radio0"]["hostapd_options"] == ["he_twt_responder=0"]
    assert second_wireless["radio1"].get("hostapd_options") is None
    for network in ("pixelguest", "pixelthings", "pixeliot"):
        section = f"reject_isp_transit_{network}"
        assert second_firewall[section] == first_firewall[section]
    assert json.loads((backups / second / "candidate" / "network").read_text())["br_lan"]["stp"] == "1"
    first_chrony_conf = (backups / first / "candidate" / "chrony.conf").read_text()
    Path(env["ROUTER_CONFIG_CHRONY_CONF"]).write_text(first_chrony_conf)
    _, third = prepare(env)
    third_chrony_conf = (backups / third / "candidate" / "chrony.conf").read_text()
    assert third_chrony_conf == first_chrony_conf
    assert third_chrony_conf.count("authselectmode ignore") == 1


@pytest.mark.parametrize("initial_value", ["0", "1"])
def test_attendedsysupgrade_login_check_is_enabled_from_either_state(router, initial_value):
    _, config, backups, _, env = router
    attendedsysupgrade = json.loads((config / "attendedsysupgrade").read_text())
    attendedsysupgrade["client"]["login_check_for_upgrades"] = initial_value
    (config / "attendedsysupgrade").write_text(json.dumps(attendedsysupgrade))

    _, transaction = prepare(env)
    candidate = json.loads(
        (backups / transaction / "candidate" / "attendedsysupgrade").read_text()
    )
    assert candidate["client"]["login_check_for_upgrades"] == "1"
    assert "login_check_for_upgrade" not in candidate["client"]


def test_check_base_rejects_missing_attendedsysupgrade_config(router):
    _, config, backups, _, env = router
    (config / "attendedsysupgrade").unlink()

    result = run_router(env, "check-base", check=False)
    assert result.returncode != 0
    assert "missing or empty" in result.stderr
    assert "attendedsysupgrade" in result.stderr
    assert not backups.exists()


@pytest.mark.parametrize(("contents", "error"), [
    (None, "missing or empty Chrony configuration"),
    ("", "missing or empty Chrony configuration"),
    ("driftfile /tmp/drift\n", "exactly one confdir"),
    (
        "confdir /var/etc/chrony.d\nconfdir /var/etc/chrony.d\n",
        "exactly one confdir",
    ),
    (
        "confdir /var/etc/chrony.d\nconfdir /var/etc/other.d\n",
        "exactly one confdir",
    ),
    (
        "authselectmode mix\nconfdir /var/etc/chrony.d\n",
        "conflicting authselectmode",
    ),
    (
        "authselectmode ignore\nauthselectmode ignore\n"
        "confdir /var/etc/chrony.d\n",
        "at most one authselectmode",
    ),
])
def test_chrony_conf_preflight_rejects_unsafe_base_before_backup(router, contents, error):
    _, config, backups, _, env = router
    chrony_conf = Path(env["ROUTER_CONFIG_CHRONY_CONF"])
    original_network = (config / "network").read_text()
    if contents is None:
        chrony_conf.unlink()
    else:
        chrony_conf.write_text(contents)
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert error in result.stderr
    assert (config / "network").read_text() == original_network
    assert not backups.exists()


def test_preflight_rejects_missing_hardware_without_backup(router):
    root, _, backups, _, env = router
    (root / "sys" / "class" / "net" / "lan4").rmdir()
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "required DSA interface missing: lan4" in result.stderr
    assert not backups.exists()


def test_fresh_stock_base_is_normalized_in_candidate_only(router):
    _, config, backups, _, env = router
    network = json.loads((config / "network").read_text())
    network["@device[0]"] = network.pop("br_lan")
    network["globals"]["ula_prefix"] = "fd12:3456:789a::/48"
    network["lan"] = {
        ".type": "interface", "device": "br-lan", "proto": "static",
        "ipaddr": ["192.168.1.1/24"], "ip6assign": "60",
    }
    network["wan6"] = {".type": "interface", "device": "@wan", "proto": "dhcpv6"}
    (config / "network").write_text(json.dumps(network))
    dhcp = json.loads((config / "dhcp").read_text())
    dhcp["lan"] = {
        ".type": "dhcp", "interface": "lan", "start": "100",
        "limit": "150", "leasetime": "12h", "dhcpv4": "server",
        "dhcpv6": "server", "ra": "server", "ra_slaac": "1",
        "ra_flags": ["managed-config", "other-config"],
    }
    (config / "dhcp").write_text(json.dumps(dhcp))
    firewall = {
        "@defaults[0]": {
            ".type": "defaults", "syn_flood": "1", "input": "REJECT",
            "output": "ACCEPT", "forward": "REJECT",
        },
        "@zone[0]": {
            ".type": "zone", "name": "lan", "network": ["lan"],
            "input": "ACCEPT", "output": "ACCEPT", "forward": "ACCEPT",
        },
        "@zone[1]": {
            ".type": "zone", "name": "wan", "network": ["wan", "wan6"],
            "input": "REJECT", "output": "ACCEPT", "forward": "DROP",
            "masq": "1", "mtu_fix": "1",
        },
        "@forwarding[0]": {".type": "forwarding", "src": "lan", "dest": "wan"},
        "@rule[0]": {
            ".type": "rule", "name": "Allow-IPSec-ESP", "src": "wan",
            "dest": "lan", "proto": "esp", "target": "ACCEPT",
        },
        "@rule[1]": {
            ".type": "rule", "name": "Allow-ISAKMP", "src": "wan",
            "dest": "lan", "dest_port": "500", "proto": "udp",
            "target": "ACCEPT",
        },
        "unrelated": {".type": "rule", "name": "Keep me"},
    }
    (config / "firewall").write_text(json.dumps(firewall))
    originals = {name: (config / name).read_text() for name in ("network", "dhcp", "firewall")}

    _, transaction = prepare(env)
    candidate_network = json.loads((backups / transaction / "candidate" / "network").read_text())
    candidate_dhcp = json.loads((backups / transaction / "candidate" / "dhcp").read_text())
    candidate_firewall = json.loads((backups / transaction / "candidate" / "firewall").read_text())
    assert "lan" not in candidate_network and "wan6" not in candidate_network
    assert "@device[0]" not in candidate_network
    assert candidate_network["br_lan"]["ports"] == ["lan1", "lan2", "lan3", "lan4", "lan5"]
    assert "ula_prefix" not in candidate_network["globals"]
    assert "lan" not in candidate_dhcp
    assert candidate_firewall["defaults"][".type"] == "defaults"
    assert candidate_firewall["defaults"]["flow_offloading"] == "1"
    assert candidate_firewall["defaults"]["flow_offloading_hw"] == "1"
    assert candidate_firewall["wan"]["network"] == ["wan"]
    assert "base_lan" not in candidate_firewall and "base_lan_wan" not in candidate_firewall
    assert not any(
        section.get("name") in {"Allow-IPSec-ESP", "Allow-ISAKMP"}
        for section in candidate_firewall.values()
    )
    assert candidate_firewall["unrelated"]["name"] == "Keep me"
    assert {name: (config / name).read_text() for name in originals} == originals
    modules_conf = (backups / transaction / "candidate" / "modules.conf").read_text()
    assert modules_conf.count("options mt7915e wed_enable=Y") == 1


def test_wed_modules_conf_is_idempotent(router):
    _, _, backups, _, env = router
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    modules_conf.write_text("# keep\noptions mt7915e wed_enable=N\noptions other ignored=1\n")
    _, first = prepare(env)
    first_text = (backups / first / "candidate" / "modules.conf").read_text()
    assert first_text.count("options mt7915e wed_enable=Y") == 1
    assert "wed_enable=N" not in first_text
    assert "options other ignored=1" in first_text
    modules_conf.write_text(first_text)
    _, second = prepare(env)
    second_text = (backups / second / "candidate" / "modules.conf").read_text()
    assert second_text == first_text
    assert second_text.count("options mt7915e wed_enable=Y") == 1


def test_custom_stock_base_is_rejected_before_backup(router):
    _, config, backups, _, env = router
    firewall = json.loads((config / "firewall").read_text())
    firewall["wan"]["network"] = ["wan", "custom_uplink"]
    (config / "firewall").write_text(json.dumps(firewall))
    result = run_router(env, "check-base", check=False)
    assert result.returncode != 0
    assert "customized network membership" in result.stderr
    assert not backups.exists()


def test_missing_stock_synflood_protection_is_rejected_before_backup(router):
    _, config, backups, _, env = router
    firewall = json.loads((config / "firewall").read_text())
    del firewall["defaults"]["syn_flood"]
    (config / "firewall").write_text(json.dumps(firewall))
    result = run_router(env, "check-base", check=False)
    assert result.returncode != 0
    assert "stock firewall defaults lack synflood protection" in result.stderr
    assert not backups.exists()


def test_custom_stock_lan_ra_defaults_are_rejected_before_backup(router):
    _, config, backups, _, env = router
    network = json.loads((config / "network").read_text())
    network["lan"] = {
        ".type": "interface", "device": "br-lan", "proto": "static",
        "ipaddr": "192.168.1.1", "netmask": "255.255.255.0",
    }
    (config / "network").write_text(json.dumps(network))
    dhcp = json.loads((config / "dhcp").read_text())
    dhcp["lan"] = {
        ".type": "dhcp", "interface": "lan", "start": "100",
        "limit": "150", "leasetime": "12h", "ra": "relay",
    }
    (config / "dhcp").write_text(json.dumps(dhcp))
    result = run_router(env, "check-base", check=False)
    assert result.returncode != 0
    assert "customized RA mode" in result.stderr
    assert not backups.exists()


def test_missing_setsid_is_rejected_before_backup(router):
    root, _, backups, _, env = router
    (root / "bin" / "setsid").unlink()
    result = run_router(env, "check-base", check=False)
    assert result.returncode != 0
    assert "required command not found: setsid" in result.stderr
    assert not backups.exists()


def test_wireless_assignment_follows_bands_not_radio_numbers(router):
    _, config, backups, _, env = router
    wireless = json.loads((config / "wireless").read_text())
    wireless["radio0"]["band"] = "2g"
    wireless["radio1"]["band"] = "5g"
    (config / "wireless").write_text(json.dumps(wireless))
    _, transaction = prepare(env)
    candidate = json.loads((backups / transaction / "candidate" / "wireless").read_text())
    assert candidate["pixel"]["device"] == "radio1"
    assert candidate["pixelthings"]["device"] == "radio1"
    assert candidate["pixelguest"]["device"] == "radio1"
    assert candidate["pixeliot"]["device"] == "radio0"
    assert candidate["radio1"]["channel"] == "36"
    assert candidate["radio1"]["htmode"] == "HE80"
    assert candidate["radio1"]["hostapd_options"] == ["he_twt_responder=0"]
    assert candidate["radio0"].get("hostapd_options") is None


def test_prepare_applies_custom_channel_with_he80(router):
    _, _, backups, _, env = router
    env["CHANNEL"] = "149"
    _, transaction = prepare(env)
    candidate = json.loads((backups / transaction / "candidate" / "wireless").read_text())
    assert candidate["radio0"]["channel"] == "149"
    assert candidate["radio0"]["htmode"] == "HE80"


def test_prepare_rejects_invalid_channel(router):
    _, _, _, _, env = router
    env["CHANNEL"] = "nope"
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "CHANNEL must be an integer from 36 through 177" in result.stderr


@pytest.mark.parametrize("vpn_addr", [
    "10.10.0.1",
    "10.10.0.1/33",
    "10.10.0.256/24",
    "10.10.0/24",
    "10.10.0.1/24/extra",
])
def test_prepare_rejects_invalid_wireguard_dns_bind_address(router, vpn_addr):
    _, _, backups, _, env = router
    env["VPN_ADDR"] = vpn_addr
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "VPN_ADDR" in result.stderr
    assert not backups.exists()


def test_wireguard_dns_bind_address_is_derived_from_vpn_addr(router):
    _, _, backups, _, env = router
    env["VPN_ADDR"] = "10.77.6.1/27"
    _, transaction = prepare(env)
    yaml = (backups / transaction / "candidate" / "adguardhome.yaml").read_text()
    assert yaml.count("  - 10.77.6.1\n") == 1
    assert "10.77.6.1/27" not in yaml


@pytest.mark.parametrize("configured_value", [None, ""])
def test_rebind_domain_unset_or_empty_renders_no_adguard_exception(
    router, configured_value
):
    _, config, backups, _, env = router
    dhcp = json.loads((config / "dhcp").read_text())
    dhcp["dnsmasq"]["rebind_domain"] = ["existing.example", "other.example"]
    (config / "dhcp").write_text(json.dumps(dhcp))
    if configured_value is None:
        env.pop("DNS_REBIND_DOMAIN", None)
    else:
        env["DNS_REBIND_DOMAIN"] = configured_value

    _, transaction = prepare(env)
    candidate = json.loads((backups / transaction / "candidate" / "dhcp").read_text())
    assert "rebind_domain" not in candidate["dnsmasq"]
    yaml = (backups / transaction / "candidate" / "adguardhome.yaml").read_text()
    assert "user_rules: []\n" in yaml


def test_rebind_domain_is_normalized_and_idempotent(router):
    _, config, backups, _, env = router
    env["DNS_REBIND_DOMAIN"] = "MyDomain.COM"

    _, first = prepare(env)
    first_yaml = (backups / first / "candidate" / "adguardhome.yaml").read_text()
    assert first_yaml.count("- '@@||mydomain.com^'") == 1

    (config / "adguardhome").write_text(
        (backups / first / "candidate" / "adguardhome").read_text()
    )
    _, second = prepare(env)
    second_yaml = (backups / second / "candidate" / "adguardhome.yaml").read_text()
    assert second_yaml == first_yaml


def test_changing_rebind_domain_replaces_the_managed_exception(router):
    _, _, backups, _, env = router
    env["DNS_REBIND_DOMAIN"] = "first.example"
    _, first = prepare(env)

    env["DNS_REBIND_DOMAIN"] = "second.example"
    _, second = prepare(env)
    candidate = (backups / second / "candidate" / "adguardhome.yaml").read_text()
    assert "- '@@||second.example^'" in candidate
    assert "first.example" not in candidate


@pytest.mark.parametrize("domain", [
    "*.mydomain.com",
    "https://mydomain.com",
    "my domain.com",
    "bad_label.example",
    "-bad.example",
    "bad-.example",
    "bad..example",
    "localhost",
    f"{'a' * 64}.example",
    ".".join(["a" * 63] * 4),
])
def test_invalid_rebind_domain_is_rejected_before_backup(router, domain):
    _, _, backups, _, env = router
    env["DNS_REBIND_DOMAIN"] = domain
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "DNS_REBIND_DOMAIN" in result.stderr
    assert not backups.exists()


def test_setup_rejects_invalid_rebind_domain_before_mutation(router):
    root, _, _, _, env = router
    marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{marker}'\n")
    env.update({
        "VPN_KEY": "A" * 43 + "=",
        "DNS_REBIND_DOMAIN": "*.mydomain.com",
    })
    result = subprocess.run(
        [str(REPO / "setup.sh"), "--recovery-ready"],
        env=env, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "DNS_REBIND_DOMAIN" in result.stderr
    assert not marker.exists()


def test_setup_rejects_invalid_channel_before_mutation(router):
    root, _, _, _, env = router
    marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{marker}'\n")
    key = "A" * 43 + "="
    env.update({"VPN_KEY": key, "CHANNEL": "12"})
    result = subprocess.run(
        [str(REPO / "setup.sh"), "--recovery-ready"],
        env=env, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "CHANNEL must be an integer from 36 through 177" in result.stderr
    assert not marker.exists()


def test_preflight_requires_explicit_2g_and_5g_radios(router):
    _, config, backups, _, env = router
    wireless = json.loads((config / "wireless").read_text())
    del wireless["radio1"]["band"]
    (config / "wireless").write_text(json.dumps(wireless))
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "missing wifi-device with band '2g'" in result.stderr
    assert not backups.exists()


def test_placeholder_and_lock_are_rejected(router):
    root, _, _, overlays, env = router
    with (overlays / "network").open("a") as stream:
        stream.write("\nset network.pixel.bad='${UNRESOLVED}'\n")
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert "unresolved placeholder" in result.stderr
    (overlays / "network").write_text((REPO / "uci/network").read_text())
    lock = root / "lock"; lock.mkdir(); (lock / "pid").write_text(str(os.getpid()))
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert "another operation holds" in result.stderr


def test_stale_empty_lock_dir_is_cleared(router):
    _, _, backups, _, env = router
    lock = Path(env["ROUTER_CONFIG_LOCK_DIR"])
    lock.mkdir()
    assert lock.is_dir()
    assert not (lock / "pid").exists()
    result, transaction = prepare(env)
    assert result.returncode == 0
    assert transaction
    assert backups.exists()
    assert not lock.exists()


def test_stale_dead_pid_lock_is_cleared(router):
    _, _, backups, _, env = router
    lock = Path(env["ROUTER_CONFIG_LOCK_DIR"])
    lock.mkdir()
    dead = subprocess.Popen(["true"])
    dead.wait()
    (lock / "pid").write_text(f"{dead.pid}\n")
    result, transaction = prepare(env)
    assert result.returncode == 0
    assert transaction
    assert backups.exists()
    assert not lock.exists()


def test_missing_transaction_module_is_rejected(router):
    root, _, backups, _, env = router
    (root / "modules" / "firewall.sh").unlink()
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "missing transaction module" in result.stderr
    assert not backups.exists()


def test_apply_confirm_and_manual_rollback(router):
    _, config, backups, _, env = router
    env["ROUTER_CONFIG_TIMEOUT"] = "2"
    names = ("network", "firewall", "wireless", "dhcp", "system", "adguardhome", "chrony", "uhttpd", "dropbear")
    originals = {name: (config / name).read_text() for name in names}
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    original_modules = modules_conf.read_text()
    chrony_conf = Path(env["ROUTER_CONFIG_CHRONY_CONF"])
    original_chrony_conf = chrony_conf.read_text()
    adguardhome_config = Path(env["ROUTER_CONFIG_ADGUARDHOME_CONFIG"])
    assert not adguardhome_config.exists()
    _, transaction = prepare(env)
    process = subprocess.Popen(
        [str(REPO / "router-config.sh"), "apply", transaction], env=env,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    pending = backups / transaction / "pending"
    for _ in range(300):
        if pending.exists(): break
        time.sleep(0.02)
    assert pending.exists()
    lock = Path(env["ROUTER_CONFIG_LOCK_DIR"])
    for _ in range(300):
        if not lock.exists(): break
        time.sleep(0.02)
    assert not lock.exists()
    watchdog_pid = backups / transaction / "watchdog.pid"
    assert watchdog_pid.read_text().strip().isdigit()
    confirm = run_router(env, "confirm", transaction)
    stdout, stderr = process.communicate(timeout=5)
    assert process.returncode == 0, stderr
    assert "confirm" in stdout
    assert "reboot after confirm" in stdout
    assert "reboot required for WED" in confirm.stdout
    for _ in range(300):
        if not watchdog_pid.exists(): break
        time.sleep(0.02)
    assert not watchdog_pid.exists()
    assert json.loads((config / "network").read_text())["pixel"]["ipaddr"] == "192.168.8.1"
    assert json.loads((config / "network").read_text())["wan"]["ipaddr"] == "192.168.2.2"
    assert json.loads((config / "network").read_text())["wan"]["gateway"] == "192.168.2.1"
    assert json.loads((config / "firewall").read_text())["defaults"]["flow_offloading"] == "1"
    assert json.loads((config / "firewall").read_text())["defaults"]["flow_offloading_hw"] == "1"
    assert modules_conf.read_text().count("options mt7915e wed_enable=Y") == 1
    assert chrony_conf.stat().st_mode & 0o777 == 0o644
    assert "authselectmode ignore\nconfdir /var/etc/chrony.d\n" in chrony_conf.read_text()
    assert adguardhome_config.exists()
    assert adguardhome_config.stat().st_mode & 0o777 == 0o600
    assert "AdAway Default Blocklist" in adguardhome_config.read_text()
    assert Path(env["ADGUARDHOME_ENABLED_STATE"]).exists()
    run_router(env, "rollback", transaction)
    assert {name: (config / name).read_text() for name in originals} == originals
    assert modules_conf.read_text() == original_modules
    assert chrony_conf.read_text() == original_chrony_conf
    assert not adguardhome_config.exists()
    assert not Path(env["ADGUARDHOME_ENABLED_STATE"]).exists()
    assert chrony_conf.stat().st_mode & 0o777 == 0o644


def test_timeout_and_reboot_recovery_restore_backup(router):
    _, config, backups, _, env = router
    original = (config / "network").read_text()
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    original_modules = modules_conf.read_text()
    chrony_conf = Path(env["ROUTER_CONFIG_CHRONY_CONF"])
    original_chrony_conf = chrony_conf.read_text()
    adguardhome_config = Path(env["ROUTER_CONFIG_ADGUARDHOME_CONFIG"])
    env["ROUTER_CONFIG_TIMEOUT"] = "0.15"
    _, transaction = prepare(env)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert (config / "network").read_text() == original
    assert modules_conf.read_text() == original_modules
    assert chrony_conf.read_text() == original_chrony_conf
    assert (backups / transaction / "state").read_text().strip() == "rolledback"
    assert not (backups / transaction / "pending").exists()
    assert not (backups / transaction / "watchdog.pid").exists()

    _, transaction = prepare(env)
    shutil.copy(backups / transaction / "candidate" / "network", config / "network")
    shutil.copy(backups / transaction / "candidate" / "modules.conf", modules_conf)
    shutil.copy(backups / transaction / "candidate" / "chrony.conf", chrony_conf)
    shutil.copy(backups / transaction / "candidate" / "adguardhome.yaml", adguardhome_config)
    (backups / transaction / "pending").touch()
    (backups / transaction / "state").write_text("pending\n")
    (backups / transaction / "watchdog.pid").write_text("999999\n")
    run_router(env, "_recover-pending")
    assert (config / "network").read_text() == original
    assert modules_conf.read_text() == original_modules
    assert chrony_conf.read_text() == original_chrony_conf
    assert not adguardhome_config.exists()
    assert (backups / transaction / "state").read_text().strip() == "rolledback"
    assert not (backups / transaction / "pending").exists()
    assert not (backups / transaction / "watchdog.pid").exists()


def test_watchdog_survives_apply_session_hangup_and_restores_every_file(router):
    _, config, backups, _, env = router
    names = (
        "network", "firewall", "wireless", "dhcp", "system",
        "adguardhome", "chrony", "uhttpd", "dropbear",
    )
    originals = {name: (config / name).read_text() for name in names}
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    original_modules = modules_conf.read_text()
    chrony_conf = Path(env["ROUTER_CONFIG_CHRONY_CONF"])
    original_chrony_conf = chrony_conf.read_text()
    env["ROUTER_CONFIG_TIMEOUT"] = "2"
    _, transaction = prepare(env)
    process = subprocess.Popen(
        [str(REPO / "router-config.sh"), "apply", transaction],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    transaction_dir = backups / transaction
    pid_file = transaction_dir / "watchdog.pid"
    lock = Path(env["ROUTER_CONFIG_LOCK_DIR"])
    watchdog_process = None
    for _ in range(500):
        if pid_file.exists() and pid_file.read_text().strip().isdigit() and not lock.exists():
            watchdog_process = int(pid_file.read_text().strip())
            break
        time.sleep(0.01)
    assert watchdog_process is not None
    assert os.getsid(watchdog_process) != os.getsid(process.pid)

    os.killpg(os.getpgid(process.pid), signal.SIGHUP)
    _, stderr = process.communicate(timeout=5)
    assert process.returncode != 0, stderr
    os.kill(watchdog_process, 0)

    for _ in range(500):
        if (transaction_dir / "state").read_text().strip() == "rolledback":
            break
        time.sleep(0.01)
    assert (transaction_dir / "state").read_text().strip() == "rolledback"
    assert {name: (config / name).read_text() for name in names} == originals
    assert modules_conf.read_text() == original_modules
    assert chrony_conf.read_text() == original_chrony_conf
    assert not (transaction_dir / "pending").exists()
    assert not pid_file.exists()


def test_watchdog_start_failure_restores_every_file(router):
    _, config, backups, _, env = router
    names = (
        "network", "firewall", "wireless", "dhcp", "system",
        "adguardhome", "chrony", "uhttpd", "dropbear",
    )
    originals = {name: (config / name).read_text() for name in names}
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    original_modules = modules_conf.read_text()
    chrony_conf = Path(env["ROUTER_CONFIG_CHRONY_CONF"])
    original_chrony_conf = chrony_conf.read_text()
    env["SETSID_FAIL"] = "1"
    env["ROUTER_CONFIG_WATCHDOG_READY_ATTEMPTS"] = "3"
    env["ROUTER_CONFIG_WATCHDOG_READY_INTERVAL"] = "0.01"
    _, transaction = prepare(env)
    result = run_router(env, "apply", transaction, check=False)
    transaction_dir = backups / transaction
    assert result.returncode != 0
    assert "could not start rollback watchdog; backups restored" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert modules_conf.read_text() == original_modules
    assert chrony_conf.read_text() == original_chrony_conf
    assert (transaction_dir / "state").read_text().strip() == "rolledback"
    assert not (transaction_dir / "pending").exists()
    assert not (transaction_dir / "watchdog.pid").exists()


def test_fw4_failure_does_not_change_live_configuration(router):
    root, config, _, _, env = router
    original = (config / "network").read_text()
    fail_file = root / "fw4-fail"; fail_file.touch(); env["FW4_FAIL_FILE"] = str(fail_file)
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "fw4 rejected candidate" in result.stderr
    assert (config / "network").read_text() == original


def test_apply_fw4_failure_restores_backup(router):
    root, config, backups, _, env = router
    original = (config / "network").read_text()
    original_adguard = (config / "adguardhome").read_text()
    _, transaction = prepare(env)
    fail_file = root / "fw4-fail"; fail_file.touch(); env["FW4_FAIL_FILE"] = str(fail_file)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "backups restored" in result.stderr
    assert (config / "network").read_text() == original
    assert (config / "adguardhome").read_text() == original_adguard
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_dnsmasq_stop_failure_restores_backup(router):
    root, config, backups, _, env = router
    names = ("network", "firewall", "wireless", "dhcp", "system", "adguardhome", "chrony", "uhttpd", "dropbear")
    originals = {name: (config / name).read_text() for name in names}
    _, transaction = prepare(env)
    fail = root / "dnsmasq-stop-fail"
    fail.touch()
    env["STOP_FAIL_ONCE"] = str(fail)
    env["STOP_FAIL_NAME"] = "dnsmasq-init"
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "could not stop dnsmasq; backups restored" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_missing_adguard_listener_restores_backup(router):
    _, config, backups, _, env = router
    original = (config / "network").read_text()
    _, transaction = prepare(env)
    (Path(env["ROUTER_CONFIG_PROC_NET_DIR"]) / "tcp").write_text("")
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "service reload failed at adguardhome-listeners; backups restored" in result.stderr
    assert (config / "network").read_text() == original
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


@pytest.mark.parametrize(("service_name", "action", "failure_label"), [
    ("network-init", "reload", "network"),
    ("wifi", "reload", "wifi"),
    ("firewall-init", "reload", "firewall"),
    ("uhttpd-init", "restart", "uhttpd"),
    ("dropbear-init", "restart", "dropbear"),
    ("chronyd-init", "restart", "chronyd"),
    ("dnsmasq-init", "restart", "dnsmasq"),
    ("adguardhome-init", "restart", "adguardhome"),
])
def test_each_coordinated_service_failure_is_named_and_restores_every_file(
    router, service_name, action, failure_label
):
    root, config, backups, _, env = router
    names = ("network", "firewall", "wireless", "dhcp", "system", "adguardhome", "chrony", "uhttpd", "dropbear")
    originals = {name: (config / name).read_text() for name in names}
    chrony_conf = Path(env["ROUTER_CONFIG_CHRONY_CONF"])
    original_chrony_conf = chrony_conf.read_text()
    _, transaction = prepare(env)
    fail = root / f"{service_name}-fail"
    fail.touch()
    if service_name == "wifi":
        env["WIFI_FAIL_ONCE"] = str(fail)
    else:
        env["SERVICE_FAIL_ONCE"] = str(fail)
        env["SERVICE_FAIL_NAME"] = service_name
        env["SERVICE_FAIL_ACTION"] = action
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert f"service reload failed at {failure_label}; backups restored" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert chrony_conf.read_text() == original_chrony_conf
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_transaction_tampering_is_rejected(router):
    _, config, backups, _, env = router
    original = (config / "network").read_text()
    chrony_conf = Path(env["ROUTER_CONFIG_CHRONY_CONF"])
    original_chrony_conf = chrony_conf.read_text()
    _, transaction = prepare(env)
    with (backups / transaction / "candidate" / "chrony.conf").open("a") as stream:
        stream.write("tampered")
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "checksum verification failed" in result.stderr
    assert (config / "network").read_text() == original
    assert chrony_conf.read_text() == original_chrony_conf


def test_partial_candidate_installation_failure_restores_all_packages(router):
    root, config, backups, _, env = router
    names = ("network", "firewall", "wireless", "dhcp", "system", "adguardhome", "chrony", "uhttpd", "dropbear")
    originals = {name: (config / name).read_text() for name in names}
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    original_modules = modules_conf.read_text()
    chrony_conf = Path(env["ROUTER_CONFIG_CHRONY_CONF"])
    original_chrony_conf = chrony_conf.read_text()
    _, transaction = prepare(env)
    fail = root / "install-fail"
    fail.touch()
    real_cp = next(path for path in ("/bin/cp", "/usr/bin/cp") if Path(path).exists())
    write_executable(root / "bin" / "cp", f'''#!/bin/sh
if [ -e "{fail}" ]; then
    case "$1" in
        */candidate/chrony.conf) rm -f "{fail}"; exit 1 ;;
    esac
fi
exec {real_cp} "$@"
''')
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "candidate installation failed" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert modules_conf.read_text() == original_modules
    assert chrony_conf.read_text() == original_chrony_conf
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_setup_rejects_an_incomplete_repository_before_mutation(router):
    root, _, _, _, env = router
    setup_copy = root / "setup.sh"
    write_executable(setup_copy, (REPO / "setup.sh").read_text())
    mutation_marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{mutation_marker}'\n")
    key = "A" * 43 + "="
    env.update({"VPN_KEY": key})
    result = subprocess.run(
        [str(setup_copy), "--recovery-ready"], env=env, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "repository file is missing or empty" in result.stderr
    assert not mutation_marker.exists()


def test_setup_rejects_missing_country_before_mutation(router):
    root, _, _, _, env = router
    marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{marker}'\n")
    key = "A" * 43 + "="
    env.update({"VPN_KEY": key})
    env.pop("COUNTRY", None)
    result = subprocess.run(
        [str(REPO / "setup.sh"), "--recovery-ready"],
        env=env, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "required variable is empty: COUNTRY" in result.stderr
    assert not marker.exists()


def test_setup_validates_all_inputs_before_mutation(router):
    root, _, _, _, env = router
    marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{marker}'\n")
    key = "A" * 43 + "="
    env.update({
        "VPN_IF": "bad-name;unsafe",
        "VPN_PORT": "42451",
        "VPN_KEY": key,
        "VPN_ADDR": "10.10.0.1/24",
    })
    result = subprocess.run(
        [str(REPO / "setup.sh"), "--recovery-ready"],
        env=env, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "safe UCI section name" in result.stderr
    assert not marker.exists()
    for secret in (key, env["PIXEL_WIFI_PASSWORD"], env["VPN_KEY"]):
        assert secret not in result.stdout + result.stderr


def run_module(env, module_name, function_call):
    result = subprocess.run(
        ["sh", "-eu", "-c", f'. "{REPO / "modules" / module_name}"; {function_call}'],
        env=env, text=True, capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    return result


def test_unique_anonymous_dnsmasq_is_named_in_candidate_only(router):
    _, config, backups, _, env = router
    dhcp = json.loads((config / "dhcp").read_text())
    dhcp["@dnsmasq[0]"] = dhcp.pop("dnsmasq")
    (config / "dhcp").write_text(json.dumps(dhcp))
    original = (config / "dhcp").read_text()
    _, transaction = prepare(env)
    candidate = json.loads((backups / transaction / "candidate" / "dhcp").read_text())
    assert "dnsmasq" in candidate
    assert "@dnsmasq[0]" not in candidate
    assert (config / "dhcp").read_text() == original


@pytest.mark.parametrize("sections", [
    {},
    {"other_name": {".type": "dnsmasq"}},
    {"@dnsmasq[0]": {".type": "dnsmasq"}, "@dnsmasq[1]": {".type": "dnsmasq"}},
])
def test_missing_or_ambiguous_dnsmasq_is_rejected(router, sections):
    _, config, backups, _, env = router
    (config / "dhcp").write_text(json.dumps(sections))
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "dnsmasq" in result.stderr
    assert not backups.exists()


def test_adguard_dnsmasq_validation_is_a_preapply_failure(router):
    _, config, backups, overlays, env = router
    original = (config / "network").read_text()
    with (overlays / "adguard-home").open("a") as stream:
        stream.write("\nset dhcp.dnsmasq.port='55'\n")
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert "dnsmasq must listen on port 54" in result.stderr
    assert (config / "network").read_text() == original
    assert not any(backups.glob("*/state"))


@pytest.mark.parametrize(("mutation", "error"), [
    (
        "set firewall.reject_dot_pixel.dest='wan'",
        "DoT/standard DoQ rejection must cover every routed destination for pixel",
    ),
    (
        "set firewall.reject_doq_pixelguest.dest_port='8854'",
        "alternate DoQ rejection has an unexpected port for pixelguest",
    ),
    (
        "set firewall.reject_doq_legacy_pixelthings='redirect'",
        "missing legacy DoQ rejection for pixelthings",
    ),
])
def test_encrypted_dns_rejection_validation_is_a_preapply_failure(
    router, mutation, error
):
    _, config, backups, overlays, env = router
    original = (config / "firewall").read_text()
    with (overlays / "adguard-home").open("a") as stream:
        stream.write(f"\n{mutation}\n")
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert error in result.stderr
    assert (config / "firewall").read_text() == original
    assert not any(backups.glob("*/state"))


@pytest.mark.parametrize(("mutation", "error"), [
    (
        "set firewall.pixel.forward='REJECT'",
        "Pixel zone must accept intra-zone forwarding",
    ),
    (
        "set firewall.pixelguest.forward='ACCEPT'",
        "pixelguest zone must reject intra-zone forwarding",
    ),
    (
        "set firewall.pixeliot.forward='ACCEPT'",
        "pixeliot zone must reject intra-zone forwarding",
    ),
    (
        "set firewall.pixelthings.forward='ACCEPT'",
        "pixelthings zone must reject intra-zone forwarding",
    ),
])
def test_managed_zone_forward_validation_is_a_preapply_failure(
    router, mutation, error
):
    _, config, backups, overlays, env = router
    original = (config / "firewall").read_text()
    with (overlays / "firewall").open("a") as stream:
        stream.write(f"\n{mutation}\n")
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert error in result.stderr
    assert (config / "firewall").read_text() == original
    assert not any(backups.glob("*/state"))


@pytest.mark.parametrize(("mutation", "error"), [
    (
        "remove_pixelguest",
        "missing ISP transit rejection for pixelguest",
    ),
    (
        "set firewall.reject_isp_transit_pixelthings.proto='tcp'",
        "ISP transit rejection has an unexpected protocol for pixelthings",
    ),
    (
        "set firewall.reject_isp_transit_pixeliot.target='ACCEPT'",
        "ISP transit rejection has an unexpected target for pixeliot",
    ),
])
def test_isp_transit_rejection_validation_is_a_preapply_failure(
    router, mutation, error
):
    _, config, backups, overlays, env = router
    original = (config / "firewall").read_text()
    firewall_overlay = overlays / "firewall"
    if mutation == "remove_pixelguest":
        overlay = firewall_overlay.read_text()
        start = overlay.index("delete firewall.reject_isp_transit_pixelguest\n")
        end = overlay.index("delete firewall.reject_isp_transit_pixelthings\n")
        firewall_overlay.write_text(overlay[:start] + overlay[end:])
    else:
        with firewall_overlay.open("a") as stream:
            stream.write(f"\n{mutation}\n")
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert error in result.stderr
    assert (config / "firewall").read_text() == original
    assert not any(backups.glob("*/state"))


def test_admin_access_validation_rejects_wildcard_uhttpd_listen(router):
    _, config, backups, overlays, env = router
    original = (config / "network").read_text()
    with (overlays / "admin-access").open("a") as stream:
        stream.write("\nadd_list uhttpd.main.listen_http='0.0.0.0:80'\n")
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "uhttpd must listen only on 192.168.8.1:80" in result.stderr
    assert (config / "network").read_text() == original
    assert not any(backups.glob("*/state"))


def test_feature_install_callbacks_only_install_and_enable(router):
    root, config, _, _, env = router
    names = ("network", "firewall", "dhcp", "adguardhome", "chrony", "uhttpd", "dropbear")
    before = {name: (config / name).read_text() for name in names}
    apk_log = root / "apk.log"
    init_log = root / "init.log"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{apk_log}'\n")
    init = root / "bin" / "init-install"
    write_executable(init, f'''#!/bin/sh
[ "${{1-}}" != enabled ] || exit 1
printf '%s\n' "$*" >> '{init_log}'
''')
    env["ROUTER_CONFIG_SYSNTPD_INIT"] = str(init)
    env["ROUTER_CONFIG_CHRONYD_INIT"] = str(init)
    env["ROUTER_CONFIG_ADGUARDHOME_INIT"] = str(init)
    run_module(env, "nts.sh", "nts_install")
    run_module(env, "adguard-home.sh", "adguard_home_install")
    run_module(env, "wireguard.sh", "wireguard_install")
    assert apk_log.read_text().splitlines() == [
        "add chrony-nts",
        "add adguardhome luci-app-adguardhome",
        "add wireguard-tools luci-proto-wireguard",
    ]
    assert init_log.read_text().splitlines() == ["stop", "disable", "enable", "stop", "disable"]
    assert {name: (config / name).read_text() for name in names} == before


def test_all_package_installation_uses_apk(router):
    root, _, _, _, env = router
    apk_log = root / "apk.log"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{apk_log}'\n")
    run_module(env, "base-packages.sh", "base_packages_run")
    assert apk_log.read_text().splitlines() == [
        "update",
        "add gawk grep sed ss coreutils-sort nano",
    ]
    project_shell = "\n".join(
        path.read_text()
        for path in [REPO / "setup.sh", *(REPO / "modules").glob("*.sh")]
    )
    assert "op" + "kg" not in project_shell
    assert "apk add dns" + "crypt" not in project_shell.lower()
    assert "apk add chrony-nts" in project_shell
    assert "apk add adguardhome luci-app-adguardhome" in project_shell
    assert "apk add wireguard-tools luci-proto-wireguard" in project_shell


def test_setup_declares_fixed_module_order_and_all_members():
    source = (REPO / "setup.sh").read_text()
    calls = [
        'router-config.sh" check-base',
        "base_packages_run",
        "nts_install",
        "adguard_home_install",
        "wireguard_install",
        'router-config.sh\" prepare',
    ]
    positions = [source.rindex(call) for call in calls]
    assert positions == sorted(positions)
    for name in (
        "base-packages", "network", "firewall", "wireless", "admin-access",
        "attendedsysupgrade", "nts",
        "adguard-home", "wireguard",
    ):
        assert f"modules/{name}.sh" in source
    assert "SCRIPT_DIR=$(CDPATH=" in source
    assert "uclient-fetch" not in source
    assert "ROUTER_CONFIG_" + "BUNDLE" not in source
    assert "adblock" + "-lean" not in source
    assert "--recovery-ready" in source
    assert "adguard_home_run" not in source
    assert "wireguard_run" not in source
    assert "nts_run" not in source
    assert "admin_access_run" not in source
    assert "adblock selector" not in (REPO / "README.md").read_text().lower()

    transaction_source = (REPO / "router-config.sh").read_text()
    assert transaction_source.index('"$FIREWALL_INIT" reload') < transaction_source.index(
        '"$UHTTPD_INIT" restart'
    )
    assert transaction_source.index('"$UHTTPD_INIT" restart') < transaction_source.index(
        '"$DROPBEAR_INIT" restart'
    )
    assert transaction_source.index('"$DROPBEAR_INIT" restart') < transaction_source.index(
        '"$CHRONYD_INIT" restart'
    )
    assert transaction_source.index('"$DNSMASQ_INIT" restart') < transaction_source.index(
        '"$ADGUARDHOME_INIT" restart'
    )
