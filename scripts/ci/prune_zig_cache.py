#!/usr/bin/env python3
"""Keep a useful, bounded Zig cache instead of uploading an oversized archive."""

import argparse
import os
import shutil
from pathlib import Path


def size(path: Path) -> int:
    if path.is_symlink() or not path.is_dir():
        return path.lstat().st_size
    total = 0
    for directory, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            child = Path(directory) / name
            if child.is_symlink() or not child.is_dir():
                total += child.lstat().st_size
    return total


def remove(path: Path) -> None:
    if path.is_symlink() or not path.is_dir():
        path.unlink()
    else:
        shutil.rmtree(path)


def prune(roots: list[Path], maximum: int) -> tuple[int, int, int]:
    if maximum < 0:
        raise ValueError("cache limit must be nonnegative")
    # Never traverse a cache root redirected outside the job checkout.
    for root in roots:
        if root.is_symlink() or (root.exists() and not root.is_dir()):
            raise ValueError(f"cache root is not a directory: {root}")
    for root in roots:
        scratch = root / "tmp"
        if scratch.exists() or scratch.is_symlink():
            remove(scratch)

    before = sum(size(root) for root in roots if root.exists())
    total = before
    candidates = []
    for root in roots:
        if not root.exists():
            continue
        for child in root.iterdir():
            if child.name == "o" and child.is_dir() and not child.is_symlink():
                # Evict whole compiler outputs, oldest first. Retain newer
                # outputs and package downloads instead of clearing the cache.
                candidates.extend((0, p.lstat().st_mtime_ns, p) for p in child.iterdir())
            else:
                # Metadata is reconstructible too; downloaded packages are
                # evicted last if they alone exceed the archive budget.
                candidates.append((2 if child.name == "p" else 1, child.lstat().st_mtime_ns, child))
    removed = 0
    invalidated = False
    for priority, _, path in sorted(candidates):
        if total <= maximum:
            break
        # An earlier output eviction may already have removed this manifest.
        if not path.exists() and not path.is_symlink():
            continue
        amount = size(path)
        remove(path)
        total -= amount
        removed += 1
        if not invalidated and (priority == 0 or any(path == root / "o" for root in roots)):
            # Zig 0.16 can trust a manifest for a static library whose output
            # was evicted, then fail linking with "lib*.a: file not found".
            # Both caches can refer to the removed output. Invalidate their
            # manifests once, retaining all remaining outputs and downloads.
            for root in roots:
                manifests = root / "h"
                if manifests.exists() or manifests.is_symlink():
                    total -= size(manifests)
                    remove(manifests)
                    removed += 1
            invalidated = True
    after = sum(size(root) for root in roots if root.exists())
    if after > maximum:
        raise RuntimeError(f"cache remains above limit: {after} > {maximum}")
    return before, after, removed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-bytes", type=int, default=2 * 1024**3)
    args = parser.parse_args()
    before, after, removed = prune([Path(".zig-cache"), Path("zig-cache")], args.max_bytes)
    print(f"Zig cache: {before} -> {after} bytes; limit={args.max_bytes}; evicted={removed}")


if __name__ == "__main__":
    main()
