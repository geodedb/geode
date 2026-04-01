#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_ZON = REPO_ROOT / "build.zig.zon"
BUILD_ZIG = REPO_ROOT / "build.zig"

BANNED_TOP_LEVEL_DEPS = {"ds", "cuda", "tls", "metrics"}
TRANSITIVE_ONLY_DEPS = {"uri", "toml"}

IMPORT_PATTERNS = {
    "yaml": ['@import("yaml")'],
    "strings": ['@import("strings")'],
    "repl": ['@import("repl")'],
    "vulkan": ['@import("vulkan")'],
    "json": ['@import("json")'],
    "quic": ['@import("vendor_quic")', '@import("transport/quic")', '@import("quic")'],
    "slog": ['@import("slog")'],
    "config": ['@import("config")'],
    "cli": ['@import("cli")'],
    "dns": ['@import("dns")'],
    "spice": ['@import("spice")', '@import("parallel/spice")'],
    "mcp": ['@import("mcp")'],
    "protobuf": ['@import("protobuf")'],
    "grpc_zig": ['@import("grpc_server")', '@import("grpc_client")', '@import("grpc")'],
    "uuid": ['@import("uuid")'],
    "wal": ['@import("wal")'],
    "graph_storage": ['@import("graph_storage")'],
    "raft": ['@import("raft")'],
    "audit": ['@import("audit_lib")', '@import("audit")'],
    "hnsw": ['@import("hnsw_lib")', '@import("hnsw")'],
    "rtree": ['@import("rtree_lib")', '@import("rtree")'],
    "concurrency": ['@import("concurrency_lib")'],
    "advanced_types": ['@import("advanced_types_lib")'],
    "fle": ['@import("fle_lib")', '@import("fle_key_manager")', '@import("fle_aead")', '@import("fle_hkdf")'],
    "gql": ['@import("gql_lib")'],
    "timeseries": ['@import("timeseries_lib")'],
    "auth": ['@import("auth_lib")', '@import("auth")'],
}

REMOVED_FILES = [
    REPO_ROOT / "src/transport/thread_pool.zig",
    REPO_ROOT / "src/monitoring/metrics.zig",
    REPO_ROOT / "src/index/hnsw.zig",
    REPO_ROOT / "src/index/rtree.zig",
    REPO_ROOT / "src/distributed/raft.zig",
]

FORBIDDEN_BUILD_IMPORTS = [
    'root_mod.addImport("uri"',
    'root_mod.addImport("ds"',
    'root_mod.addImport("cuda"',
    'root_mod.addImport("tls"',
    'root_mod.addImport("metrics_lib"',
    'geode_exe.root_module.addImport("uri"',
    'geode_exe.root_module.addImport("ds"',
    'geode_exe.root_module.addImport("cuda"',
    'geode_exe.root_module.addImport("tls"',
    'geode_exe.root_module.addImport("metrics_lib"',
]

FORBIDDEN_SRC_IMPORTS = {
    '@import("mfa")': {"src/lib.zig"},
    '@import("index/hnsw.zig")': set(),
    '@import("index/rtree.zig")': set(),
    '@import("distributed/raft.zig")': set(),
}

REQUIRED_FILE_PATTERNS = {
    "src/security/geode_auth_lib.zig": ['@import("auth_lib").mfa'],
    "src/cli/user_mgmt_cli.zig": ['@import("auth_lib").mfa', '@import("mfa_policy")'],
    "src/types/url.zig": ['@import("advanced_types_lib")'],
    "src/keys/manager.zig": ['@import("fle_lib")'],
    "src/distributed/raft_consensus.zig": ['@import("raft")'],
    "src/distributed/raft_persistent.zig": ['@import("raft")'],
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def repo_files() -> list[Path]:
    return list((REPO_ROOT / "src").rglob("*.zig")) + list((REPO_ROOT / "tests").rglob("*.zig"))


def relative(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def dependency_names() -> set[str]:
    text = read_text(BUILD_ZON)
    return set(re.findall(r"^\s*\.(\w+)\s*=\s*\{", text, re.MULTILINE))


def has_any_pattern(paths: list[Path], patterns: list[str]) -> bool:
    for path in paths:
        text = read_text(path)
        if any(pattern in text for pattern in patterns):
            return True
    return False


def main() -> int:
    failures: list[str] = []
    deps = dependency_names()
    all_source_files = repo_files()
    src_files = list((REPO_ROOT / "src").rglob("*.zig"))

    for dep in sorted(BANNED_TOP_LEVEL_DEPS):
        if dep in deps:
            failures.append(f"banned top-level dependency still declared in build.zig.zon: {dep}")

    for dep in sorted(deps):
        if dep in TRANSITIVE_ONLY_DEPS or dep in BANNED_TOP_LEVEL_DEPS:
            continue
        patterns = IMPORT_PATTERNS.get(dep)
        if not patterns:
            failures.append(f"dependency audit has no evidence rule for top-level dependency: {dep}")
            continue
        if not has_any_pattern(all_source_files, patterns):
            failures.append(f"top-level dependency has no direct source/test evidence: {dep}")

    build_text = read_text(BUILD_ZIG)
    live_build_lines = "\n".join(line for line in build_text.splitlines() if not line.lstrip().startswith("//"))
    for pattern in FORBIDDEN_BUILD_IMPORTS:
        if pattern in live_build_lines:
            failures.append(f"forbidden build import still present: {pattern}")

    for path in REMOVED_FILES:
        if path.exists():
            failures.append(f"removed compatibility file still exists: {relative(path)}")

    for pattern, allowed_files in FORBIDDEN_SRC_IMPORTS.items():
        for path in src_files:
            rel = relative(path)
            if rel in allowed_files:
                continue
            if pattern in read_text(path):
                failures.append(f"forbidden src import still present in {rel}: {pattern}")

    lib_text = read_text(REPO_ROOT / "src/lib.zig")
    if "mfa_stub" in lib_text:
        failures.append("legacy mfa_stub export still present in src/lib.zig")

    for file_name, patterns in REQUIRED_FILE_PATTERNS.items():
        text = read_text(REPO_ROOT / file_name)
        for pattern in patterns:
            if pattern not in text:
                failures.append(f"required direct-integration evidence missing from {file_name}: {pattern}")

    if failures:
        print("Dependency integration audit failed:", file=sys.stderr)
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1

    print("Dependency integration audit passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
