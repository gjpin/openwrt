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
    for name in ("network", "firewall", "wireless"):
        shutil.copy(REPO / "configs/openwrt" / name, overlays / name)
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
    for name, value in (("network", network), ("firewall", firewall), ("wireless", wireless)):
        (config / name).write_text(json.dumps(value))

    write_executable(bin_dir / "uci", UCI_STUB)
    write_executable(bin_dir / "ubus", "#!/bin/sh\nexit 0\n")
    write_executable(bin_dir / "wifi", "#!/bin/sh\nexit 0\n")
    write_executable(bin_dir / "fw4", "#!/bin/sh\n[ ! -e \"${FW4_FAIL_FILE:-/nonexistent}\" ]\n")
    service = bin_dir / "service-stub"
    write_executable(service, '''#!/bin/sh
if [ -e "${SERVICE_FAIL_ONCE:-/nonexistent}" ]; then
    rm -f "$SERVICE_FAIL_ONCE"
    exit 1
fi
exit 0
''')

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
        "ROUTER_CONFIG_OVERLAY_DIR": str(overlays),
        "ROUTER_CONFIG_MODULE_DIR": str(modules),
        "ROUTER_CONFIG_NETWORK_INIT": str(service),
        "ROUTER_CONFIG_FIREWALL_INIT": str(service),
        "ROUTER_CONFIG_TIMEOUT": "2",
        "ROUTER_CONFIG_POLL_INTERVAL": "0.05",
        "MAIN_WIFI_PASSWORD": "main-secret-123",
        "SECONDARY_WIFI_PASSWORD": "secondary-secret-123",
        "GUEST_WIFI_PASSWORD": "guest-secret-123",
        "IOT_WIFI_PASSWORD": "iot-secret-123",
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
    result = run_router(env, "prepare", "--recovery-ready")
    return result, result.stdout.strip().splitlines()[-1]


def test_prepare_preserves_base_and_is_secret_safe(router):
    _, _, backups, _, env = router
    result, transaction = prepare(env)
    candidate = json.loads((backups / transaction / "candidate" / "network").read_text())
    assert candidate["br_lan"]["stp"] == "1"
    assert candidate["unrelated"] == {".type": "interface", "proto": "none"}
    assert set(name for name in candidate if name == "pixelmain") == {"pixelmain"}
    assert "main-secret-123" not in result.stdout + result.stderr
    assert (backups / transaction).stat().st_mode & 0o777 == 0o700


def test_repeated_prepare_is_idempotent(router):
    _, config, backups, _, env = router
    _, first = prepare(env)
    for name in ("network", "firewall", "wireless"):
        shutil.copy(backups / first / "candidate" / name, config / name)
    _, second = prepare(env)
    for name in ("network", "firewall", "wireless"):
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
        stream.write("\nset network.pixelmain.bad='${UNRESOLVED}'\n")
    result = run_router(env, "prepare", "--recovery-ready", check=False)
    assert "unresolved placeholder" in result.stderr
    (overlays / "network").write_text((REPO / "configs/openwrt/network").read_text())
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
    original = (config / "network").read_text()
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
    assert json.loads((config / "network").read_text())["pixelmain"]["ipaddr"] == "192.168.1.1"
    run_router(env, "rollback", transaction)
    assert (config / "network").read_text() == original


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
    _, transaction = prepare(env)
    fail_file = root / "fw4-fail"; fail_file.touch(); env["FW4_FAIL_FILE"] = str(fail_file)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "backup restored" in result.stderr
    assert (config / "network").read_text() == original
    assert (backups / transaction / "state").read_text().strip() == "rolledback"

    fail_file.unlink(); env.pop("FW4_FAIL_FILE")
    _, transaction = prepare(env)
    service_fail = root / "service-fail"; service_fail.touch(); env["SERVICE_FAIL_ONCE"] = str(service_fail)
    result = run_router(env, "apply", transaction, check=False)
    assert result.returncode != 0
    assert "service reload failed" in result.stderr
    assert (config / "network").read_text() == original
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
    for secret in (key, env["MAIN_WIFI_PASSWORD"], env["VPN_KEY"]):
        assert secret not in result.stdout + result.stderr


