import importlib.util
import io
import tarfile
from pathlib import Path


REPO = Path(__file__).parents[1]


def load_script(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, REPO / relative)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_vm_release_inputs_are_pinned_and_archive_is_secret_free(tmp_path):
    vm = load_script("run_vm_tests", "tools/run-vm-tests.py")
    assert vm.RELEASE == "25.12.4"
    assert set(vm.ARTIFACTS) == {
        "openwrt-25.12.4-armsr-armv8-generic-kernel.bin",
        "openwrt-25.12.4-armsr-armv8-generic-initramfs-kernel.bin",
        "openwrt-25.12.4-armsr-armv8-generic-ext4-rootfs.img.gz",
    }
    assert all(len(value) == 64 for value in vm.ARTIFACTS.values())
    archive = tmp_path / "repository.tar.gz"
    assert len(vm.make_repository_archive(archive)) == 64
    with tarfile.open(archive) as bundle:
        names = bundle.getnames()
    assert "openwrt/tools/vm/guest-tests.sh" in names
    assert not any("/.git/" in name or "/.cache/" in name for name in names)


def test_vm_installs_split_resize2fs_package():
    source = (REPO / "tools/run-vm-tests.py").read_text()
    assert "apk add resize2fs" in source
    assert "apk add e2fsprogs" not in source
    assert "for attempt in 1 2 3; do apk update && break" in source
    assert "! grep -q '^/dev/vda ' /proc/mounts" in source
    assert "resize2fs /dev/vda && sync" in source


def test_vm_initramfs_does_not_mount_acceptance_disk_as_root():
    vm = load_script("run_vm_initramfs", "tools/run-vm-tests.py")
    initramfs = vm.qemu_command("qemu", Path("initramfs"), Path("disk"), False)
    disk_root = vm.qemu_command("qemu", Path("kernel"), Path("disk"), True)
    assert initramfs[initramfs.index("-append") + 1] == "console=ttyAMA0,115200n8"
    assert disk_root[disk_root.index("-append") + 1].startswith("root=/dev/vda rootwait ")
    netdev = disk_root[disk_root.index("-netdev") + 1]
    assert "net=192.168.2.0/24" in netdev
    assert "host=192.168.2.1" in netdev
    assert "dhcpstart=192.168.2.2" in netdev
    assert "dns=192.168.2.3" in netdev


def test_vm_guest_avoids_builtin_and_virtual_package_names():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    assert "kmod-8021q" not in source
    assert "wpa-supplicant-mesh" not in source
    for package in (
        "diffutils",
        "ip-full",
        "kmod-veth",
        "kmod-nft-bridge",
        "tcpdump",
        "bind-dig",
        "kmod-mac80211-hwsim",
        "iw-full",
        "wifi-scripts",
        "wpad-mesh-mbedtls",
        "wireguard-tools",
    ):
        assert package in source
    assert source.index("rmmod mac80211_hwsim") < source.index(
        "insmod mac80211_hwsim radios=6"
    )
    assert "modprobe mac80211_hwsim radios=6" not in source
    assert source.index("apk add diffutils") < source.index("/etc/init.d/wpad restart")
    assert source.index("wifi-scripts") < source.index("/etc/init.d/network restart")
    assert 'mv "$wpad_capabilities" "$wpad_capabilities_saved"' in source
    assert "ubus -S list hostapd" in source
    assert "ubus -S list wpa_supplicant" in source
    assert source.index("/etc/init.d/wpad restart") < source.index("rmmod mac80211_hwsim")
    assert source.index("insmod mac80211_hwsim radios=6") < source.index(
        "/etc/init.d/network restart"
    )
    assert source.index('uci set "wireless.radio1.phy=$ap_2g_phy"') < source.index(
        "/etc/init.d/network restart"
    )


