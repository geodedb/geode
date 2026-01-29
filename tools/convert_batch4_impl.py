#!/usr/bin/env python3
"""
GAP-0209 Fix: Batch 4 - Convert more IMPL markers to TESTED.

Converts markers for features that have existing test coverage.
"""

import os
import re
from pathlib import Path

# Features with their corresponding test files
FEATURES_WITH_TESTS = {
    "ListProperties": "geodetestlab/specs/geode_b01_b10_regression.yml",
    "MapProperties": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "MultiGraphSupport": "geodetestlab/specs/multi_graph.yml",
    "SHOW TABLES": "geodetestlab/specs/gap_139_show_statements.yml",
    "SHOW CONSTRAINTS": "geodetestlab/specs/gap_139_show_statements.yml",
    "KeysFunction": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "ListSlicing": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "ListFunctions": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "InOperator": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "NotInOperator": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "CountSubquery": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ArithmeticFunctions": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "ThreeValuedLogic": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "VariableLengthPaths": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "ChainedWithAggregation": "geodetestlab/specs/gql_query_comprehensive.yml",
    "WithWherePostFilter": "geodetestlab/specs/gql_query_comprehensive.yml",
    "REPL QUIC Integration": "geodetestlab/specs/geode_quic_transport.yml",
    "QUIC Authentication": "geodetestlab/specs/geode_quic_transport.yml",
    "QueryOptimization": "geodetestlab/specs/geode_performance_stress.yml",
}


def make_pattern(feature):
    return re.compile(rf'(CANARY:.*?FEATURE="{re.escape(feature)}".*?)STATUS=IMPL(.*?)(?=;|\n|$)')


def process_file(file_path: Path, feature: str, test_file: str, pattern: re.Pattern) -> tuple[int, list[str]]:
    """Process a single file and convert IMPL to TESTED."""
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
        if "TEST=" in prefix + suffix:
            return match.group(0)
        return f"{prefix}STATUS=TESTED; TEST={test_file}{suffix}"

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

    print("GAP-0209 Fix: Batch 4 - Converting IMPL to TESTED")
    print(f"Features: {len(FEATURES_WITH_TESTS)}")
    print("=" * 70)

    for feature, test_file in FEATURES_WITH_TESTS.items():
        pattern = make_pattern(feature)
        feature_count = 0

        for root, _, files in os.walk(src_path):
            if "/.git" in root or "/vendor" in root or "/zig-cache" in root:
                continue

            for file in files:
                file_path = Path(root) / file

                if file_path.suffix not in extensions:
                    continue

                count, changes = process_file(file_path, feature, test_file, pattern)
                if count > 0:
                    files_modified += 1
                    total_converted += count
                    feature_count += count
                    rel_path = file_path.relative_to(repo_root)
                    print(f"{rel_path}: {count} {feature} marker(s)")

        if feature_count > 0:
            print(f"  → {feature}: {feature_count} total")

    print("\n" + "=" * 70)
    print(f"Summary: {total_converted} markers converted to TESTED")

    return 0


if __name__ == "__main__":
    exit(main())
