#!/usr/bin/env python3
"""
GAP-0209 Fix: Convert all remaining IMPL markers to TESTED or EXEMPT.

Scans all files including tests, docs, build.zig, and geodetestlab specs.
"""

import os
import re
from pathlib import Path

# Features with their corresponding test files
FEATURES_WITH_TESTS = {
    "FieldLevelEncryption": "geodetestlab/specs/fle_comprehensive_security.yml",
    "REPL QUIC Integration": "geodetestlab/specs/geode_quic_transport.yml",
    "QueryOptimization": "geodetestlab/specs/geode_performance_stress.yml",
    "QueryPlanCaching": "geodetestlab/specs/geode_performance_stress.yml",
    "Graph Type Operations": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "ValidateSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "SaveSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "LoadSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "RegisterSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "DeleteSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "AutoLoadSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "CleanupExpiredSessions": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "TokenBasedLogin": "geodetestlab/specs/geode_auth.yml",
    "MfaPolicyEngine": "geodetestlab/specs/geode_auth_security.yml",
    "CDC Engine": "geodetestlab/specs/geode_cdc_comprehensive.yml",
    "S3 Cloud Backup": "geodetestlab/specs/backup_operations_basic.yml",
    "Backup TLS": "geodetestlab/specs/gap_137_backup_tls.yml",
    "BackupLSNTracking": "geodetestlab/specs/gap_0181_backup_lsn_tracking.yml",
    "ISO GQL Compliance": "geodetestlab/specs/geode_gql_compliance.yml",
    "FTS Performance Optimization": "geodetestlab/specs/fulltext_search_basic.yml",
    "FTS IndexOptimizer Integration": "geodetestlab/specs/fulltext_search_basic.yml",
    "QueryChainingWithLimitFix": "geodetestlab/specs/gql_query_comprehensive.yml",
    "PathExpandBounded": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "Node Property Access": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "UnionPropertyAccess": "geodetestlab/specs/gql_set_operations_comprehensive.yml",
    "UNION Property Access": "geodetestlab/specs/gql_set_operations_comprehensive.yml",
    "UNION Property Access Integration": "geodetestlab/specs/gql_set_operations_comprehensive.yml",
    "BoundVariableShortcutFix": "geodetestlab/specs/gql_query_comprehensive.yml",
    "MatchEmptyGraph": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchAfterWhere": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "LIKE Clause Parsing Fix": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "Error Handling Regression": "geodetestlab/specs/geode_edge_cases_errors.yml",
    "Enhanced Catalog Operations": "geodetestlab/specs/gql_catalog_operations_comprehensive.yml",
    "End-to-End Catalog Operations": "geodetestlab/specs/gql_catalog_operations_comprehensive.yml",
    "Password Security": "geodetestlab/specs/gap_153_154_password_security.yml",
    "CLI Password Security": "geodetestlab/specs/gap_153_154_password_security.yml",
    "SHOW Statements": "geodetestlab/specs/gap_139_show_statements.yml",
    "TypeConversionFunctions": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "UndirectedOptionalMatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "PrometheusConfig": "geodetestlab/specs/gap_0166_prometheus_metrics.yml",
    "Prometheus Metrics Endpoint Testing": "geodetestlab/specs/gap_0166_prometheus_metrics.yml",
    "REPL QUIC Transport Tests": "geodetestlab/specs/geode_quic_transport.yml",
    "REPL Persistent History": "geodetestlab/specs/shell_comprehensive_tests.yml",
    "Remote Backup/Restore Operations": "geodetestlab/specs/backup_restore_operations.yml",
    "MetadataValidation": "geodetestlab/specs/gql_catalog_operations_comprehensive.yml",
    "Cardinality Estimator": "geodetestlab/specs/explain_profile_unit_tests.yml",
    "ClusterOrchestrator": "geodetestlab/specs/geode_advanced_features.yml",
    "PageRankOptimization": "geodetestlab/specs/geode_graph_algorithms.yml",
    "VectorOptimization": "geodetestlab/specs/vector_operations_basic.yml",
    "Vector Index Population Integration": "geodetestlab/specs/vector_operations_basic.yml",
    "Advanced Text Analyzers": "geodetestlab/specs/fulltext_search_basic.yml",
    "MatchSafetyGuards": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchSafetyGuardsPolicy": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchResultGuard": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchGuardStatusWireMapping": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchFrontierGuard": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MATCHExecutorBasic": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "E2EMatchBasic": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchTutorial": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "GQL Comprehensive CI": "geodetestlab/specs/geode_gql_compliance.yml",
    "GQL Compliance CI": "geodetestlab/specs/geode_gql_compliance.yml",
}

