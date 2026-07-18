import json
import hashlib
import os
import shutil
import subprocess
import tarfile
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
        return json.load(f)

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
if command in ("set", "add_list", "del_list", "delete"):
    sys.exit(mutate([command, args[0]]))
target = args[0]
if command == "show" and "." not in target:
    package = target
    data = load(package)
    for name, section_data in data.items():
        print(f"{package}.{name}='{section_data['.type']}'")
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
    backups = tmp_path / "backups"
    runtime = tmp_path / "libexec" / "router-config"
    init = tmp_path / "init.d" / "router-config-rollback"
    overlays = tmp_path / "overlays"
    modules = tmp_path / "modules"
    config.mkdir(); bin_dir.mkdir(); overlays.mkdir(); modules.mkdir()
    for name in ("br-lan", "lan1", "lan2", "lan3", "lan4"):
        (sys_net / name).mkdir(parents=True)
    for name in ("network", "firewall", "wireless", "dns-over-https", "adblock-fast", "wireguard"):
        shutil.copy(REPO / "uci" / name, overlays / name)
    for name in ("network", "firewall", "wireless", "dns-over-https", "adblock-fast", "wireguard"):
        shutil.copy(REPO / "modules" / f"{name}.sh", modules / f"{name}.sh")

    network = {
        "loopback": {".type": "interface", "proto": "static"},
        "globals": {".type": "globals", "ula_prefix": "fd00::/48"},
        "wan": {".type": "interface", "proto": "dhcp"},
        "wan6": {".type": "interface", "proto": "dhcpv6"},
        "br_lan": {".type": "device", "name": "br-lan", "ports": ["lan1", "lan2", "lan3", "lan4"], "stp": "1"},
        "unrelated": {".type": "interface", "proto": "none"},
    }
    firewall = {
        "defaults": {".type": "defaults", "input": "REJECT"},
        "wan": {".type": "zone", "name": "wan", "network": ["wan", "wan6"]},
        "unrelated": {".type": "rule", "name": "Keep me"},
    }
    wireless = {"radio0": {".type": "wifi-device", "type": "mac80211", "channel": "auto"}}
    dhcp = {
        "dnsmasq": {".type": "dnsmasq", "server": ["old"], "domainneeded": "1"},
        "unrelated": {".type": "dhcp", "interface": "unrelated", "ignore": "1"},
    }
    system = {"ntp": {".type": "timeserver", "server": ["old"]}, "unrelated": {".type": "system", "hostname": "keep"}}
    adblock = {"config": {".type": "adblock-fast", "enabled": "0"}, "unmanaged": {".type": "file_url", "name": "Keep me"}}
    for name, value in (("network", network), ("firewall", firewall), ("wireless", wireless), ("dhcp", dhcp), ("system", system), ("adblock-fast", adblock)):
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
    write_executable(bin_dir / "dnscrypt-proxy", "#!/bin/sh\n[ ! -e \"${DNSCRYPT_FAIL_FILE:-/nonexistent}\" ]\n")
    service_source = '''#!/bin/sh
service_name=${0##*/}
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
    for name in ("network-init", "firewall-init", "sysntpd-init", "dnscrypt-init", "dnsmasq-init", "adblock-init"):
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
        "ROUTER_CONFIG_INIT_SCRIPT": str(init),
        "ROUTER_CONFIG_LIBEXEC": str(runtime),
        "ROUTER_CONFIG_UCI_DIR": str(overlays),
        "ROUTER_CONFIG_MODULE_DIR": str(modules),
        "ROUTER_CONFIG_NETWORK_INIT": str(services["network-init"]),
        "ROUTER_CONFIG_FIREWALL_INIT": str(services["firewall-init"]),
        "ROUTER_CONFIG_SYSNTPD_INIT": str(services["sysntpd-init"]),
        "ROUTER_CONFIG_DNSCRYPT_INIT": str(services["dnscrypt-init"]),
        "ROUTER_CONFIG_DNSMASQ_INIT": str(services["dnsmasq-init"]),
        "ROUTER_CONFIG_ADBLOCK_INIT": str(services["adblock-init"]),
        "ROUTER_CONFIG_DNSCRYPT_CONFIG": str(tmp_path / "dnscrypt-live.toml"),
        "ROUTER_CONFIG_DNSCRYPT_SOURCE": str(REPO / "configs/dnscrypt/dnscrypt-proxy.toml"),
        "ROUTER_CONFIG_TIMEOUT": "2",
        "ROUTER_CONFIG_POLL_INTERVAL": "0.05",
        "PIXEL_WIFI_PASSWORD": "pixel-secret-123",
        "THINGS_WIFI_PASSWORD": "things-secret-123",
        "GUEST_WIFI_PASSWORD": "guest-secret-123",
        "IOT_WIFI_PASSWORD": "iot-secret-123",
        "VPN_IF": "wgserver",
        "VPN_PORT": "51820",
        "VPN_KEY": "private-secret",
        "VPN_ADDR": "10.10.0.1/24",
        "VPN_ADDR6": "fd10::1/64",
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
    assert "pixel-secret-123" not in result.stdout + result.stderr
    assert (backups / transaction).stat().st_mode & 0o777 == 0o700
    transaction_dir = backups / transaction
    dhcp = json.loads((transaction_dir / "candidate" / "dhcp").read_text())
    for name in ("pixel", "pixelthings", "pixelguest", "pixeliot"):
        assert dhcp[name] == {
            ".type": "dhcp", "interface": name, "ignore": "0",
            "start": "100", "limit": "150", "leasetime": "12h",
        }
    assert dhcp["unrelated"]["ignore"] == "1"
    assert dhcp["dnsmasq"]["server"] == ["127.0.0.53#53"]
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
    assert (transaction_dir / "backup" / "dnscrypt-proxy.missing").exists()
    assert (transaction_dir / "candidate" / "wireless").stat().st_mode & 0o777 == 0o600
    rendered = (transaction_dir / "overlay" / "wireguard").read_text()
    assert env["VPN_KEY"] not in rendered
    assert env["VPN_PSK"] not in rendered
    assert "${" not in rendered


def test_repeated_prepare_is_idempotent(router):
    _, config, backups, _, env = router
    _, first = prepare(env)
    for name in ("network", "firewall", "wireless", "dhcp", "system", "adblock-fast"):
        shutil.copy(backups / first / "candidate" / name, config / name)
    shutil.copy(backups / first / "candidate" / "dnscrypt-proxy.toml", env["ROUTER_CONFIG_DNSCRYPT_CONFIG"])
    _, second = prepare(env)
    for name in ("network", "firewall", "wireless", "dhcp", "system", "adblock-fast"):
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


def test_missing_transaction_module_is_rejected(router):
    root, _, backups, _, env = router
    (root / "modules" / "firewall.sh").unlink()
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "missing transaction module" in result.stderr
    assert not backups.exists()


def test_apply_confirm_and_manual_rollback(router):
    _, config, backups, _, env = router
    originals = {name: (config / name).read_text() for name in ("network", "firewall", "wireless", "dhcp", "system", "adblock-fast")}
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
    run_router(env, "confirm", transaction)
    stdout, stderr = process.communicate(timeout=5)
    assert process.returncode == 0, stderr
    assert "confirm" in stdout
    assert json.loads((config / "network").read_text())["pixel"]["ipaddr"] == "192.168.1.1"
    assert Path(env["ROUTER_CONFIG_DNSCRYPT_CONFIG"]).exists()
    run_router(env, "rollback", transaction)
    assert {name: (config / name).read_text() for name in originals} == originals
    assert not Path(env["ROUTER_CONFIG_DNSCRYPT_CONFIG"]).exists()


def test_timeout_and_reboot_recovery_restore_backup(router):
    _, config, backups, _, env = router
    original = (config / "network").read_text()
    env["ROUTER_CONFIG_TIMEOUT"] = "0.15"
    _, transaction = prepare(env)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert (config / "network").read_text() == original
    assert (backups / transaction / "state").read_text().strip() == "rolledback"

    _, transaction = prepare(env)
    shutil.copy(backups / transaction / "candidate" / "network", config / "network")
    (backups / transaction / "pending").touch()
    (backups / transaction / "state").write_text("pending\n")
    run_router(env, "_recover-pending")
    assert (config / "network").read_text() == original


def test_fw4_failure_does_not_change_live_configuration(router):
    root, config, _, _, env = router
    original = (config / "network").read_text()
    fail_file = root / "fw4-fail"; fail_file.touch(); env["FW4_FAIL_FILE"] = str(fail_file)
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert result.returncode != 0
    assert "fw4 rejected candidate" in result.stderr
    assert (config / "network").read_text() == original


def test_apply_fw4_and_reload_failures_restore_backup(router):
    root, config, backups, _, env = router
    original = (config / "network").read_text()
    dnscrypt_live = Path(env["ROUTER_CONFIG_DNSCRYPT_CONFIG"])
    dnscrypt_live.write_text("original dnscrypt configuration\n")
    _, transaction = prepare(env)
    fail_file = root / "fw4-fail"; fail_file.touch(); env["FW4_FAIL_FILE"] = str(fail_file)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "backups restored" in result.stderr
    assert (config / "network").read_text() == original
    assert dnscrypt_live.read_text() == "original dnscrypt configuration\n"
    assert (backups / transaction / "state").read_text().strip() == "rolledback"

    fail_file.unlink(); env.pop("FW4_FAIL_FILE")
    _, transaction = prepare(env)
    service_fail = root / "service-fail"; service_fail.touch(); env["SERVICE_FAIL_ONCE"] = str(service_fail)
    env["SERVICE_FAIL_NAME"] = "network-init"
    env["SERVICE_FAIL_ACTION"] = "restart"
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "service reload failed" in result.stderr
    assert (config / "network").read_text() == original
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


@pytest.mark.parametrize(("service_name", "action"), [
    ("wifi", "reload"),
    ("firewall-init", "reload"),
    ("sysntpd-init", "restart"),
    ("dnscrypt-init", "restart"),
    ("dnsmasq-init", "restart"),
    ("adblock-init", "restart"),
])
def test_each_coordinated_service_failure_restores_every_file(router, service_name, action):
    root, config, backups, _, env = router
    names = ("network", "firewall", "wireless", "dhcp", "system", "adblock-fast")
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
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "service reload failed" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert not Path(env["ROUTER_CONFIG_DNSCRYPT_CONFIG"]).exists()
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
    names = ("network", "firewall", "wireless", "dhcp", "system", "adblock-fast")
    originals = {name: (config / name).read_text() for name in names}
    _, transaction = prepare(env)
    fail = root / "install-fail"
    fail.touch()
    write_executable(root / "bin" / "cp", f'''#!/bin/sh
