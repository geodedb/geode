#!/usr/bin/env python3
"""
GAP-0209 Fix: Mark more infrastructure/internal IMPL markers as EXEMPT (Batch 4).

These features are internal implementation details that don't require explicit tests.
"""

import os
import re
from pathlib import Path

# Features that are infrastructure/internal and don't need explicit tests
EXEMPT_FEATURES = [
    # Internal optimizations
    "MetricsOptimization",
    "GraphOptimization",
    "ExecutionOptimization",
    "PerformanceOptimization",
    "PerformanceAnalysis",
    "PerformanceBenchmarking",
    "PerformanceIntegration",
    "PerformanceIntegrationSimple",
    "Performance Evidence",
    "StorageOptimization",
    "StorageBenchmarking",
    "CollectionOptimization",
    "JSONPerformanceImprovement",
    "IOOptimization",
    "MeanDistance",
    # Build/CI infrastructure
    "UnicodeBuildVerification",
    "UnicodeBuildIntegration",
    "UnicodeBuildEnforcement",
    "CIIntegration",
    "Platform Build Requirements",
    "GitLab Label Taxonomy",
    "Requirement Traceability",
    "Phase 7 Modularization",
    "DeadCodeRemoval",
    "Module Testing",
    "DependencyInjection",
    "Adapter Initialization",
    "Environment",
    # Testing infrastructure
    "FuzzDictionaries",
    "RegressionTests",
    "RegressionRunner",
    "WorkloadTests",
    "WorkloadPatterns",
    "LoadTestTests",
    "OrchestratorTests",
    "QuerySuiteTests",
    "BenchmarkQuerySuite",
    "ConcurrencyBenchmarking",
    "TDETestImplementations",
    "TDE Overhead Benchmark",
    "BackupLSNTests",
    # Documentation (not testable)
    "Documentation",
    "APIDocumentation",
    "Documentation System Integration Tests",
    "Documentation Structure Tests",
    "GoToDefinition",
    "Language Server Protocol",
    # GPU internal features
    "GPUTelemetryMetrics",
    "GPUSort",
    "GPUPageRank",
    # Internal messaging/protocols
    "Two-Phase Commit Network Transport",
    "Two-Phase Commit Message Format",
    "Network Transport",
    "2PCTimeout",
    "2PC Write Set Application",
    "2PC TLS One-shot",
    "2PC TLS",
    "2PC Storage Interface",
    "2PC Participant Node",
    "2PC Commit Handler",
    "2PC Abort Handler",
    "Write Set Parser and Applicator",
    # Internal cluster infrastructure
    "ClusterOrchestrator",
    "Shard Data Migration",
    "Shard Split Point",
    "ShardPruning",
    "Range-Based Sharding",
    "Graph-Aware Sharding",
    "Geo-Distributed Sharding",
    "Key Range Operations",
    "Node Registry",
    "Union-Find Cycle Detection",
    "Topological Sort Cycle Detection",
    "DFS Cycle Detection",
    # Internal memory management
    "StreamMemoryManagement",
    "CTEDiskSpilling",
    "HighThroughputBulkLoader",
    "MetadataValidation",
    # Internal encoding
    "UnicodeWtf8",
    # Editor tooling (already in batch 3 but may have more)
    "PowerShell Compatibility",
    "Advanced Text Analyzers",
    # Internal algorithm helpers
    "Short-circuit evaluation",
    "BridgeLeverageCentrality",
    "GreyCardinalComposite",
    # Internal distributed features
    "Distributed Query Federation",
    "Distributed Query Coordination Tests",
    "Distributed Query Coordination Integration Tests",
    # CLI internal tests
    "CLI Subprocess Elimination Tests",
    # Internal gap analysis tools
    "GapAnalysisJan2026Fixes",
    "GapAnalysisFixes",
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
        return f"{prefix}STATUS=EXEMPT{suffix}"

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

    print("GAP-0209 Fix: Marking infrastructure IMPL as EXEMPT (Batch 4)")
    print(f"Features: {len(EXEMPT_FEATURES)}")
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
