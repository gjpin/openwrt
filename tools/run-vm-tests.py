#!/usr/bin/env python3
"""Boot the pinned OpenWrt AArch64 release and run the router acceptance suite."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import http.server
import os
import platform
import re
import selectors
import shutil
import socketserver
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request
from functools import partial
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CACHE = REPO / ".cache" / "openwrt-vm"
RELEASE = "25.12.4"
QEMU_ISP_NETWORK = "192.168.1.0/24"
QEMU_ISP_GATEWAY = "192.168.1.1"
QEMU_WAN_ADDRESS = "192.168.1.2"
QEMU_ISP_DNS = "192.168.1.3"
BASE_URL = f"https://downloads.openwrt.org/releases/{RELEASE}/targets/armsr/armv8"
ARTIFACTS = {
    "openwrt-25.12.4-armsr-armv8-generic-kernel.bin":
        "f56d204390dd5edfd3a1b67162bc9b5fa34b80f623a3fbbdf49e10ec3bc7a3cd",
    "openwrt-25.12.4-armsr-armv8-generic-initramfs-kernel.bin":
        "1e978e72215190a554decb45fdaed2d8d076cc74c4d32e0c72b77d533282146b",
    "openwrt-25.12.4-armsr-armv8-generic-ext4-rootfs.img.gz":
        "40ce3ea1b872a4a07b9009b7e8ff949b14ee5680f75655322b9554f3bcb1d6bb",
}
SECRET_RE = re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_verified(name: str, expected: str) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    destination = CACHE / name
    if destination.exists() and sha256(destination) != expected:
        destination.unlink()
    if not destination.exists():
        partial_path = destination.with_suffix(destination.suffix + ".part")
        partial_path.unlink(missing_ok=True)
        print(f"downloading {name}")
        with urllib.request.urlopen(f"{BASE_URL}/{name}", timeout=60) as source:
            with partial_path.open("wb") as output:
                shutil.copyfileobj(source, output)
        if sha256(partial_path) != expected:
            partial_path.unlink(missing_ok=True)
            raise RuntimeError(f"SHA-256 mismatch for {name}")
        partial_path.replace(destination)
    # Cache contents are untrusted between runs; verify on every invocation.
    if sha256(destination) != expected:
        raise RuntimeError(f"cached SHA-256 mismatch for {name}")
    return destination


def make_repository_archive(destination: Path) -> str:
    excluded = {".git", ".cache", ".pytest_cache", "__pycache__"}
    with tarfile.open(destination, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(REPO.rglob("*")):
            relative = path.relative_to(REPO)
            if any(part in excluded or part.startswith(".router-test-") for part in relative.parts):
                continue
            archive.add(path, arcname=Path("openwrt") / relative, recursive=False)
    return sha256(destination)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args: object) -> None:
        return


class ReusableServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


class SerialConsole:
    def __init__(self, process: subprocess.Popen[bytes], log_path: Path):
        self.process = process
        self.log_path = log_path
        self.buffer = ""
        self.selector = selectors.DefaultSelector()
        assert process.stdout is not None
        self.selector.register(process.stdout, selectors.EVENT_READ)

    def send(self, value: str) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(value.encode())
        self.process.stdin.flush()

    def send_line(self, value: str = "") -> None:
        # stdin is a raw pipe, not a PTY. A UART terminal's Enter key sends CR;
        # LF alone activates askfirst but is not reliably accepted by ash. Pace
        # long lines as well: writing a whole command while boot messages are
        # active can overrun the emulated PL011 receive FIFO.
        # Some QEMU chardev/PL011 combinations can discard the first byte sent
        # after the guest becomes idle. Leading shell whitespace is harmless
        # when received and protects the actual command when it is discarded.
        # Console activation is the one case where leading whitespace cannot
        # protect the payload: askfirst is waiting specifically for Enter.
        # Send it twice so a discarded first UART byte cannot strand the boot
        # at "Please press Enter to activate this console."
        line = (" " * 8 + value + "\r") if value else "\r\r"
        for offset, character in enumerate(line):
            self.send(character)
            if offset + 1 < len(line):
                time.sleep(0.001)

    def wait_for(self, pattern: str, timeout: float) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if pattern in self.buffer:
                return self.buffer
            if self.process.poll() is not None:
                raise RuntimeError(f"QEMU exited with status {self.process.returncode}")
            for key, _ in self.selector.select(timeout=0.5):
                chunk = os.read(key.fd, 65536).decode(errors="replace")
                if not chunk:
                    continue
                self.buffer = (self.buffer + chunk)[-2_000_000:]
                redacted = SECRET_RE.sub("<redacted-key>", chunk)
                with self.log_path.open("a", encoding="utf-8") as log:
                    log.write(redacted)
        raise TimeoutError(f"timed out waiting for serial marker: {pattern!r}")

    def wait_for_regex(self, pattern: re.Pattern[str], timeout: float) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if pattern.search(self.buffer):
                return self.buffer
            if self.process.poll() is not None:
                raise RuntimeError(f"QEMU exited with status {self.process.returncode}")
            for key, _ in self.selector.select(timeout=0.5):
                chunk = os.read(key.fd, 65536).decode(errors="replace")
                if not chunk:
                    continue
                self.buffer = (self.buffer + chunk)[-2_000_000:]
                redacted = SECRET_RE.sub("<redacted-key>", chunk)
                with self.log_path.open("a", encoding="utf-8") as log:
                    log.write(redacted)
        raise TimeoutError(f"timed out waiting for serial pattern: {pattern.pattern!r}")

    def command(self, command: str, timeout: float = 120) -> str:
        marker_suffix = f"DONE_{time.monotonic_ns()}__"
        marker = f"__VM_{marker_suffix}"
        start = len(self.buffer)
        # Run in a subshell so commands such as `exit 0` cannot close the
        # interactive console.  Split the marker across two printf arguments
        # so its literal value is absent from the UART echo and the completion
        # pattern can only match the marker emitted after the command finishes.
        self.send_line(
            f"( {command} ); vm_status=$?; "
            f"printf '%s%s%d\\n' '__VM_' '{marker_suffix}' \"$vm_status\""
        )
        completion = re.compile(re.escape(marker) + r"\d+\r?\n")
        try:
            self.wait_for_regex(completion, timeout)
        except TimeoutError as error:
            raise TimeoutError(f"guest command timed out after {timeout}s: {command}") from error
        tail = self.buffer[start:]
        match = re.search(re.escape(marker) + r"(\d+)", tail)
        if not match or match.group(1) != "0":
            raise RuntimeError(f"guest command failed: {command}\n{SECRET_RE.sub('<redacted-key>', tail[-16000:])}")
        return tail[: match.start()]


def accelerator_args() -> list[str]:
    machine = platform.machine().lower()
    if platform.system() == "Darwin" and machine in {"arm64", "aarch64"}:
        return ["-accel", "hvf", "-cpu", "host"]
    if platform.system() == "Linux" and machine in {"arm64", "aarch64"} and Path("/dev/kvm").exists():
        return ["-accel", "kvm", "-cpu", "host"]
    return ["-accel", "tcg,thread=multi", "-cpu", "max"]


def require_host_tools() -> str:
    qemu = shutil.which("qemu-system-aarch64")
    if not qemu:
        if platform.system() == "Darwin":
            raise RuntimeError("missing qemu-system-aarch64; run: brew install qemu")
        raise RuntimeError("missing qemu-system-aarch64; install the Fedora qemu-system-aarch64 package")
    return qemu


def qemu_command(qemu: str, kernel: Path, disk: Path, disk_root: bool) -> list[str]:
    kernel_args = "console=ttyAMA0,115200n8"
    if disk_root:
        kernel_args = "root=/dev/vda rootwait " + kernel_args
    uplink = (
        f"user,id=uplink,net={QEMU_ISP_NETWORK},host={QEMU_ISP_GATEWAY},"
        f"dhcpstart={QEMU_WAN_ADDRESS},dns={QEMU_ISP_DNS}"
    )
    return [
        qemu, "-M", "virt", *accelerator_args(), "-m", "1024", "-smp", "2",
        "-nographic", "-kernel", str(kernel),
        "-drive", f"file={disk},format=raw,if=virtio",
        "-append", kernel_args,
        "-netdev", uplink, "-device", "virtio-net-pci,netdev=uplink",
    ]


def wait_for_boot(console: SerialConsole) -> None:
    console.wait_for("Please press Enter to activate this console", 240)
    console.send_line()
    # The generic armsr images have no hostname until board configuration is
    # generated, so a fresh console normally prompts as root@(none):~#.
    console.wait_for("root@", 30)
    # The login prompt appears before rc.d has finished starting netifd, and
    # sending UART input during that phase can overrun the emulated PL011
    # receive FIFO. Passively wait for the single bridge port to come up.
    console.wait_for("br-lan: port 1(eth0) entered forwarding state", 60)
    console.command("ifstatus lan | grep -q '\"up\": true'", 30)


def configure_uplink(console: SerialConsole) -> None:
    # Remove the disposable LAN so eth0 is no longer claimed by br-lan when
    # the stock-shaped WAN is brought up.  Keep the interface named wan: the
    # guest suite later seeds that same section, and a second DHCP interface on
    # eth0 can race package/service reloads and interrupt repository downloads.
    console.command(
        "ifdown lan; uci -q delete network.lan; uci -q set network.wan=interface; "
        "uci set network.wan.device=eth0; uci set network.wan.proto=dhcp; "
        "uci commit network; ifup wan",
        60,
    )
    console.command(
        "for n in 1 2 3 4 5 6 7 8 9 10; do "
        "ip -4 addr show dev eth0 | grep -q 'inet ' && exit 0; sleep 1; done; exit 1",
        30,
    )


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("stable", "live"), default="stable")
    parser.add_argument("--keep-workdir", action="store_true")
    args = parser.parse_args()

    try:
        qemu = require_host_tools()
    except RuntimeError as error:
        print(f"VM suite cannot start: {error}", file=sys.stderr)
        return 1
    downloads = {name: download_verified(name, digest) for name, digest in ARTIFACTS.items()}
    workdir = Path(tempfile.mkdtemp(prefix="openwrt-vm-"))
    process: subprocess.Popen[bytes] | None = None
    server: ReusableServer | None = None
    try:
        disk = workdir / "rootfs.img"
        rootfs = downloads["openwrt-25.12.4-armsr-armv8-generic-ext4-rootfs.img.gz"]
        with gzip.open(rootfs, "rb") as source, disk.open("wb") as output:
            shutil.copyfileobj(source, output)
        with disk.open("r+b") as stream:
            stream.truncate(2 * 1024 * 1024 * 1024)

        archive = workdir / "repository.tar.gz"
        archive_hash = make_repository_archive(archive)
        handler = partial(QuietHandler, directory=str(workdir))
        server = ReusableServer(("0.0.0.0", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]

        # The release ext4 image cannot grow to 2 GiB while mounted because its
        # reserved group-descriptor layout only permits a small online resize.
        # Boot the pinned initramfs entirely from RAM and expand /dev/vda
        # offline before using it as the acceptance VM's root filesystem.
        initramfs = downloads["openwrt-25.12.4-armsr-armv8-generic-initramfs-kernel.bin"]
        process = subprocess.Popen(
            qemu_command(qemu, initramfs, disk, disk_root=False),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        console = SerialConsole(process, workdir / "serial-redacted.log")
        wait_for_boot(console)
        configure_uplink(console)
        console.command(
            "! grep -q '^/dev/vda ' /proc/mounts && "
            "for attempt in 1 2 3; do apk update && break; "
            "[ \"$attempt\" -lt 3 ] || exit 1; sleep 2; done && "
            "apk add resize2fs && resize2fs /dev/vda && sync",
            180,
        )
        stop_process(process)
        process = None

        kernel = downloads["openwrt-25.12.4-armsr-armv8-generic-kernel.bin"]
        process = subprocess.Popen(
            qemu_command(qemu, kernel, disk, disk_root=True),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        console = SerialConsole(process, workdir / "serial-redacted.log")
        wait_for_boot(console)
        configure_uplink(console)
        guest_url = f"http://{QEMU_ISP_GATEWAY}:{port}/repository.tar.gz"
        console.command(f"uclient-fetch '{guest_url}' -O /tmp/repository.tar.gz", 60)
        console.command(f"echo '{archive_hash}  /tmp/repository.tar.gz' | sha256sum -c -", 30)
        console.command("mkdir -p /tmp/source; tar -xzf /tmp/repository.tar.gz -C /tmp/source", 30)
        console.command(f"cd /tmp/source/openwrt && sh tools/vm/guest-tests.sh {args.profile}", 2400)
        print(f"OpenWrt {RELEASE} {args.profile} VM suite passed")
        return 0
    except Exception as error:
        print(f"VM suite failed: {error}", file=sys.stderr)
        print(f"redacted diagnostics: {workdir / 'serial-redacted.log'}", file=sys.stderr)
        log_path = workdir / "serial-redacted.log"
        if log_path.exists():
            print("--- redacted serial tail ---", file=sys.stderr)
            print(log_path.read_text(errors="replace")[-50_000:], file=sys.stderr)
        return 1
    finally:
        if process is not None:
            stop_process(process)
        if server is not None:
            server.shutdown()
            server.server_close()
        if args.keep_workdir:
            print(f"kept work directory: {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