if [ -e "{fail}" ]; then
    case "$1" in
        */candidate/firewall) rm -f "{fail}"; exit 1 ;;
    esac
fi
exec /usr/bin/cp "$@"
''')
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "candidate installation failed" in result.stderr
    assert {name: (config / name).read_text() for name in names} == originals
    assert (backups / transaction / "state").read_text().strip() == "rolledback"


def test_bundle_contains_every_module(tmp_path):
    archive = tmp_path / "router-config-bundle.tar.gz"
    subprocess.run(
        [str(REPO / "tools" / "build-router-config-bundle.sh"), str(archive)],
        check=True,
        text=True,
        capture_output=True,
    )
    with tarfile.open(archive) as bundle:
        members = set(bundle.getnames())
    expected = {
        f"modules/{name}.sh"
        for name in (
            "base-packages", "network", "firewall", "wireless",
            "dns-over-https", "adblock-fast", "wireguard",
        )
    }
    assert expected <= members
    assert {
        f"uci/{name}" for name in (
            "network", "firewall", "wireless", "dns-over-https",
            "adblock-fast", "wireguard",
        )
    } <= members
    assert not any(member.startswith("configs/openwrt") for member in members)
    retired_name = "adblock" + "-lean"
    assert not any(retired_name in member for member in members)


def test_setup_rejects_tampered_and_incomplete_bundles_before_mutation(router):
    root, _, _, _, env = router
    good_archive = root / "good.tar.gz"
    subprocess.run(
        [str(REPO / "tools" / "build-router-config-bundle.sh"), str(good_archive)],
        check=True,
        text=True,
        capture_output=True,
    )
    good_digest = hashlib.sha256(good_archive.read_bytes()).hexdigest()
    setup_source = (REPO / "setup.sh").read_text().replace(
        "REPLACE_WITH_IMMUTABLE_VERSION", "test-v1"
    ).replace("REPLACE_WITH_64_CHARACTER_SHA256", good_digest)
    setup_copy = root / "setup.sh"
    write_executable(setup_copy, setup_source)
    mutation_marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{mutation_marker}'\n")
    key = "A" * 43 + "="
    env.update({
        "VPN_IF": "wgserver", "VPN_PORT": "51820", "VPN_KEY": key,
        "VPN_ADDR": "10.10.0.1/24", "VPN_ADDR6": "fd10::1/64",
        "VPN_PUB": key, "VPN_PSK": key,
    })

    tampered_archive = root / "tampered.tar.gz"
    tampered_archive.write_bytes(good_archive.read_bytes() + b"tampered")
    write_executable(
        root / "bin" / "uclient-fetch",
        f"#!/bin/sh\ncp '{tampered_archive}' \"$3\"\n",
    )
    result = subprocess.run(
        [str(setup_copy), "--recovery-ready"], env=env, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "FAILED" in result.stdout + result.stderr
    assert not mutation_marker.exists()

    incomplete_archive = root / "incomplete.tar.gz"
    with tarfile.open(incomplete_archive, "w:gz") as bundle:
        bundle.add(REPO / "router-config.sh", arcname="router-config.sh")
    incomplete_digest = hashlib.sha256(incomplete_archive.read_bytes()).hexdigest()
    write_executable(
        setup_copy,
        setup_source.replace(good_digest, incomplete_digest),
    )
    write_executable(
        root / "bin" / "uclient-fetch",
        f"#!/bin/sh\ncp '{incomplete_archive}' \"$3\"\n",
    )
    result = subprocess.run(
        [str(setup_copy), "--recovery-ready"], env=env, text=True, capture_output=True,
    )
    assert result.returncode != 0
    assert "bundle member is missing or empty" in result.stderr
    assert not mutation_marker.exists()


def test_setup_validates_all_inputs_before_mutation(router):
    root, _, _, _, env = router
    marker = root / "mutation-attempted"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\ntouch '{marker}'\n")
    write_executable(root / "bin" / "uclient-fetch", f"#!/bin/sh\ntouch '{marker}'\n")
    key = "A" * 43 + "="
    env.update({
        "VPN_IF": "bad-name;unsafe",
        "VPN_PORT": "51820",
        "VPN_KEY": key,
        "VPN_ADDR": "10.10.0.1/24",
        "VPN_ADDR6": "fd10::1/64",
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


def test_dnscrypt_validation_and_endpoint_mismatch_are_preapply_failures(router):
    root, config, _, _, env = router
    original = (config / "network").read_text()
    fail = root / "dnscrypt-fail"
    fail.touch()
    env["DNSCRYPT_FAIL_FILE"] = str(fail)
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert "DNSCrypt rejected candidate" in result.stderr
    assert (config / "network").read_text() == original

    fail.unlink()
    env.pop("DNSCRYPT_FAIL_FILE")
    mismatched = root / "dnscrypt-mismatch.toml"
    mismatched.write_text(
        (REPO / "configs/dnscrypt/dnscrypt-proxy.toml").read_text().replace(
            "127.0.0.53:53", "127.0.0.54:53", 1
        )
    )
    env["ROUTER_CONFIG_DNSCRYPT_SOURCE"] = str(mismatched)
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert "does not match dnsmasq upstream" in result.stderr


def test_feature_install_callbacks_only_install_and_enable(router):
    root, config, _, _, env = router
    names = ("network", "firewall", "dhcp", "adblock-fast")
    before = {name: (config / name).read_text() for name in names}
    apk_log = root / "apk.log"
    init_log = root / "init.log"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{apk_log}'\n")
    init = root / "bin" / "init-install"
    write_executable(init, f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{init_log}'\n")
    env["ROUTER_CONFIG_DNSCRYPT_INIT"] = str(init)
    env["ROUTER_CONFIG_ADBLOCK_INIT"] = str(init)
    run_module(env, "dns-over-https.sh", "dns_over_https_install")
    run_module(env, "adblock-fast.sh", "adblock_fast_install")
    run_module(env, "wireguard.sh", "wireguard_install")
    assert apk_log.read_text().splitlines() == [
        "add dnscrypt-proxy2",
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
        "add gawk grep sed coreutils-sort nano",
    ]
    project_shell = "\n".join(
        path.read_text()
        for path in [REPO / "setup.sh", *(REPO / "modules").glob("*.sh")]
    )
    assert "op" + "kg" not in project_shell
    assert "apk add dnscrypt-proxy2" in project_shell
    assert "apk add wireguard-tools luci-proto-wireguard" in project_shell


def test_setup_declares_fixed_module_order_and_all_members():
    source = (REPO / "setup.sh").read_text()
    calls = [
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
    assert "adblock" + "-lean" not in source
    assert "--recovery-ready" in source
    assert "dns_over_https_run" not in source
    assert "adblock_fast_run" not in source
    assert "wireguard_run" not in source
    assert "adblock selector" not in (REPO / "README.md").read_text().lower()
