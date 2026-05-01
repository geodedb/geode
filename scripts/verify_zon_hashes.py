#!/usr/bin/env python3
"""verify_zon_hashes.py — pre-commit hook that re-derives every recorded
hash in build.zig.zon by running `zig fetch <url>` and compares it to
the recorded `.hash` value. Catches the case where someone records a
hash from a parent or sibling commit instead of the actual pinned SHA.

Exit codes:
  0 — every recorded hash matches what zig fetch produces (or there
      are no fetchable deps).
  1 — at least one recorded hash does NOT match the freshly-derived
      one. The script prints `<dep>: declared <H1>, fetched <H2>`
      lines and the developer must fix the manifest.
  2 — network/zig-cache unavailable (zig fetch failed for every dep
      that we tried), so we cannot verify. Caller treats this as
      soft-skip so offline commits aren't blocked.

Why this exists: pipeline #1004 (2026-04-30) failed in
bench-timeseries / bench-query-path / test-gql-compliance because
geode pinned otel@0c34ce9b but the recorded `.hash` was the
content-hash of the PARENT commit (ee492166). Locally the build
worked because zig-pkg/otel-0.1.0-B0v3lr2UMw was already cached
from earlier iter runs. CI did a fresh fetch from 0c34ce9b, got
B0v3lnSv, saw the mismatch, and aborted. This hook would have
caught it before the push.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import List, Tuple

ZON = Path("build.zig.zon")

DEP_BLOCK = re.compile(
    r"\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\.\{[^{}]*?"
    r'\.url\s*=\s*"([^"]+)"'
    r"[^{}]*?"
    r'\.hash\s*=\s*"([^"]+)"'
    r"[^{}]*?\}",
    re.DOTALL,
)


def parse_deps(text: str) -> List[Tuple[str, str, str]]:
    """Return [(dep_name, url, recorded_hash), ...]."""
    return [(m.group(1), m.group(2), m.group(3)) for m in DEP_BLOCK.finditer(text)]


def zig_fetch(url: str, timeout: int = 60) -> Tuple[str, str]:
    """Return (fetched_hash, error_message). Empty hash on failure."""
    try:
        cp = subprocess.run(
            ["zig", "fetch", url],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return "", "zig binary not found in PATH"
    except subprocess.TimeoutExpired:
        return "", f"timeout after {timeout}s"
    if cp.returncode != 0:
        msg = (cp.stderr or cp.stdout or "fetch failed").strip()
        return "", msg.splitlines()[-1] if msg else "fetch failed"
    out = cp.stdout.strip()
    if not out:
        return "", "empty output"
    return out.splitlines()[-1].strip(), ""


def main() -> int:
    if not ZON.exists():
        return 0
    text = ZON.read_text()
    deps = parse_deps(text)
    if not deps:
        return 0

    mismatches: List[Tuple[str, str, str]] = []
    fetch_errors: List[Tuple[str, str]] = []
    verified = 0

    for name, url, recorded in deps:
        if not url.startswith("git+") and "git@" not in url:
            continue
        fetched, err = zig_fetch(url)
        if not fetched:
            fetch_errors.append((name, err))
            continue
        if fetched != recorded:
            mismatches.append((name, recorded, fetched))
        else:
            verified += 1

    if mismatches:
        print("\n✗ build.zig.zon hash MISMATCHES detected:\n", file=sys.stderr)
        for name, recorded, fetched in mismatches:
            print(f"  .{name}:", file=sys.stderr)
            print(f"    declared: {recorded}", file=sys.stderr)
            print(f"    fetched:  {fetched}", file=sys.stderr)
        print(
            "\n  Fix by updating the .hash field in build.zig.zon to the fetched value\n"
            "  (or by changing the .url SHA to one whose content matches the recorded\n"
            "  hash). Pipeline #1004 hit this exact failure on 2026-04-30 with otel.",
            file=sys.stderr,
        )
        return 1

    if not verified and fetch_errors:
        print(
            f"zon-hash-verify: all {len(fetch_errors)} fetches failed (network/zig issue?)",
            file=sys.stderr,
        )
        for name, err in fetch_errors[:3]:
            print(f"  .{name}: {err}", file=sys.stderr)
        return 2

    if fetch_errors:
        print(
            f"zon-hash-verify: {verified}/{verified+len(fetch_errors)} deps verified, "
            f"{len(fetch_errors)} could not be fetched (skipping):",
            file=sys.stderr,
        )
        for name, err in fetch_errors[:5]:
            print(f"  .{name}: {err}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
