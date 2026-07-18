#!/usr/bin/env python3
"""Run the pytest suite in balanced, isolated worker processes."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


def collect_tests() -> list[str]:
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "--collect-only",
            "-q",
            "-p",
            "no:cacheprovider",
        ],
        check=False,
        text=True,
        capture_output=True,
        cwd=REPO,
    )
    if result.returncode != 0:
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)

    return [
        line
        for line in result.stdout.splitlines()
        if line.startswith("tests/") and "::" in line
    ]


def run_group(node_ids: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-q",
            "-p",
            "no:cacheprovider",
            *node_ids,
        ],
        check=False,
        text=True,
        capture_output=True,
        cwd=REPO,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-j",
        "--workers",
        type=int,
        default=min(4, os.cpu_count() or 1),
        help="number of concurrent pytest workers (default: up to 4)",
    )
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("workers must be at least 1")

    node_ids = collect_tests()
    if not node_ids:
        print("no tests collected", file=sys.stderr)
        return 5

    worker_count = min(args.workers, len(node_ids))
    groups = [[] for _ in range(worker_count)]
    for index, node_id in enumerate(node_ids):
        groups[index % worker_count].append(node_id)

    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        results = list(executor.map(run_group, groups))
    elapsed = time.perf_counter() - started

    for index, result in enumerate(results, start=1):
        print(f"\n--- worker {index} ---")
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)

    failed = sum(result.returncode != 0 for result in results)
    print(
        f"\n{len(node_ids)} tests across {worker_count} workers "
        f"in {elapsed:.2f}s; {failed} workers failed"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