def test_vm_guest_repeats_failure_reason_after_verbose_diagnostics():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    fail_body = source[source.index("fail() {") : source.index("\n}", source.index("fail() {"))]
    assert fail_body.count("printf 'vm-test: %s\\n'") == 2
    assert fail_body.rindex("printf 'vm-test: %s\\n'") > fail_body.index("logread")
    assert "tail -n 200 /tmp/setup.log" in fail_body
    # Compact setup/failure diagnostics come after noisy logread so CI tails still
    # show the setup failure reason when logread dominates the serial buffer.
    assert fail_body.index("--- transaction lock ---") < fail_body.index("logread")
    assert fail_body.index("logread") < fail_body.index("tail -n 200 /tmp/setup.log")
    assert fail_body.index("tail -n 200 /tmp/setup.log") < fail_body.rindex(
        "printf 'vm-test: %s\\n'"
    )
    assert "(empty or missing)" in fail_body


def test_vm_guest_captures_setup_log_on_early_exit():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    helper_start = source.index("run_and_confirm() {")
    helper = source[helper_start : source.index("\n}", helper_start)]
    assert "fail 'setup exited before pending state'" in helper
    assert "setup pid exited with status:" in helper
    assert helper.index("setup pid exited with status:") < helper.index(
        "fail 'setup exited before pending state'"
    )
    assert ">/tmp/vm-test-failure-detail" in helper
    assert "(empty or missing)" in helper

def test_vm_guest_reports_redacted_idempotence_diff_after_verbose_diagnostics():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    fail_body = source[source.index("fail() {") : source.index("\n}", source.index("fail() {"))]
    assert "cat /tmp/vm-test-failure-detail" in fail_body
    assert fail_body.index("cat /tmp/vm-test-failure-detail") > fail_body.index("logread")

    export_start = source.index("export_normalized_uci() {")
    export_body = source[export_start : source.index("\n}", export_start)]
    assert 'uci show "$package"' in export_body
    for secret_option in ("private_key", "preshared_key", "wireless\\.[^.]*\\.key"):
        assert secret_option in export_body
    assert "adblock-fast\\.[^.]*\\.size" in export_body
    assert "occurrence[key]++" in export_body
    assert "sort" in export_body

    assert "diff -u /tmp/first.export /tmp/second.export" in source
    assert (
        "diff -u /tmp/first.export /tmp/second.export "
        ">/tmp/vm-test-failure-detail 2>&1"
    ) in source


def test_vm_guest_waits_for_apply_to_release_lock_before_confirming():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    helper_start = source.index("run_and_confirm() {")
    helper = source[helper_start : source.index("\n}", helper_start)]
    pending = helper.index("setup did not create a pending transaction")
    unlocked = helper.index("[ ! -d /var/lock/router-config.lock ]")
    applied = helper.index("candidate applied; confirm")
    confirm = helper.index('/usr/libexec/router-config confirm "$transaction"')
    assert pending < unlocked < confirm
    assert pending < applied < confirm
    assert "900" in helper


def test_vm_guest_checks_doh_listeners_across_rollback_phases():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    assert "check_doh_listeners 'before rollback'" in source
    assert "check_doh_listeners 'after manual rollback'" in source
    assert "check_doh_listeners 'after early-boot recovery'" in source
    helper_start = source.index("check_doh_listeners() {")
    helper = source[helper_start : source.index("\n}", helper_start)]
    assert "ss -lntu" in helper
    assert "/proc/net/tcp /proc/net/udp" in helper


def test_vm_guest_moves_wifi_phys_before_creating_namespaced_clients():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    helper_start = source.index("wifi_client() {")
    helper = source[helper_start : source.index("\n}", helper_start)]
    move_phy = 'iw phy "$client_phy" set netns name "$client_ns"'
    create_interface = (
        'iw phy "$client_phy" interface add "$client_if" type managed'
    )
    assert move_phy in helper
    assert create_interface in helper
    assert helper.index(move_phy) < helper.index(create_interface)
    assert 'ip link set "$client_if" netns "$client_ns"' not in helper


def test_vm_guest_sets_regulatory_country_and_reports_wifi_failures():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    assert "set wireless.radio0.country='US'" in source
    assert "set wireless.radio1.country='US'" in source
    assert "export CHANNEL='36'" in source
    helper_start = source.index("wifi_client() {")
    helper = source[helper_start : source.index('\nwifi_client "$pixel_client_phy"', helper_start)]
    assert "iw reg get" in helper
    assert 'ip netns exec "$client_ns" iw dev "$client_if" link' in helper
    assert "logread -e hostapd -e wpa_supplicant" in helper