def run_module(env, module_name, function_call):
    result = subprocess.run(
        ["sh", "-eu", "-c", f'. "{REPO / "modules" / module_name}"; {function_call}'],
        env=env, text=True, capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    return result


def test_dns_and_wireguard_modules_are_idempotent(router):
    root, config, _, _, env = router
    env["UCI_STUB_CONFIG_DIR"] = str(config)
    env.update({
        "VPN_IF": "wgserver",
        "VPN_PORT": "51820",
        "VPN_KEY": "private-secret",
        "VPN_ADDR": "10.10.0.1/24",
        "VPN_ADDR6": "fd10::1/64",
        "VPN_PUB": "public-secret",
        "VPN_PSK": "preshared-secret",
    })
    write_executable(root / "bin" / "apk", "#!/bin/sh\nexit 0\n")
    write_executable(root / "bin" / "dnscrypt-proxy", "#!/bin/sh\nexit 0\n")
    write_executable(root / "bin" / "service", "#!/bin/sh\nexit 0\n")
    dnscrypt_target = root / "dnscrypt-proxy.toml"
    env["DNSCRYPT_CONFIG_FILE"] = str(dnscrypt_target)
    (config / "dhcp").write_text(json.dumps({"@dnsmasq[0]": {".type": "dnsmasq", "server": ["old"]}}))
    (config / "system").write_text(json.dumps({"ntp": {".type": "timeserver", "server": ["old"]}}))

    run_module(env, "dns-over-https.sh", f'dns_over_https_run "{REPO}"')
    first_dns = {name: (config / name).read_text() for name in ("dhcp", "system", "network", "firewall")}
    run_module(env, "dns-over-https.sh", f'dns_over_https_run "{REPO}"')
    assert first_dns == {name: (config / name).read_text() for name in first_dns}
    assert "127.0.0.53:53" in dnscrypt_target.read_text()
    assert json.loads((config / "dhcp").read_text())["@dnsmasq[0]"]["server"] == ["127.0.0.53#53"]

    run_module(env, "wireguard.sh", "wireguard_run")
    first_wg = {name: (config / name).read_text() for name in ("network", "firewall")}
    run_module(env, "wireguard.sh", "wireguard_run")
    assert first_wg == {name: (config / name).read_text() for name in first_wg}
    firewall = json.loads((config / "firewall").read_text())
    assert firewall["pixelmain"]["network"].count("wgserver") == 1
    assert [name for name in firewall if name == "allow_wireguard"] == ["allow_wireguard"]


def test_adblock_fast_is_apk_installed_configured_and_idempotent(router):
    root, config, _, _, env = router
    env["UCI_STUB_CONFIG_DIR"] = str(config)
    (config / "adblock-fast").write_text(json.dumps({
        "config": {
            ".type": "adblock-fast",
            "enabled": "0",
            "force_dns_interface": ["lan"],
            "force_dns_port": ["53"],
        },
        "unmanaged": {
            ".type": "file_url",
            "name": "Keep me",
            "url": "https://example.invalid/list.txt",
        },
    }))
    apk_log = root / "apk.log"
    service_log = root / "service.log"
    write_executable(root / "bin" / "apk", f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{apk_log}'\n")
    write_executable(root / "bin" / "service", f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{service_log}'\n")

    run_module(env, "adblock-fast.sh", "adblock_fast_run")
    first = (config / "adblock-fast").read_text()
    run_module(env, "adblock-fast.sh", "adblock_fast_run")
    assert first == (config / "adblock-fast").read_text()

    data = json.loads(first)
    assert data["config"]["enabled"] == "1"
    assert data["config"]["dns"] == "dnsmasq.servers"
    assert data["config"]["force_dns"] == "1"
    assert data["config"]["force_dns_interface"] == [
        "pixelmain", "pixelsecondary", "pixelguest", "pixeliot",
    ]
    assert data["config"]["force_dns_port"] == ["53", "853"]
    assert data["config"]["download_allow_insecure"] == "0"
    assert data["config"]["allow_non_ascii"] == "0"
    assert data["unmanaged"]["name"] == "Keep me"

    sources = {
        "adguard_general": (
            "AdGuard general",
            "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt",
        ),
        "hagezi_pro": (
            "Hagezi Pro",
            "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro-onlydomains.txt",
        ),
        "adguard_cname_trackers": (
            "AdGuard CNAME trackers",
            "https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_disguised_trackers_justdomains.txt",
        ),
        "cert_polska": (
            "CERT Polska",
            "https://hole.cert.pl/domains/v2/domains.txt",
        ),
    }
    assert {
        name: (section["name"], section["url"])
        for name, section in data.items()
        if name in sources
    } == sources
    for name in sources:
        assert data[name][".type"] == "file_url"
        assert data[name]["action"] == "block"
        assert data[name]["enabled"] == "1"

    assert apk_log.read_text().splitlines() == [
        "add adblock-fast luci-app-adblock-fast",
        "add adblock-fast luci-app-adblock-fast",
    ]
    assert service_log.read_text().splitlines() == [
        "adblock-fast enable", "adblock-fast restart",
        "adblock-fast enable", "adblock-fast restart",
    ]
    source = (REPO / "modules" / "adblock-fast.sh").read_text()
    assert source.count("uci commit adblock-fast") == 1


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


def test_adblock_fast_restart_failure_is_propagated(router):
    root, config, _, _, env = router
    env["UCI_STUB_CONFIG_DIR"] = str(config)
    (config / "adblock-fast").write_text(json.dumps({
        "config": {".type": "adblock-fast"},
    }))
    write_executable(root / "bin" / "apk", "#!/bin/sh\nexit 0\n")
    write_executable(
        root / "bin" / "service",
        "#!/bin/sh\n[ \"$2\" != restart ]\n",
    )
    result = subprocess.run(
        [
            "sh", "-eu", "-c",
            f'. "{REPO / "modules" / "adblock-fast.sh"}"; adblock_fast_run',
        ],
        env=env, text=True, capture_output=True,
    )
    assert result.returncode != 0


def test_setup_declares_fixed_module_order_and_all_members():
    source = (REPO / "setup.sh").read_text()
    calls = [
        "base_packages_run",
        'router-config.sh\" prepare',
        "dns_over_https_run",
        "adblock_fast_run",
        "wireguard_run",
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
    assert "adblock selector" not in (REPO / "README.md").read_text().lower()
