import json
import os
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
    config.mkdir(); bin_dir.mkdir(); overlays.mkdir(); modules.mkdir(); proc_net.mkdir(parents=True)
    modules_conf.write_text("# test modules.conf\n")
    socket_lines = "".join(
        f"   {index}: 0100007F:{port:04X} 00000000:0000 0A\n"
        for index, port in enumerate((5053, 5054, 5055, 5056, 5999))
    )
    (proc_net / "tcp").write_text(socket_lines)
    (proc_net / "udp").write_text("")
    for name in ("br-lan", "lan1", "lan2", "lan3", "lan4", "lan5"):
        (sys_net / name).mkdir(parents=True)
    for name in ("network", "firewall", "wireless", "dns-over-https", "adblock-fast", "wireguard"):
        shutil.copy(REPO / "uci" / name, overlays / name)
    for name in ("network", "firewall", "wireless", "dns-over-https", "adblock-fast", "wireguard"):
        shutil.copy(REPO / "modules" / f"{name}.sh", modules / f"{name}.sh")

    network = {
        "loopback": {".type": "interface", "proto": "static"},
        "globals": {".type": "globals"},
        "wan": {".type": "interface", "proto": "dhcp"},
        "br_lan": {".type": "device", "name": "br-lan", "type": "bridge", "ports": ["lan1", "lan2", "lan3", "lan4", "lan5"], "stp": "1"},
        "unrelated": {".type": "interface", "proto": "none"},
    }
    firewall = {
        "defaults": {".type": "defaults", "input": "REJECT", "output": "ACCEPT", "forward": "REJECT"},
        "wan": {".type": "zone", "name": "wan", "network": ["wan"], "input": "REJECT", "output": "ACCEPT", "forward": "REJECT"},
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
    adblock = {"config": {".type": "adblock-fast", "enabled": "0"}, "unmanaged": {".type": "file_url", "name": "Keep me"}}
    https_dns_proxy = {
        "config": {".type": "main", "dnsmasq_config_update": "*", "force_dns": "1", "notrack_dns": "1"},
        "@https-dns-proxy[0]": {".type": "https-dns-proxy", "resolver_url": "https://cloudflare-dns.com/dns-query", "listen_port": "5053"},
        "@https-dns-proxy[1]": {".type": "https-dns-proxy", "resolver_url": "https://dns.google/dns-query", "listen_port": "5054"},
        "unmanaged": {".type": "https-dns-proxy", "resolver_url": "https://example.invalid/dns-query", "listen_port": "5999"},
    }
    for name, value in (("network", network), ("firewall", firewall), ("wireless", wireless), ("dhcp", dhcp), ("system", system), ("https-dns-proxy", https_dns_proxy), ("adblock-fast", adblock)):
        (config / name).write_text(json.dumps(value))

    write_executable(bin_dir / "uci", UCI_STUB)
    write_executable(bin_dir / "ubus", "#!/bin/sh\nexit 0\n")
    write_executable(bin_dir / "wifi", '''#!/bin/sh
if [ -e "${WIFI_FAIL_ONCE:-/nonexistent}" ]; then
    rm -f "$WIFI_FAIL_ONCE"
    exit 1
fi
exit 0
''')
    write_executable(bin_dir / "fw4", "#!/bin/sh\n[ ! -e \"${FW4_FAIL_FILE:-/nonexistent}\" ]\n")
    service_source = '''#!/bin/sh
service_name=${0##*/}
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
    for name in ("network-init", "firewall-init", "sysntpd-init", "https-dns-proxy-init", "dnsmasq-init", "adblock-init"):
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
        "ROUTER_CONFIG_NETWORK_INIT": str(services["network-init"]),
        "ROUTER_CONFIG_FIREWALL_INIT": str(services["firewall-init"]),
        "ROUTER_CONFIG_SYSNTPD_INIT": str(services["sysntpd-init"]),
        "ROUTER_CONFIG_HTTPS_DNS_PROXY_INIT": str(services["https-dns-proxy-init"]),
        "ROUTER_CONFIG_DNSMASQ_INIT": str(services["dnsmasq-init"]),
        "ROUTER_CONFIG_ADBLOCK_INIT": str(services["adblock-init"]),
        "ROUTER_CONFIG_TIMEOUT": "2",
        "ROUTER_CONFIG_POLL_INTERVAL": "0.05",
        "PIXEL_WIFI_PASSWORD": "pixel-secret-123",
        "THINGS_WIFI_PASSWORD": "things-secret-123",
        "GUEST_WIFI_PASSWORD": "guest-secret-123",
        "IOT_WIFI_PASSWORD": "iot-secret-123",
        "COUNTRY": "US",
        "VPN_IF": "wgserver",
        "VPN_PORT": "42451",
        "VPN_KEY": "private-secret",
        "VPN_ADDR": "10.10.0.1/24",
        "VPN_PUB": "public-key",
        "VPN_PSK": "preshared-secret",
    }
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
    assert candidate["wan"]["ipaddr"] == "192.168.1.2"
    assert candidate["wan"]["netmask"] == "255.255.255.0"
    assert candidate["wan"]["gateway"] == "192.168.1.1"
    assert candidate["wan"]["ipv6"] == "0"
    assert candidate["pixel"]["ipaddr"] == "192.168.8.1"
    assert candidate["pixelguest"]["ipaddr"] == "192.168.9.1"
    assert candidate["pixeliot"]["ipaddr"] == "192.168.10.1"
    assert candidate["pixelthings"]["ipaddr"] == "192.168.11.1"
    assert "pixel-secret-123" not in result.stdout + result.stderr
    assert (backups / transaction).stat().st_mode & 0o777 == 0o700
    transaction_dir = backups / transaction
    dhcp = json.loads((transaction_dir / "candidate" / "dhcp").read_text())
    for name in ("pixel", "pixelthings", "pixelguest", "pixeliot"):
        assert dhcp[name] == {
            ".type": "dhcp", "interface": name, "ignore": "0",
            "start": "100", "limit": "150", "leasetime": "12h",
            "ra": "disabled", "dhcpv6": "disabled", "ndp": "disabled",
        }
    wireless = json.loads((transaction_dir / "candidate" / "wireless").read_text())
    assert wireless["pixel"]["device"] == "radio0"
    assert wireless["pixelthings"]["device"] == "radio0"
    assert wireless["pixelguest"]["device"] == "radio0"
    assert wireless["pixeliot"]["device"] == "radio1"
    assert wireless["radio0"]["country"] == "US"
    assert wireless["radio1"]["country"] == "US"
    assert wireless["radio0"]["channel"] == "52"
    assert wireless["radio0"]["htmode"] == "HE80"
    assert wireless["radio1"].get("channel") == "auto"
    assert "htmode" not in wireless["radio1"]
    firewall = json.loads((transaction_dir / "candidate" / "firewall").read_text())
    assert firewall["defaults"]["flow_offloading"] == "1"
    assert firewall["defaults"]["flow_offloading_hw"] == "1"
    assert firewall["pixeliot_dhcp_reply"] == {
        ".type": "rule", "name": "PixelIoT-DHCP-Reply", "dest": "pixeliot",
        "src_port": "67", "dest_port": "68", "proto": "udp",
        "family": "ipv4", "target": "ACCEPT",
    }
    modules_conf = (transaction_dir / "candidate" / "modules.conf").read_text()
    assert modules_conf.count("options mt7915e wed_enable=Y") == 1
    assert "wed_enable=N" not in modules_conf
    assert "# test modules.conf" in modules_conf
    assert dhcp["unrelated"]["ignore"] == "1"
    assert dhcp["dnsmasq"]["server"] == [
        "127.0.0.1#5053", "127.0.0.1#5054", "127.0.0.1#5055", "127.0.0.1#5056",
    ]
    assert dhcp["dnsmasq"]["noresolv"] == "1"
    assert dhcp["dnsmasq"]["cachesize"] == "4096"
    proxy = json.loads((transaction_dir / "candidate" / "https-dns-proxy").read_text())
    assert set(proxy) == {"config", "quad9", "cloudflare_security", "control_d_ads_tracking", "mullvad_base"}
    assert proxy["config"] == {
        ".type": "main", "dnsmasq_config_update": "-", "force_dns": "0", "notrack_dns": "0",
    }
    expected_proxy = {
        "quad9": ("https://dns.quad9.net/dns-query", "5053"),
        "cloudflare_security": ("https://security.cloudflare-dns.com/dns-query", "5054"),
        "control_d_ads_tracking": ("https://freedns.controld.com/p2", "5055"),
        "mullvad_base": ("https://base.dns.mullvad.net/dns-query", "5056"),
    }
    for name, (url, port) in expected_proxy.items():
        assert proxy[name] == {
            ".type": "https-dns-proxy", "resolver_url": url, "listen_port": port,
            "bootstrap_dns": "9.9.9.11,1.1.1.1,8.8.8.8",
        }
    adblock = json.loads((transaction_dir / "candidate" / "adblock-fast").read_text())
    sources = {name: section for name, section in adblock.items() if section[".type"] == "file_url"}
    assert "unmanaged" not in adblock
    assert len(sources) == 19
    assert {section["name"] for section in sources.values()} == {
        "HaGeZi - Multi PRO", "OISD", "Steven Black", "Peter Lowe",
        "NextDNS - Windows", "NextDNS - Samsung", "NextDNS - Apple", "EasyList",
        "HaGeZi - Prevent DNS bypass", "Smart TV", "HaGeZi - LG webOS",
        "Smart TV blocklist", "Perflyst - Android tracking", "Divested - LG",
        "Divested - Mobile", "GameIndustry - Gaming hosts", "AdGuard CNAME trackers",
        "CERT Polska", "AdGuard",
    }
    assert all(section["action"] == "block" and section["enabled"] == "1" for section in sources.values())
    assert sources["peter_lowe"]["url"].endswith("&mimetype=plaintext")
    assert "/adblock/doh-vpn-proxy-bypass.txt" in sources["hagezi_dns_bypass"]["url"]
    manifest = (transaction_dir / "manifest.sha256").read_text()
    assert "backup/https-dns-proxy" in manifest
    assert "candidate/https-dns-proxy" in manifest
    assert (transaction_dir / "candidate" / "wireless").stat().st_mode & 0o777 == 0o600
    rendered = (transaction_dir / "overlay" / "wireguard").read_text()
    assert env["VPN_KEY"] not in rendered
    assert env["VPN_PSK"] not in rendered
    assert "${" not in rendered
    assert candidate["wan"]["ipv6"] == "0"
    assert "wan6" not in candidate
    assert "ula_prefix" not in candidate["globals"]
    assert candidate["wgserver"]["addresses"] == ["10.10.0.1/24"]
    assert candidate["wgclient"]["allowed_ips"] == ["10.10.0.2/32"]
    firewall = json.loads((transaction_dir / "candidate" / "firewall").read_text())
    assert firewall["wan"]["network"] == ["wan"]


def test_repeated_prepare_is_idempotent(router):
    _, config, backups, _, env = router
    _, first = prepare(env)
    for name in ("network", "firewall", "wireless", "dhcp", "system", "https-dns-proxy", "adblock-fast"):
        shutil.copy(backups / first / "candidate" / name, config / name)
    _, second = prepare(env)
    for name in ("network", "firewall", "wireless", "dhcp", "system", "https-dns-proxy", "adblock-fast"):
        data = json.loads((backups / second / "candidate" / name).read_text())
        assert len(data) == len(set(data))
    assert json.loads((backups / second / "candidate" / "network").read_text())["br_lan"]["stp"] == "1"


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
        "limit": "150", "leasetime": "12h",
    }
    (config / "dhcp").write_text(json.dumps(dhcp))
    firewall = {
        "@defaults[0]": {
            ".type": "defaults", "synflood_protect": "1", "input": "REJECT",
            "output": "ACCEPT", "forward": "REJECT",
        },
        "@zone[0]": {
            ".type": "zone", "name": "lan", "network": ["lan"],
            "input": "ACCEPT", "output": "ACCEPT", "forward": "ACCEPT",
        },
        "@zone[1]": {
            ".type": "zone", "name": "wan", "network": ["wan", "wan6"],
            "input": "REJECT", "output": "ACCEPT", "forward": "REJECT",
            "masq": "1", "mtu_fix": "1",
        },
        "@forwarding[0]": {".type": "forwarding", "src": "lan", "dest": "wan"},
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
    assert candidate["radio1"]["channel"] == "52"
    assert candidate["radio1"]["htmode"] == "HE80"


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


def test_setup_rejects_invalid_channel_before_mutation(router):
    root, _, _, _, env = router
    marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{marker}'\n")
    key = "A" * 43 + "="
    env.update({"VPN_KEY": key, "VPN_PUB": key, "VPN_PSK": key, "CHANNEL": "12"})
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
    names = ("network", "firewall", "wireless", "dhcp", "system", "https-dns-proxy", "adblock-fast")
    originals = {name: (config / name).read_text() for name in names}
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    original_modules = modules_conf.read_text()
    _, transaction = prepare(env)
    process = subprocess.Popen(
        [str(REPO / "router-config.sh"), "apply", transaction], env=env,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    pending = backups / transaction / "pending"
    for _ in range(100):
        if pending.exists(): break
        time.sleep(0.02)
    assert pending.exists()
    lock = Path(env["ROUTER_CONFIG_LOCK_DIR"])
    for _ in range(100):
        if not lock.exists(): break
        time.sleep(0.02)
    assert not lock.exists()
    confirm = run_router(env, "confirm", transaction)
    stdout, stderr = process.communicate(timeout=5)
    assert process.returncode == 0, stderr
    assert "confirm" in stdout
    assert "reboot after confirm" in stdout
    assert "reboot required for WED" in confirm.stdout
    assert json.loads((config / "network").read_text())["pixel"]["ipaddr"] == "192.168.8.1"
    assert json.loads((config / "network").read_text())["wan"]["ipaddr"] == "192.168.1.2"
    assert json.loads((config / "network").read_text())["wan"]["gateway"] == "192.168.1.1"
    assert json.loads((config / "firewall").read_text())["defaults"]["flow_offloading"] == "1"
    assert json.loads((config / "firewall").read_text())["defaults"]["flow_offloading_hw"] == "1"
    assert modules_conf.read_text().count("options mt7915e wed_enable=Y") == 1
    proxy = json.loads((config / "https-dns-proxy").read_text())
    assert set(proxy) == {"config", "quad9", "cloudflare_security", "control_d_ads_tracking", "mullvad_base"}
    run_router(env, "rollback", transaction)
    assert {name: (config / name).read_text() for name in originals} == originals
    assert modules_conf.read_text() == original_modules


def test_timeout_and_reboot_recovery_restore_backup(router):
    _, config, backups, _, env = router
    original = (config / "network").read_text()
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    original_modules = modules_conf.read_text()
    env["ROUTER_CONFIG_TIMEOUT"] = "0.15"
    _, transaction = prepare(env)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert (config / "network").read_text() == original
    assert modules_conf.read_text() == original_modules
    assert (backups / transaction / "state").read_text().strip() == "rolledback"

    _, transaction = prepare(env)
    shutil.copy(backups / transaction / "candidate" / "network", config / "network")
    shutil.copy(backups / transaction / "candidate" / "modules.conf", modules_conf)
    (backups / transaction / "pending").touch()
    (backups / transaction / "state").write_text("pending\n")
    run_router(env, "_recover-pending")
    assert (config / "network").read_text() == original
    assert modules_conf.read_text() == original_modules


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
    original_proxy = (config / "https-dns-proxy").read_text()
    _, transaction = prepare(env)
    fail_file = root / "fw4-fail"; fail_file.touch(); env["FW4_FAIL_FILE"] = str(fail_file)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "backups restored" in result.stderr
    assert (config / "network").read_text() == original
    assert (config / "https-dns-proxy").read_text() == original_proxy
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_https_dns_proxy_stop_failure_restores_backup(router):
    root, config, backups, _, env = router
    names = ("network", "firewall", "wireless", "dhcp", "system", "https-dns-proxy", "adblock-fast")
    originals = {name: (config / name).read_text() for name in names}
    _, transaction = prepare(env)
    fail = root / "https-stop-fail"
    fail.touch()
    env["STOP_FAIL_ONCE"] = str(fail)
    env["STOP_FAIL_NAME"] = "https-dns-proxy-init"
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "could not stop https-dns-proxy; backups restored" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_https_dns_proxy_nonzero_stop_is_accepted_when_all_listeners_stopped(router):
    root, _, backups, _, env = router
    _, transaction = prepare(env)
    fail = root / "https-stopped-with-nonzero"
    fail.touch()
    env["STOPPED_WITH_NONZERO_ONCE"] = str(fail)
    env["STOP_FAIL_NAME"] = "https-dns-proxy-init"
    process = subprocess.Popen(
        [str(REPO / "router-config.sh"), "apply", transaction], env=env,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    pending = backups / transaction / "pending"
    lock = Path(env["ROUTER_CONFIG_LOCK_DIR"])
    for _ in range(100):
        if pending.exists() and not lock.exists(): break
        time.sleep(0.02)
    assert pending.exists() and not lock.exists()
    run_router(env, "confirm", transaction)
    stdout, stderr = process.communicate(timeout=5)
    assert process.returncode == 0, stderr
    assert "https-dns-proxy stop returned nonzero; verifying listeners stopped" in stdout
    assert (backups / transaction / "state").read_text().strip() == "confirmed"


def test_https_dns_proxy_nonzero_restart_is_accepted_when_all_listeners_are_ready(router):
    root, _, backups, _, env = router
    _, transaction = prepare(env)
    fail = root / "https-restart-fail"
    fail.touch()
    env["SERVICE_FAIL_ONCE"] = str(fail)
    env["SERVICE_FAIL_NAME"] = "https-dns-proxy-init"
    env["SERVICE_FAIL_ACTION"] = "restart"
    process = subprocess.Popen(
        [str(REPO / "router-config.sh"), "apply", transaction], env=env,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    pending = backups / transaction / "pending"
    lock = Path(env["ROUTER_CONFIG_LOCK_DIR"])
    for _ in range(100):
        if pending.exists() and not lock.exists(): break
        time.sleep(0.02)
    assert pending.exists() and not lock.exists()
    run_router(env, "confirm", transaction)
    stdout, stderr = process.communicate(timeout=5)
    assert process.returncode == 0, stderr
    assert "https-dns-proxy restart returned nonzero; verifying listeners" in stdout
    assert (backups / transaction / "state").read_text().strip() == "confirmed"


@pytest.mark.parametrize(("service_name", "action", "failure_label"), [
    ("network-init", "reload", "network"),
    ("wifi", "reload", "wifi"),
    ("firewall-init", "reload", "firewall"),
    ("sysntpd-init", "restart", "sysntpd"),
    ("https-dns-proxy-init", "restart", "https-dns-proxy"),
    ("dnsmasq-init", "restart", "dnsmasq"),
    ("adblock-init", "restart", "adblock-fast"),
])
def test_each_coordinated_service_failure_is_named_and_restores_every_file(
    router, service_name, action, failure_label
):
    root, config, backups, _, env = router
    names = ("network", "firewall", "wireless", "dhcp", "system", "https-dns-proxy", "adblock-fast")
    originals = {name: (config / name).read_text() for name in names}
    _, transaction = prepare(env)
    fail = root / f"{service_name}-fail"
    fail.touch()
    if service_name == "wifi":
        env["WIFI_FAIL_ONCE"] = str(fail)
    else:
        env["SERVICE_FAIL_ONCE"] = str(fail)
        env["SERVICE_FAIL_NAME"] = service_name
        env["SERVICE_FAIL_ACTION"] = action
    if service_name == "https-dns-proxy-init":
        proc_net = Path(env["ROUTER_CONFIG_PROC_NET_DIR"])
        backup_only = "".join(
            f"   {index}: 0100007F:{port:04X} 00000000:0000 0A\n"
            for index, port in enumerate((5053, 5054, 5999))
        )
        (proc_net / "tcp").write_text(backup_only)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert f"service reload failed at {failure_label}; backups restored" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_transaction_tampering_is_rejected(router):
    _, config, backups, _, env = router
    original = (config / "network").read_text()
    _, transaction = prepare(env)
    with (backups / transaction / "candidate" / "network").open("a") as stream:
        stream.write("tampered")
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "checksum verification failed" in result.stderr
    assert (config / "network").read_text() == original


def test_partial_candidate_installation_failure_restores_all_packages(router):
    root, config, backups, _, env = router
    names = ("network", "firewall", "wireless", "dhcp", "system", "https-dns-proxy", "adblock-fast")
    originals = {name: (config / name).read_text() for name in names}
    modules_conf = Path(env["ROUTER_CONFIG_MODULES_CONF"])
    original_modules = modules_conf.read_text()
    _, transaction = prepare(env)
    fail = root / "install-fail"
    fail.touch()
    real_cp = next(path for path in ("/bin/cp", "/usr/bin/cp") if Path(path).exists())
    write_executable(root / "bin" / "cp", f'''#!/bin/sh
if [ -e "{fail}" ]; then
    case "$1" in
        */candidate/firewall) rm -f "{fail}"; exit 1 ;;
    esac