def test_vm_guest_checks_ap_readiness_across_apply_and_rollback_phases():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    assert "check_ap_interfaces 'after first installation'" in source
    assert "check_ap_interfaces 'after second installation'" in source
    assert "check_ap_interfaces 'after manual rollback'" in source
    assert "check_ap_interfaces 'after early-boot recovery'" in source
    helper_start = source.index("check_ap_interfaces() {")
    helper_end = source.index("\napk_boot_attempt=0", helper_start)
    helper = source[helper_start:helper_end]
    assert 'awk \'$1 == "type" && $2 == "AP"' in helper
    assert "uci show wireless | sed '/\\.key=/d'" in helper
    assert "ubus -v list hostapd" in helper
    assert "ubus call network.wireless status" in helper
    assert "ls -1 /sys/class/ieee80211" in helper
    assert "-printf" not in helper


def test_vm_guest_waits_for_apk_on_non_overlapping_wan():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    network_restart = source.index(
        "/etc/init.d/network restart || fail "
        "'failed to restart netifd after installing wifi-scripts'"
    )
    lan_ready = source.index('ifstatus lan | grep -q \'"up": true\'', network_restart)
    wan_ready = source.index('ifstatus wan | grep -q \'"up": true\'', lan_ready)
    firewall_restart = source.index(
        "/etc/init.d/firewall restart || fail 'failed to apply seeded firewall'",
        wan_ready,
    )
    ping_probe = source.index("ping -c 1 -W 2 192.168.2.1", firewall_restart)
    wget_probe = source.index(
        "uclient-fetch -T 10 -O /dev/null https://downloads.openwrt.org/", ping_probe
    )
    apk_retries = source.index('while [ "$apk_attempt" -lt 5 ]; do', wget_probe)
    apk_gate = source.index("apk update >/tmp/vm-test-apk-update", apk_retries)
    setup_start = source.index("run_and_confirm() {", apk_gate)
    assert (
        network_restart
        < lan_ready
        < wan_ready
        < firewall_restart
        < ping_probe
        < wget_probe
        < apk_retries
        < apk_gate
        < setup_start
    )
    assert "ifdown lan" not in source
    assert "ip -4 address flush dev br-lan" not in source
    assert "failed to unnumber overlapping stock LAN" not in source
    assert "fail 'apk update failed after WAN recovery'" in source
    assert "failed to install VM guest packages" in source


def test_vm_guest_keeps_production_wan_for_second_setup_and_live_doh():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    first_setup = source.index("run_and_confirm first")
    wan_static = source.index(
        '[ "$(uci -q get network.wan.ipaddr)" = 192.168.2.2 ]', first_setup
    )
    second_setup = source.index("run_and_confirm second", wan_static)
    live = source.index('if [ "$profile" = live ]; then', second_setup)
    rollback = source.index("check_doh_listeners 'before rollback'", live)
    assert first_setup < wan_static < second_setup < live < rollback
    assert "restore_qemu_wan_dhcp" not in source
    assert "10.0.2." not in source


def test_vm_guest_command_timeout_covers_two_setup_passes():
    source = (REPO / "tools/run-vm-tests.py").read_text()
    assert 'guest-tests.sh {args.profile}", 2400)' in source


def test_vm_guest_synchronizes_static_wan_before_dot_probe():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    network_restart = source.index(
        "/etc/init.d/network restart || fail 'failed to restart network for static VM WAN'"
    )
    wan_ready = source.index('grep -q \'"l3_device": "vmwan"\'', network_restart)
    probe_retry = source.index('while [ "$wan_probe_attempt" -lt 30 ]; do', wan_ready)
    connectivity_probe = source.index(
        'ip netns exec "$namespace" ping -c 1 -W 2 198.18.0.2', probe_retry
    )
    firewall_reload = source.index(
        "/etc/init.d/firewall reload || fail "
        "'firewall reload failed after static VM WAN activation'",
        connectivity_probe,
    )
    dot_probe = source.index(
        "ip netns exec guest dig +tcp +time=1 +tries=1", firewall_reload
    )
    doq_probe = source.index(
        "ip netns exec guest dig +time=1 +tries=1 \\\n"
        "    @198.18.0.2 -p 8853",
        dot_probe,
    )
    assert (
        network_restart
        < wan_ready
        < probe_retry
        < connectivity_probe
        < firewall_reload
        < dot_probe
        < doq_probe
    )
    assert "ip netns exec guest busybox nc" not in source
    assert "uci -q delete network.wan.gateway" in source
    assert "guest_dot_counter() {" in source
    assert "guest_doq_counter() {" in source
    assert "nft list chain inet fw4 forward_pixelguest" in source
    assert "Guest TCP/853 reject packets before:" in source
    assert "Guest TCP/853 reject packets after:" in source
    assert "--- DoT probe output ---" in source
    assert "Guest UDP/8853 reject packets before:" in source
    assert "Guest UDP/8853 reject packets after:" in source
    assert "--- DoQ probe output ---" in source
    assert '@198.18.0.2 -p 8853' in source
    assert "missing DoQ rejection for $net" in source


