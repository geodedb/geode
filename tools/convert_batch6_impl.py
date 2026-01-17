#!/usr/bin/env python3
"""
GAP-0209 Fix: Batch 6 - Convert more IMPL markers to TESTED.

Converts markers for features that have existing test coverage.
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

def make_pattern(feature):
    return re.compile(
        rf'(CANARY:.*?FEATURE="{re.escape(feature)}".*?)STATUS=IMPL(.*?)(?=;|\n|$)'
    )

def process_file(file_path: Path, feature: str, test_file: str, pattern: re.Pattern) -> tuple[int, list[str]]:
    """Process a single file and convert IMPL to TESTED."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
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
        return f'{prefix}STATUS=TESTED; TEST={test_file}{suffix}'

    new_content = pattern.sub(replace_func, content)

    if new_content != content:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)

        changes = []
        for match in matches:
            changes.append(f"  Updated: {match.group(0)[:80]}...")

        return len(matches), changes

    return 0, []

def main():
    repo_root = Path('/home/benji/src/gl/devnw/geode/geode')
    src_path = repo_root / 'src'
    extensions = {'.zig'}

    total_converted = 0
    files_modified = 0

    print("GAP-0209 Fix: Batch 6 - Converting IMPL to TESTED")
    print(f"Features: {len(FEATURES_WITH_TESTS)}")
    print("=" * 70)

    for feature, test_file in FEATURES_WITH_TESTS.items():
        pattern = make_pattern(feature)
        feature_count = 0

        for root, _, files in os.walk(src_path):
            if '/.git' in root or '/vendor' in root or '/zig-cache' in root:
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

if __name__ == '__main__':
    exit(main())
