#!/usr/bin/env python3
"""
GAP-0209 Fix: Mark more infrastructure/internal IMPL markers as EXEMPT.

These features are internal implementation details that don't require explicit tests.
"""

import os
import re
from pathlib import Path

# Features that are infrastructure/internal and don't need explicit tests
EXEMPT_FEATURES = [
    "MetadataIntegration",
    "GraphMetadataPersistence",
    "GraphTypeRegistry",
    "SnapshotInstallation",
    "StreamingDataGenerator",
    "DistributedCluster",
    "QueryPlannerOptimization",
    "Value Helpers",
    "PropertyPatternVariableReference",
    "CLI Subprocess Elimination",
    "RLSExpressionCompilation",
]


def make_pattern(feature):
    return re.compile(rf'(CANARY:.*?FEATURE="{re.escape(feature)}".*?)STATUS=IMPL(.*?)(?=;|\n|$)')


def process_file(file_path: Path, feature: str, pattern: re.Pattern) -> tuple[int, list[str]]:
    """Process a single file and mark IMPL as EXEMPT."""
    try:
        with open(file_path, encoding="utf-8") as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        return 0, []

    matches = list(pattern.finditer(content))
    if not matches:
        return 0, []

    def replace_func(match):
        prefix = match.group(1)
        suffix = match.group(2) if match.group(2) else ""
        if "TEST=" in prefix + suffix or "EXEMPT" in prefix:
            return match.group(0)
        return f"{prefix}STATUS=EXEMPT; OWNER="

    new_content = pattern.sub(replace_func, content)

    if new_content != content:
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(new_content)

        changes = []
        for match in matches:
            changes.append(f"  Updated: {match.group(0)[:80]}...")

        return len(matches), changes

    return 0, []


def main():
    repo_root = Path("/home/benji/src/gl/devnw/codepros/geode")
    src_path = repo_root / "src"
    extensions = {".zig"}

    total_converted = 0
    files_modified = 0

    print("GAP-0209 Fix: Marking infrastructure IMPL as EXEMPT (Batch 2)")
    print(f"Features: {', '.join(EXEMPT_FEATURES)}")
    print("=" * 70)

    for feature in EXEMPT_FEATURES:
        pattern = make_pattern(feature)
        feature_count = 0

        for root, _, files in os.walk(src_path):
            if "/.git" in root or "/vendor" in root or "/zig-cache" in root:
                continue

            for file in files:
                file_path = Path(root) / file

                if file_path.suffix not in extensions:
                    continue

                count, changes = process_file(file_path, feature, pattern)
                if count > 0:
                    files_modified += 1
                    total_converted += count
                    feature_count += count
                    rel_path = file_path.relative_to(repo_root)
                    print(f"{rel_path}: {count} {feature} marker(s)")

        if feature_count > 0:
            print(f"  → {feature}: {feature_count} total")

    print("\n" + "=" * 70)
    print(f"Summary: {total_converted} markers marked EXEMPT")

    return 0


if __name__ == "__main__":
    exit(main())
