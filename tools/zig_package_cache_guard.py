#!/usr/bin/env python3
"""Validate and optionally prune stale Zig package cache entries.

The cache under docker/zig-packages should only contain directories reachable from
root build.zig.zon dependency hashes (including transitive hashes discovered in
cached dependency build.zig.zon files).
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import shutil
import sys
from dataclasses import dataclass

HASH_RE = re.compile(r"\.hash\s*=\s*\"([^\"]+)\"")


@dataclass
class AnalysisResult:
    root_hashes: list[str]
    reachable_hashes: set[str]
    missing_hashes: set[str]
    cache_dirs: set[str]
    stale_dirs: list[str]


def extract_hashes(path: pathlib.Path) -> list[str]:
    if not path.exists() or not path.is_file():
        return []
    content = path.read_text(encoding="utf-8", errors="ignore")
    return HASH_RE.findall(content)


def analyze(root_zon: pathlib.Path, cache_dir: pathlib.Path) -> AnalysisResult:
    root_hashes = extract_hashes(root_zon)

    queue: collections.deque[str] = collections.deque(root_hashes)
    reachable: set[str] = set(root_hashes)
    missing: set[str] = set()

    while queue:
        pkg_hash = queue.popleft()
        pkg_dir = cache_dir / pkg_hash
        if not pkg_dir.is_dir():
            missing.add(pkg_hash)
            continue

        dep_hashes = extract_hashes(pkg_dir / "build.zig.zon")
        for dep_hash in dep_hashes:
            if dep_hash not in reachable:
                reachable.add(dep_hash)
                queue.append(dep_hash)

    cache_dirs = {p.name for p in cache_dir.iterdir() if p.is_dir()}
    stale_dirs = sorted(cache_dirs - reachable)

    return AnalysisResult(
        root_hashes=root_hashes,
        reachable_hashes=reachable,
        missing_hashes=missing,
        cache_dirs=cache_dirs,
        stale_dirs=stale_dirs,
    )


def print_report(result: AnalysisResult) -> None:
    print("Zig package cache analysis")
    print(f"- Root hashes: {len(result.root_hashes)}")
    print(f"- Reachable hashes (transitive): {len(result.reachable_hashes)}")
    print(f"- Cache directories present: {len(result.cache_dirs)}")
    print(f"- Missing referenced hashes: {len(result.missing_hashes)}")
    print(f"- Stale cache directories: {len(result.stale_dirs)}")

    if result.missing_hashes:
        print("\nMissing referenced hashes (informational):")
        for pkg_hash in sorted(result.missing_hashes):
            print(f"  - {pkg_hash}")

    if result.stale_dirs:
        print("\nStale directories (safe to prune):")
        for entry in result.stale_dirs:
            print(f"  - {entry}")


def prune(cache_dir: pathlib.Path, stale_dirs: list[str]) -> None:
    for entry in stale_dirs:
        target = cache_dir / entry
        if target.is_dir():
            shutil.rmtree(target)
            print(f"pruned: {target}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root-zon",
        default="build.zig.zon",
        help="Path to root build.zig.zon",
    )
    parser.add_argument(
        "--cache-dir",
        default="docker/zig-packages",
        help="Path to Zig package cache directory",
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help="Delete stale cache directories",
    )
    parser.add_argument(
        "--strict-stale",
        action="store_true",
        help="Exit non-zero when stale directories are found",
    )
    parser.add_argument(
        "--strict-missing",
        action="store_true",
        help="Exit non-zero when referenced hashes are missing from cache",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    root_zon = pathlib.Path(args.root_zon)
    cache_dir = pathlib.Path(args.cache_dir)

    if not root_zon.exists():
        print(f"error: root zon not found: {root_zon}", file=sys.stderr)
        return 2

    if not cache_dir.exists() or not cache_dir.is_dir():
        print(f"error: cache dir not found: {cache_dir}", file=sys.stderr)
        return 2

    result = analyze(root_zon, cache_dir)
    print_report(result)

    if args.prune and result.stale_dirs:
        print("\nPruning stale directories...")
        prune(cache_dir, result.stale_dirs)

        # Recompute and reprint concise post-prune summary.
        post = analyze(root_zon, cache_dir)
        print("\nPost-prune summary:")
        print(f"- Cache directories present: {len(post.cache_dirs)}")
        print(f"- Stale cache directories: {len(post.stale_dirs)}")

    exit_code = 0
    if args.strict_stale and result.stale_dirs:
        exit_code = 1
    if args.strict_missing and result.missing_hashes:
        exit_code = 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