def test_vm_guest_blocks_restricted_clients_from_isp_transit_before_wan_swap():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    client_setup = source.index("lease things things0")
    pixel_probe = source.index(
        "ip netns exec pixel1 ping -c 1 -W 2 192.168.2.1", client_setup
    )
    restricted_probe = source.index(
        'ip netns exec "$client" ping -c 1 -W 2 192.168.2.1', pixel_probe
    )
    counter_check = source.index(
        "ISP transit rejection counter did not increase", restricted_probe
    )
    wan_swap = source.index("ip link add vmwan type veth", counter_check)
    assert client_setup < pixel_probe < restricted_probe < counter_check < wan_swap
    assert "isp_transit_counter() {" in source
    assert 'nft list chain inet fw4 "forward_$1"' in source
    assert "Reject-ISP-Transit-$2" in source
    assert "for client in guest things iot; do" in source


def test_vm_guest_live_doh_waits_for_egress_and_retries_dig():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    live_start = source.index('if [ "$profile" = live ]; then')
    live = source[live_start : source.index("\nfi\n", live_start)]
    assert "check_doh_listeners 'before live DoH'" in live
    assert "live DoH egress probe attempt" in live
    assert "ping -c 1 -W 2 192.168.2.1" in live
    assert "uclient-fetch -T 10 -O /dev/null https://downloads.openwrt.org/" in live
    assert "/etc/init.d/firewall reload" in live
    assert "fail 'live DoH egress was not ready'" in live
    assert "/etc/init.d/https-dns-proxy restart" in live
    assert "check_doh_listeners 'after live DoH restart'" in live
    assert 'while [ "$doh_attempt" -lt 8 ]; do' in live
    assert "dig +time=5 +tries=1 @127.0.0.1 -p \"$port\" example.com A" in live
    assert "--- dig output ---" in live
    assert 'fail "live DoH query failed on $port"' in live
    assert 'dig +time=10 +tries=1 @127.0.0.1 -p "$port" openwrt.org A' not in live


def test_vm_guest_live_blocklist_check_avoids_full_redownload():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    live_start = source.index('if [ "$profile" = live ]; then')
    live = source[live_start : source.index("\nfi\n", live_start)]
    assert "/var/run/adblock-fast/dnsmasq.servers" in live
    assert "adblock-fast dnsmasq.servers missing after live setup" in live
    assert "adblock-fast dnsmasq.servers too small:" in live
    assert "uclient-fetch \"$url\" -O /dev/null" not in live
    assert "blocklist unavailable:" not in live
    assert "/tmp/vm-test-blocklist-urls" in live


def test_vm_guest_uses_diagnostics_for_pre_confirmation_failures():
    source = (REPO / "tools/vm/guest-tests.sh").read_text()
    helper_start = source.index("run_and_confirm() {")
    helper = source[helper_start : source.index("\n}", helper_start)]
    assert "fail 'pending transaction disappeared before confirmation'" in helper
    assert "fail 'setup exited before confirmation'" in helper
    assert (
        '/usr/libexec/router-config confirm "$transaction" || '
        "fail 'transaction confirmation failed'"
    ) in helper
    assert "--- transaction state ---" in source
    assert "--- transaction lock ---" in source
    assert "ls -la /var/lock/router-config.lock" in source
    assert "pid file: missing" in source