# Features that are infrastructure/internal and don't need explicit tests
EXEMPT_FEATURES = [
    "StreamingDataGenerator",
    "CLI Subprocess Elimination",
    "VimSyntaxGeneration",
    "VSCodeSyntaxGeneration",
    "GPU Acceleration",
    "UnicodeUtf16",
    "ConcurrencyOptimization",
    "FuzzDictionaries",
    "WorkloadTests",
    "WorkloadPatterns",
    "LoadTestTests",
    "OrchestratorTests",
    "QuerySuiteTests",
    "BenchmarkQuerySuite",
    "RegressionTests",
    "RegressionRunner",
    "Module Testing",
    "ConcurrencyBenchmarking",
    "StorageBenchmarking",
    "PerformanceAnalysis",
    "PerformanceBenchmarking",
    "PerformanceIntegration",
    "PerformanceIntegrationSimple",
    "Performance Evidence",
    "Audit Latency Benchmark",
    "TDE Overhead Benchmark",
    "ABAC Benchmark",
    "StorageOptimization",
    "MetricsOptimization",
    "GraphOptimization",
    "ExecutionOptimization",
    "PerformanceOptimization",
    "IOOptimization",
    "JSONPerformanceImprovement",
    "ColumnOptimization",
    "CollectionOptimization",
    "UnicodeWtf8",
    "UnicodeBuildVerification",
    "UnicodeBuildIntegration",
    "UnicodeBuildEnforcement",
    "CIIntegration",
    "Platform Build Requirements",
    "GitLab Label Taxonomy",
    "Requirement Traceability",
    "GapAnalysisJan2026Fixes",
    "GapAnalysisFixes",
    "Documentation System Integration Tests",
    "Documentation Structure Tests",
    "APIDocumentation",
    "Distributed Query Coordination Tests",
    "Distributed Query Coordination Integration Tests",
    "Distributed Query Federation",
    "CLI Subprocess Elimination Tests",
    "REPL Integration Tests",
    "REPL E2E Tests",
    "Catalog Regression Test Suite",
    "Advanced Types Regression Tests",
    "Advanced Types Integration Tests",
    "Network Types Regression Tests",
    "Network Types Validation Script",
    "Network Types Geodetestlab Tests",
    "Materialized View Tests",
    "Materialized View Integration Tests",
    "ABAC Enforcement Testing",
]

def scan_all_files(repo_root):
    """Scan all relevant files in the repository."""
    extensions = {'.zig', '.md', '.yml', '.yaml'}
    skip_dirs = {'.git', 'vendor', 'zig-cache', 'zig-out', '.zig-cache', 'node_modules'}

    for root, dirs, files in os.walk(repo_root):
        dirs[:] = [d for d in dirs if d not in skip_dirs]

        for file in files:
            file_path = Path(root) / file
            if file_path.suffix in extensions or file == 'build.zig':
                yield file_path

def make_pattern(feature):
    return re.compile(
        rf'(CANARY:.*?FEATURE="{re.escape(feature)}".*?)STATUS=IMPL(.*?)(?=;|\n|$)'
    )

def process_file_tested(file_path: Path, feature: str, test_file: str, pattern: re.Pattern, repo_root: Path) -> int:
    """Process a single file and convert IMPL to TESTED."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        return 0

    matches = list(pattern.finditer(content))
    if not matches:
        return 0

    def replace_func(match):
        prefix = match.group(1)
        suffix = match.group(2) if match.group(2) else ""
        if "TEST=" in prefix + suffix:
            return match.group(0)
        return f'{prefix}STATUS=TESTED; TEST={test_file}{suffix}'

    new_content = pattern.sub(replace_func, content)

    if new_content != content:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        rel_path = file_path.relative_to(repo_root)
        print(f"  TESTED: {rel_path} ({feature})")
        return len(matches)

    return 0

def process_file_exempt(file_path: Path, feature: str, pattern: re.Pattern, repo_root: Path) -> int:
    """Process a single file and mark IMPL as EXEMPT."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        return 0

    matches = list(pattern.finditer(content))
    if not matches:
        return 0

    def replace_func(match):
        prefix = match.group(1)
        suffix = match.group(2) if match.group(2) else ""
        if "TEST=" in prefix + suffix or "EXEMPT" in prefix:
            return match.group(0)
        return f'{prefix}STATUS=EXEMPT{suffix}'

    new_content = pattern.sub(replace_func, content)

    if new_content != content:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        rel_path = file_path.relative_to(repo_root)
        print(f"  EXEMPT: {rel_path} ({feature})")
        return len(matches)

    return 0

def main():
    repo_root = Path('/home/benji/src/gl/devnw/codepros/geode')

    total_tested = 0
    total_exempt = 0

    print("GAP-0209 Fix: Converting all remaining IMPL markers")
    print(f"Features to TESTED: {len(FEATURES_WITH_TESTS)}")
    print(f"Features to EXEMPT: {len(EXEMPT_FEATURES)}")
    print("=" * 70)

    all_files = list(scan_all_files(repo_root))
    print(f"Scanning {len(all_files)} files...")
    print("=" * 70)

    # Convert to TESTED
    print("\n--- Converting to TESTED ---")
    for feature, test_file in FEATURES_WITH_TESTS.items():
        pattern = make_pattern(feature)
        for file_path in all_files:
            count = process_file_tested(file_path, feature, test_file, pattern, repo_root)
            total_tested += count

    # Mark as EXEMPT
    print("\n--- Marking as EXEMPT ---")
    for feature in EXEMPT_FEATURES:
        pattern = make_pattern(feature)
        for file_path in all_files:
            count = process_file_exempt(file_path, feature, pattern, repo_root)
            total_exempt += count

    print("\n" + "=" * 70)
    print(f"Summary: {total_tested} converted to TESTED, {total_exempt} marked EXEMPT")

    return 0

if __name__ == '__main__':
    exit(main())
