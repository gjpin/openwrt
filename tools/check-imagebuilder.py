#!/usr/bin/env python3
"""Build and discard the exact GL-MT6000 OpenWrt package set."""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CACHE = REPO / ".cache" / "openwrt-vm"
NAME = "openwrt-imagebuilder-25.12.4-mediatek-filogic.Linux-x86_64.tar.zst"
URL = f"https://downloads.openwrt.org/releases/25.12.4/targets/mediatek/filogic/{NAME}"
EXPECTED = "8207da9d689f02d42833e4e8abc9eabb4ec63a433a7a26473296d3d2c489e257"
PACKAGES = (
    "gawk grep sed coreutils-sort nano "
    "https-dns-proxy luci-app-https-dns-proxy "
    "adblock-fast luci-app-adblock-fast wireguard-tools luci-proto-wireguard"
)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def artifact() -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / NAME
    if target.exists() and digest(target) != EXPECTED:
        target.unlink()
    if not target.exists():
        partial = target.with_suffix(".part")
        partial.unlink(missing_ok=True)
        with urllib.request.urlopen(URL, timeout=60) as source, partial.open("wb") as output:
            shutil.copyfileobj(source, output)
        if digest(partial) != EXPECTED:
            partial.unlink(missing_ok=True)
            raise RuntimeError("ImageBuilder SHA-256 mismatch")
        partial.replace(target)
    if digest(target) != EXPECTED:
        raise RuntimeError("cached ImageBuilder SHA-256 mismatch")
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-workdir", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("the official native ImageBuilder requires Linux x86_64")
    workdir = Path(tempfile.mkdtemp(prefix="gl-mt6000-imagebuilder-"))
    try:
        source = artifact()
        subprocess.run(["tar", "--zstd", "-xf", str(source), "-C", str(workdir)], check=True)
        builder = next(path for path in workdir.iterdir() if path.is_dir())
        env = {**os.environ, "LC_ALL": "C"}
        subprocess.run(
            ["make", "image", "PROFILE=glinet_gl-mt6000", f"PACKAGES={PACKAGES}"],
            cwd=builder, env=env, check=True,
        )
        output = builder / "bin" / "targets" / "mediatek" / "filogic"
        factory = list(output.glob("*glinet_gl-mt6000*squashfs-factory.bin"))
        sysupgrade = list(output.glob("*glinet_gl-mt6000*squashfs-sysupgrade.bin"))
        manifests = list(output.glob("*glinet_gl-mt6000*.manifest"))
        if len(factory) != 1 or len(sysupgrade) != 1 or not manifests:
            raise RuntimeError("ImageBuilder did not produce both images and a manifest")
        manifest_text = "\n".join(path.read_text() for path in manifests)
        for package in PACKAGES.split():
            if not any(line.split(" - ", 1)[0] == package for line in manifest_text.splitlines()):
                raise RuntimeError(f"generated manifest lacks {package}")
        if not factory[0].stat().st_size or not sysupgrade[0].stat().st_size:
            raise RuntimeError("ImageBuilder produced an empty firmware image")
        print("GL-MT6000 factory/sysupgrade images and package manifest verified; outputs discarded")
        return 0
    finally:
        if args.keep_workdir:
            print(f"kept work directory: {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