fi
exec {real_cp} "$@"
''')
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "candidate installation failed" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert modules_conf.read_text() == original_modules
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_setup_rejects_an_incomplete_repository_before_mutation(router):
    root, _, _, _, env = router
    setup_copy = root / "setup.sh"
    write_executable(setup_copy, (REPO / "setup.sh").read_text())
    mutation_marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{mutation_marker}'\n")
    key = "A" * 43 + "="
    env.update({"VPN_KEY": key, "VPN_PUB": key, "VPN_PSK": key})
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
    env.update({"VPN_KEY": key, "VPN_PUB": key, "VPN_PSK": key})
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
        "VPN_PUB": key,
        "VPN_PSK": key,
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


def test_https_dns_proxy_validation_and_forward_mismatch_are_preapply_failures(router):
    _, config, backups, overlays, env = router
    original = (config / "network").read_text()
    with (overlays / "dns-over-https").open("a") as stream:
        stream.write("\nset https-dns-proxy.quad9.resolver_url='https://example.invalid/dns-query'\n")
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert "unexpected https-dns-proxy URL for quad9" in result.stderr
    assert (config / "network").read_text() == original

    shutil.rmtree(backups)
    (overlays / "dns-over-https").write_text(
        (REPO / "uci/dns-over-https").read_text().replace(
            "127.0.0.1#5056", "127.0.0.1#5999"
        )
    )
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert "dnsmasq upstreams do not match" in result.stderr
    assert (config / "network").read_text() == original


def test_feature_install_callbacks_only_install_and_enable(router):
    root, config, _, _, env = router
    names = ("network", "firewall", "dhcp", "https-dns-proxy", "adblock-fast")
    before = {name: (config / name).read_text() for name in names}
    apk_log = root / "apk.log"
    init_log = root / "init.log"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{apk_log}'\n")
    init = root / "bin" / "init-install"
    write_executable(init, f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{init_log}'\n")
    env["ROUTER_CONFIG_HTTPS_DNS_PROXY_INIT"] = str(init)
    env["ROUTER_CONFIG_ADBLOCK_INIT"] = str(init)
    run_module(env, "dns-over-https.sh", "dns_over_https_install")
    run_module(env, "adblock-fast.sh", "adblock_fast_install")
    run_module(env, "wireguard.sh", "wireguard_install")
    assert apk_log.read_text().splitlines() == [
        "add https-dns-proxy luci-app-https-dns-proxy",
        "add adblock-fast luci-app-adblock-fast",
        "add wireguard-tools luci-proto-wireguard",
    ]
    assert init_log.read_text().splitlines() == ["enable", "enable"]
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
    assert "dns" + "crypt" not in project_shell.lower()
    assert "apk add https-dns-proxy luci-app-https-dns-proxy" in project_shell
    assert "apk add wireguard-tools luci-proto-wireguard" in project_shell


def test_setup_declares_fixed_module_order_and_all_members():
    source = (REPO / "setup.sh").read_text()
    calls = [
        'router-config.sh" check-base',
        "base_packages_run",
        "dns_over_https_install",
        "adblock_fast_install",
        "wireguard_install",
        'router-config.sh\" prepare',
    ]
    positions = [source.rindex(call) for call in calls]
    assert positions == sorted(positions)
    for name in (
        "base-packages", "network", "firewall", "wireless",
        "dns-over-https", "adblock-fast", "wireguard",
    ):
        assert f"modules/{name}.sh" in source
    assert "SCRIPT_DIR=$(CDPATH=" in source
    assert "uclient-fetch" not in source
    assert "ROUTER_CONFIG_" + "BUNDLE" not in source
    assert "adblock" + "-lean" not in source
    assert "--recovery-ready" in source
    assert "dns_over_https_run" not in source
    assert "adblock_fast_run" not in source
    assert "wireguard_run" not in source
    assert "adblock selector" not in (REPO / "README.md").read_text().lower()

    transaction_source = (REPO / "router-config.sh").read_text()
    assert transaction_source.index('"$HTTPS_DNS_PROXY_INIT" restart') < transaction_source.index(
        '"$DNSMASQ_INIT" restart'
    )