def test_imagebuilder_gate_matches_every_installer_package():
    imagebuilder = load_script("check_imagebuilder", "tools/check-imagebuilder.py")
    assert imagebuilder.EXPECTED == "8207da9d689f02d42833e4e8abc9eabb4ec63a433a7a26473296d3d2c489e257"
    shell_source = "\n".join(
        path.read_text() for path in [REPO / "setup.sh", *(REPO / "modules").glob("*.sh")]
    )
    for package in imagebuilder.PACKAGES.split():
        assert package in shell_source


def test_ci_uses_vm_and_native_imagebuilder_without_container_engines():
    workflow = (REPO / ".github/workflows/test.yml").read_text()
    assert "workflow_dispatch:" in workflow
    assert "push:" not in workflow
    assert "pull_request:" not in workflow
    assert "schedule:" not in workflow
    assert "run-vm-tests.py --profile stable" in workflow
    assert "run-vm-tests.py --profile live" in workflow
    assert "check-imagebuilder.py" in workflow
    assert "pip install -r requirements-dev.txt" in workflow
    assert (REPO / "requirements-dev.txt").read_text().strip().startswith("pytest==")
    assert "docker" not in workflow.lower()
    assert "podman" not in workflow.lower()


def test_vm_console_prompt_does_not_assume_a_hostname():
    source = (REPO / "tools/run-vm-tests.py").read_text()
    assert 'console.wait_for("root@", 30)' in source
    assert 'console.wait_for("root@OpenWrt:/#"' not in source


def test_vm_serial_lines_use_carriage_return():
    vm = load_script("run_vm_serial", "tools/run-vm-tests.py")

    class Process:
        stdin = io.BytesIO()

    console = object.__new__(vm.SerialConsole)
    console.process = Process()
    console.send_line("echo ready")
    assert console.process.stdin.getvalue() == b"        echo ready\r"


def test_vm_console_activation_survives_a_dropped_first_byte():
    vm = load_script("run_vm_activation", "tools/run-vm-tests.py")

    class Process:
        stdin = io.BytesIO()

    console = object.__new__(vm.SerialConsole)
    console.process = Process()
    console.send_line()
    assert console.process.stdin.getvalue() == b"\r\r"


def test_vm_command_marker_cannot_match_terminal_echo(monkeypatch):
    vm = load_script("run_vm_command", "tools/run-vm-tests.py")

    class Process:
        stdin = io.BytesIO()

    console = object.__new__(vm.SerialConsole)
    console.process = Process()
    console.buffer = ""
    monkeypatch.setattr(vm.time, "monotonic_ns", lambda: 123)

    def complete_after_split_output(pattern, _timeout):
        sent = console.process.stdin.getvalue().decode()
        assert pattern.pattern == r"__VM_DONE_123__\d+\r?\n"
        assert "__VM_DONE_123__" not in sent
        console.buffer += "command output\r\n__VM_DONE_123__"
        assert not pattern.search(console.buffer)
        console.buffer += "0\r\n"
        assert pattern.search(console.buffer)
        return console.buffer

    console.wait_for_regex = complete_after_split_output
    assert console.command("exit 0") == "command output\r\n"
    sent = console.process.stdin.getvalue()
    assert sent.startswith(b"        ( exit 0 ); vm_status=$?;")


def test_vm_passively_waits_for_boot_network_before_sending_commands():
    source = (REPO / "tools/run-vm-tests.py").read_text()
    ready = source.index(
        'console.wait_for("br-lan: port 1(eth0) entered forwarding state", 60)'
    )
    verify = source.index("ifstatus lan | grep")
    remove_lan = source.index("uci -q delete network.lan")
    stock_wan = source.index("uci -q set network.wan=interface")
    assert ready < verify < remove_lan < stock_wan
    assert "network.uplink" not in source


def test_vm_verifies_stock_runtime_before_reconfiguring_disk_root():
    source = (REPO / "tools/run-vm-tests.py").read_text()
    disk_boot = source.index(
        'kernel = downloads["openwrt-25.12.4-armsr-armv8-generic-kernel.bin"]'
    )
    runtime_check = source.index("verify_stock_runtime(console)", disk_boot)
    uplink_change = source.index("configure_uplink(console)", runtime_check)
    assert disk_boot < runtime_check < uplink_change
