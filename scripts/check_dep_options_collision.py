#!/usr/bin/env python3
"""check_dep_options_collision.py — pre-commit guard against Zig
build-options module collisions across the dependency tree.

Why this exists: MR !28 (uuid v0.1.5) failed governance-match-ops-campaign
with `file exists in modules 'build_options23' and 'build_options25'`.
Zig's options cache is content-addressed: when two packages generate
byte-identical options content (uuid v0.1.5 and fts-storage 0.1.3 both
emitted exactly `pub const fips: bool = false;`), both modules dedupe to
ONE cached options.zig file, and a file rooted in two modules is a hard
compile error the moment both packages land in the same compilation.

The ecosystem convention (see timeseries-storage) is to add a
`package_name` option so each package's generated content is unique.

This script statically extracts every `addOption(type, "name", value)`
call per build.zig (repo root plus every package in the transitive pin
closure under zig-pkg/), resolves values where determinable (string/bool
literals, `@import("build.zig.zon").version`, single-hop consts,
`b.option(...) orelse <default>`), and fails when two packages declare
an identical resolved signature set — the precondition for a content
collision. Unresolvable values compare equal (conservative: defaults
usually match across packages).

Known-latent pairs that are not co-reachable today can be suppressed in
scripts/options_collision_allowlist.txt (one `pkgA pkgB` pair per line,
'#' comments allowed) — fix those upstream when convenient.

Exit codes:
  0 — no collision preconditions (or only allowlisted ones).
  1 — new collision precondition detected; offending packages printed.
  2 — soft skip: zig-pkg/ not populated yet (fresh checkout, no build);
      callers treat this as success so offline commits aren't blocked.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ADD_OPTION_RE = re.compile(r"\.addOption\s*\(\s*([^,]+?)\s*,\s*\"([^\"]+)\"\s*,\s*(.+?)\)\s*;")
ZON_HASH_RE = re.compile(r"\.hash\s*=\s*\"([^\"]+)\"")
ZON_VERSION_RE = re.compile(r"\.version\s*=\s*\"([^\"]+)\"")
CONST_RE_TMPL = r"const\s+{ident}\s*=\s*(.+?);"
ORELSE_RE = re.compile(r"orelse\s+(true|false|\"[^\"]*\")\s*$")
PKG_NAME_RE = re.compile(r"^(.*?)-\d")
ALLOWLIST = Path("scripts/options_collision_allowlist.txt")


def resolve_value(expr: str, build_text: str, zon_version: str | None, depth: int = 0) -> str:
    """Best-effort static resolution of an addOption value expression."""
    expr = expr.strip()
    if expr in ("true", "false"):
        return expr
    if expr.startswith('"') and expr.endswith('"'):
        return expr
    if '@import("build.zig.zon").version' in expr:
        return f'"{zon_version}"' if zon_version else "<dynamic>"
    m = ORELSE_RE.search(expr)
    if m:
        return m.group(1)
    if depth < 2 and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", expr):
        m = re.search(CONST_RE_TMPL.format(ident=re.escape(expr)), build_text)
        if m:
            return resolve_value(m.group(1), build_text, zon_version, depth + 1)
    return "<dynamic>"


def signature(build_zig: Path) -> frozenset[tuple[str, str, str]] | None:
    try:
        text = build_zig.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    if "addOptions" not in text:
        return None
    zon = build_zig.parent / "build.zig.zon"
    zon_version = None
    if zon.is_file():
        m = ZON_VERSION_RE.search(zon.read_text(encoding="utf-8", errors="replace"))
        zon_version = m.group(1) if m else None
    pairs = frozenset(
        (t.strip(), name, resolve_value(value, text, zon_version)) for t, name, value in ADD_OPTION_RE.findall(text)
    )
    return pairs or None


def pinned_packages(pkg_dir: Path) -> dict[str, tuple[Path, bool]]:
    """BFS the transitive pin closure: zig-pkg dir names ARE the zon hash
    strings, so start from the repo's build.zig.zon hashes and follow each
    matched package's own build.zig.zon. Stale unpacked versions of a
    package (old pins still sitting in zig-pkg/) are never scanned.
    Returns hash -> (package root, pinned directly by the repo?)."""
    found: dict[str, tuple[Path, bool]] = {}
    queue: list[tuple[Path, bool]] = [(Path("build.zig.zon"), True)]
    seen_zons: set[Path] = set()
    while queue:
        zon, direct = queue.pop()
        if zon in seen_zons or not zon.is_file():
            continue
        seen_zons.add(zon)
        for pkg_hash in ZON_HASH_RE.findall(zon.read_text(encoding="utf-8", errors="replace")):
            pkg_root = pkg_dir / pkg_hash
            if pkg_hash not in found and pkg_root.is_dir():
                found[pkg_hash] = (pkg_root, direct)
                queue.append((pkg_root / "build.zig.zon", False))
    return found


def short_name(label: str) -> str:
    m = PKG_NAME_RE.match(label)
    return m.group(1) if m else label


def load_allowlist() -> set[frozenset[str]]:
    pairs: set[frozenset[str]] = set()
    if not ALLOWLIST.is_file():
        return pairs
    for line in ALLOWLIST.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) == 2:
            pairs.add(frozenset(parts))
    return pairs


def main() -> int:
    roots: dict[str, Path] = {}
    repo_build = Path("build.zig")
    if repo_build.is_file():
        roots["<repo root>"] = repo_build

    pkg_dir = Path("zig-pkg")
    pinned = pinned_packages(pkg_dir) if pkg_dir.is_dir() else {}
    if not pinned:
        print(
            "check-dep-options-collision: zig-pkg/ not populated — "
            "skipping (run `zig build --fetch` to enable; CI enforces via "
            "governance-match-ops-campaign)"
        )
        return 2

    direct: dict[str, bool] = {"<repo root>": True}
    for pkg_hash, (pkg_root, is_direct) in pinned.items():
        build = pkg_root / "build.zig"
        if build.is_file():
            roots[pkg_hash] = build
            direct[pkg_hash] = is_direct

    sigs: dict[frozenset[tuple[str, str, str]], list[str]] = {}
    for label, build in roots.items():
        sig = signature(build)
        if sig is None:
            continue
        sigs.setdefault(sig, []).append(label)

    allow = load_allowlist()
    failures: list[tuple[frozenset[tuple[str, str, str]], list[str]]] = []
    warnings: list[tuple[frozenset[tuple[str, str, str]], list[str]]] = []
    for sig, pkgs in sigs.items():
        if len(pkgs) < 2:
            continue
        names = frozenset(short_name(p) for p in pkgs)
        if len(names) < 2:
            # Two pinned versions of ONE package with identical content is
            # the diamond-dep problem — detect-diamond-deps owns that.
            continue
        if names in allow:
            continue
        direct_pkgs = [p for p in pkgs if direct.get(p)]
        if len(direct_pkgs) >= 2:
            # Both sides pinned directly by this repo: the exact MR !28
            # class — direct pins are wired into the main module graph.
            failures.append((sig, pkgs))
        else:
            # A transitive pin is involved; reachability depends on how the
            # intermediate package wires its dep, so warn without blocking.
            warnings.append((sig, pkgs))

    def render(bucket: list[tuple[frozenset[tuple[str, str, str]], list[str]]]) -> None:
        for sig, pkgs in bucket:
            rendered = "; ".join(f"{n}: {t} = {v}" for t, n, v in sorted(sig, key=lambda p: p[1]))
            print(f"  [{rendered}]")
            for pkg in sorted(pkgs):
                marker = "direct" if direct.get(pkg) else "transitive"
                print(f"    - {pkg} ({marker})")

    if warnings:
        print(
            "⚠ latent options-content collisions involving transitive pins (not blocking — fix upstream when bumping):"
        )
        render(warnings)

    if not failures:
        print("check-dep-options-collision: ok — no direct-pin collisions")
        return 0

    print("✗ identical generated build-options content across direct pins:")
    render(failures)
    print(
        "\nIdentical generated options content dedupes to one cached "
        "options.zig; one file rooted in two modules is a hard Zig compile "
        "error when both packages land in the same compilation "
        "(see MR !28 / uuid v0.1.5 vs fts-storage).\n"
        "Fix upstream: add a distinguishing option, e.g.\n"
        '  build_options.addOption([]const u8, "package_name", "<pkg>");\n'
        "(the timeseries-storage convention), then bump the pin here.\n"
        "A pair that is provably not co-reachable can be suppressed in "
        "scripts/options_collision_allowlist.txt."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
