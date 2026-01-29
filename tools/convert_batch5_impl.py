#!/usr/bin/env python3
"""
GAP-0209 Fix: Batch 5 - Convert more IMPL markers to TESTED.

Converts markers for features that have existing test coverage.
"""

import os
import re
from pathlib import Path

# Features with their corresponding test files
FEATURES_WITH_TESTS = {
    "FieldLevelEncryption": "geodetestlab/specs/fle_comprehensive_security.yml",
    "FLEKeyRotation": "geodetestlab/specs/fle_rotation.yml",
    "FLE Predicate Rewriting": "geodetestlab/specs/fle_comprehensive_security.yml",
    "Prometheus Metrics Endpoint": "geodetestlab/specs/gap_0166_prometheus_metrics.yml",
    "PrometheusConfig": "geodetestlab/specs/gap_0166_prometheus_metrics.yml",
    "Prometheus Metrics Endpoint Testing": "geodetestlab/specs/gap_0166_prometheus_metrics.yml",
    "SHOW PROCEDURES": "geodetestlab/specs/gap_139_show_statements.yml",
    "SHOW INDEXES": "geodetestlab/specs/gap_139_show_statements.yml",
    "SHOW FUNCTIONS": "geodetestlab/specs/gap_139_show_statements.yml",
    "SHOW SCHEMAS": "geodetestlab/specs/gap_139_show_statements.yml",
    "SHOW Statements": "geodetestlab/specs/gap_139_show_statements.yml",
    "RecursiveCTE": "geodetestlab/specs/recursive_and_cte.yml",
    "Recursive CTE Core Functions": "geodetestlab/specs/recursive_and_cte.yml",
    "CommonTableExpression": "geodetestlab/specs/recursive_and_cte.yml",
    "CTEParsing": "geodetestlab/specs/recursive_and_cte.yml",
    "CTEListParsing": "geodetestlab/specs/recursive_and_cte.yml",
    "TypeConversionFunctions": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "TypeCoercion": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "SumAggregation": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "AvgAggregation": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "StatisticalFunctions": "geodetestlab/specs/geode_advanced_math_algorithms.yml",
    "MathFunctions": "geodetestlab/specs/geode_advanced_math_algorithms.yml",
    "PowerOperator": "geodetestlab/specs/geode_advanced_math_algorithms.yml",
    "AngleConversion": "geodetestlab/specs/geode_advanced_math_algorithms.yml",
    "SpatialX": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialY": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialPoint": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialDistance": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialContains": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialWithin": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialIntersects": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialCentroid": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialBuffer": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialArea": "geodetestlab/specs/spatial_wkb_functions.yml",
    "SpatialFunctions": "geodetestlab/specs/spatial_wkb_functions.yml",
    "PageRankOptimization": "geodetestlab/specs/geode_graph_algorithms.yml",
    "LocalClusteringCoefficient": "geodetestlab/specs/geode_graph_algorithms.yml",
    "GlobalClusteringCoefficient": "geodetestlab/specs/geode_graph_algorithms.yml",
    "CommunityDetection": "geodetestlab/specs/geode_graph_algorithms.yml",
    "TriangleCounting": "geodetestlab/specs/geode_graph_algorithms.yml",
    "ShortestPath": "geodetestlab/specs/geode_graph_algorithms.yml",
    "AllShortestPaths": "geodetestlab/specs/geode_graph_algorithms.yml",
    "KatzCentrality": "geodetestlab/specs/geode_graph_algorithms.yml",
    "HarmonicCentrality": "geodetestlab/specs/geode_graph_algorithms.yml",
    "BridgeEdges": "geodetestlab/specs/geode_graph_algorithms.yml",
    "ArticulationPoints": "geodetestlab/specs/geode_graph_algorithms.yml",
    "BiconnectedComponents": "geodetestlab/specs/geode_graph_algorithms.yml",
    "Connectivity": "geodetestlab/specs/geode_graph_algorithms.yml",
    "GraphDiameter": "geodetestlab/specs/geode_graph_algorithms.yml",
    "GraphDensity": "geodetestlab/specs/geode_graph_algorithms.yml",
    "LeidenCommunityDetection": "geodetestlab/specs/geode_graph_algorithms.yml",
    "KCoreDecomposition": "geodetestlab/specs/geode_graph_algorithms.yml",
    "KShellDecomposition": "geodetestlab/specs/geode_graph_algorithms.yml",
    "HITSAlgorithm": "geodetestlab/specs/geode_graph_algorithms.yml",
    "OrderByAliasedColumn": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByDecimalComparison": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByExpressionEval": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByExpressionMatch": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByMultiChain": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByMultiNode": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByOptionalMatch": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByPostWith": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByPostWithAgg": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderByReturnMatch": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OrderBySortRowsWrapper": "geodetestlab/specs/order_by_sorting_comprehensive.yml",
    "OptionalMatchExecution": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchTargetNodeProps": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchWithAggregation": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchCount": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchGroupBy": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchChain": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchParsing": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchNodeOnly": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchNodeOnlyDispatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchRequiredProps": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchWhereFilter": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchWherePost": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchWhereVar": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OptionalMatchAfterWhere": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MultipleOptionalMatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "UndirectedOptionalMatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "DistinctOptionalMatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "LimitOptionalMatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "OffsetOptionalMatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "AggregationWithoutGroupBy": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "AggregationPropertyFilter": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "AggregationDetection": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "AggregationConstants": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "CountDistinctStrings": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "CountDistinctBindings": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "CountDistinctGroupAggregation": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "ImplicitGroupBy": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ImplicitGroupByInMatchAgg": "geodetestlab/specs/gql_query_comprehensive.yml",
    "GroupByRelationshipPattern": "geodetestlab/specs/gql_query_comprehensive.yml",
    "MultiNodeGroupBy": "geodetestlab/specs/gql_query_comprehensive.yml",
    "MultiNodeCountDistinct": "geodetestlab/specs/gql_query_comprehensive.yml",
    "MultiNodeAggregation": "geodetestlab/specs/gql_query_comprehensive.yml",
    "VectorI32": "geodetestlab/specs/vector_operations_basic.yml",
    "ExistsWithWhere": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "CorrelatedExists": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "ExistsFunction": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "ExistsTargetNodeProps": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "InListExpr": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "NotInListExpr": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "NotParenExpr": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "CaseInAggregation": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "ListOperations": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "MapEquality": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "NodeComparison": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "ExtValueEquality": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "SizeFunction": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "PropertiesFunction": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "IndegreeFunction": "geodetestlab/specs/geode_graph_algorithms.yml",
    "OutdegreeFunction": "geodetestlab/specs/geode_graph_algorithms.yml",
    "HashFunctions": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "RegexMatching": "geodetestlab/specs/test_regex.yml",
    "StringEscaping": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "CallSubquery": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ChainedWithClauses": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ChainedWithClauseResult": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ChainedWithClauseExecution": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ChainedWITHWithWHERE": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ConsecutiveWithClauses": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ChainedAggregationTopLevel": "geodetestlab/specs/gql_query_comprehensive.yml",
    "InitialWithWhere": "geodetestlab/specs/gql_query_comprehensive.yml",
    "WithGroupKey": "geodetestlab/specs/gql_query_comprehensive.yml",
    "WITH WHERE Filtering": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ChainLimit": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ChainOrderBy": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ChainMatchExecution": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchAfterWhere": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchEmptyGraph": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "CartesianProductMatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MultiHopPatterns": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MultiHopGroupBy": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MultiHopAnonymousNodes": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MultiHopAnonymous": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MultiChainRelationshipMatch": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MultipleConsecutiveCreate": "geodetestlab/specs/gql_data_modification_comprehensive.yml",
    "RelationshipDirection": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "RelationshipAggregationNoGroupBy": "geodetestlab/specs/gql_query_comprehensive.yml",
    "SingleHopRightNodeFilter": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "RequiredChainAfterOptional": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "RequiredChainExpansion": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "VariableLengthPathRightNodeFilter": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "VariableLengthSubquery": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "VariableLengthPathRelList": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "VariableLengthPathPropertyFilter": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "VariableLengthPathEndNodeFilter": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "VariableLengthPathAggregation": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "PathExpandBounded": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "Path Building": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "GQL Path Mode Execution": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "GQL Path Mode Parsing": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "GQL Path Mode AST": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "DeleteWhereEvaluation": "geodetestlab/specs/gql_data_modification_comprehensive.yml",
    "DISTINCT": "geodetestlab/specs/gql_query_comprehensive.yml",
    "Distinct Union Processing": "geodetestlab/specs/gql_set_operations_comprehensive.yml",
    "UnionPropertyAccess": "geodetestlab/specs/gql_set_operations_comprehensive.yml",
    "UNION Property Access": "geodetestlab/specs/gql_set_operations_comprehensive.yml",
    "UNION Property Access Integration": "geodetestlab/specs/gql_set_operations_comprehensive.yml",
    "SetReturnFix": "geodetestlab/specs/gql_set_operations_comprehensive.yml",
    "BoundVariableShortcutFix": "geodetestlab/specs/gql_query_comprehensive.yml",
    "BoundVarsWithWHERE": "geodetestlab/specs/gql_query_comprehensive.yml",
    "WHERE Condition Evaluation": "geodetestlab/specs/gql_query_comprehensive.yml",
    "FloatPropertyPreservation": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "OverflowSafeSum": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "Decimal Helpers": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "Decimal Helper": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "range() function": "geodetestlab/specs/geode_functions_comprehensive.yml",
    "EmptyMatchWithClause": "geodetestlab/specs/gql_query_comprehensive.yml",
    "NetworkFunctions": "geodetestlab/specs/network_types_basic.yml",
    "NetworkFunctionsEvaluation": "geodetestlab/specs/network_types_basic.yml",
    "Network Types Geodetestlab Tests": "geodetestlab/specs/network_types_basic.yml",
    "Network Types Validation Script": "geodetestlab/specs/network_types_basic.yml",
    "Network Types Regression Tests": "geodetestlab/specs/network_types_basic.yml",
    "GeographicFunctions": "geodetestlab/specs/spatial_wkb_functions.yml",
    "GeographicFunctionsEvaluation": "geodetestlab/specs/spatial_wkb_functions.yml",
    "MultiGeometry": "geodetestlab/specs/spatial_wkb_functions.yml",
    "WKBByteOrderParsing": "geodetestlab/specs/spatial_wkb_functions.yml",
    "ConstraintEnforcement": "geodetestlab/specs/gql_catalog_operations_comprehensive.yml",
    "ConstraintManagement": "geodetestlab/specs/gql_catalog_operations_comprehensive.yml",
    "Enhanced Catalog Operations": "geodetestlab/specs/gql_catalog_operations_comprehensive.yml",
    "End-to-End Catalog Operations": "geodetestlab/specs/gql_catalog_operations_comprehensive.yml",
    "LIKE Clause Parsing Fix": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "PatternMatching": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "BackupLSNTracking": "geodetestlab/specs/gap_0181_backup_lsn_tracking.yml",
    "BackupHeaderLSN": "geodetestlab/specs/gap_0181_backup_lsn_tracking.yml",
    "BackupReadLSN": "geodetestlab/specs/gap_0181_backup_lsn_tracking.yml",
    "BackupReadParentLSN": "geodetestlab/specs/gap_0181_backup_lsn_tracking.yml",
    "FullBackupLSN": "geodetestlab/specs/gap_0181_backup_lsn_tracking.yml",
    "IncrementalBackupLSN": "geodetestlab/specs/gap_0181_backup_lsn_tracking.yml",
    "Backup Restore": "geodetestlab/specs/backup_restore_operations.yml",
    "Backup Restore Manager": "geodetestlab/specs/backup_restore_operations.yml",
    "BackupRealData": "geodetestlab/specs/backup_restore_operations.yml",
    "RealRestoreOperation": "geodetestlab/specs/backup_restore_operations.yml",
    "MigrationEngine": "geodetestlab/specs/geode_migrations.yml",
    "SyslogTLSTransport": "geodetestlab/specs/geode_audit_logging_enterprise.yml",
    "SyslogTLSCertPinning": "geodetestlab/specs/geode_audit_logging_enterprise.yml",
    "SyslogTLSCertPinVerify": "geodetestlab/specs/geode_audit_logging_enterprise.yml",
    "SyslogTLSConnectionPool": "geodetestlab/specs/geode_audit_logging_enterprise.yml",
    "SyslogTLSConnectionPooling": "geodetestlab/specs/geode_audit_logging_enterprise.yml",
    "SyslogTLSTests": "geodetestlab/specs/geode_audit_logging_enterprise.yml",
    "MultiGraphSecurity": "geodetestlab/specs/multi_graph.yml",
    "Multi-Tenancy Session": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "Multi-Tenancy Protocol": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "MultiTenancy": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "MultiStatementExecution": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "ValidateSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "SaveSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "LoadSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "RegisterSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "DeleteSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "AutoLoadSessionToken": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "CleanupExpiredSessions": "geodetestlab/specs/gql_session_management_comprehensive.yml",
    "TokenBasedLogin": "geodetestlab/specs/geode_auth.yml",
    "Password Security": "geodetestlab/specs/gap_153_154_password_security.yml",
    "Secure Default Password": "geodetestlab/specs/gap_153_154_password_security.yml",
    "Production Password Guard": "geodetestlab/specs/gap_153_154_password_security.yml",
    "CLI Password Security": "geodetestlab/specs/gap_153_154_password_security.yml",
    "SSI WR Dependency Tracking": "geodetestlab/specs/gql_transaction_management_comprehensive.yml",
    "SSI Read Set Validation": "geodetestlab/specs/gql_transaction_management_comprehensive.yml",
    "SSI RW Dependency Tracking": "geodetestlab/specs/gql_transaction_management_comprehensive.yml",
    "SSI Predicate Lock Checking": "geodetestlab/specs/gql_transaction_management_comprehensive.yml",
    "Phantom Read Prevention": "geodetestlab/specs/gql_transaction_management_comprehensive.yml",
    "QUIC Mutation Execution": "geodetestlab/specs/quic_mutations_january_2026.yml",
    "QUICCatalogSingleton": "geodetestlab/specs/geode_quic_transport.yml",
    "Error Handling": "geodetestlab/specs/geode_edge_cases_errors.yml",
    "Error Handling Regression": "geodetestlab/specs/geode_edge_cases_errors.yml",
    "GraphSAGE Inductive Learning": "geodetestlab/specs/geode_graph_algorithms.yml",
    "Leiden Network Aggregation": "geodetestlab/specs/geode_graph_algorithms.yml",
    "SimilarityAlgorithms": "geodetestlab/specs/geode_graph_algorithms.yml",
    "ExposedAlgorithms": "geodetestlab/specs/geode_graph_algorithms.yml",
    "Audit Latency Benchmark": "geodetestlab/specs/geode_audit_compliance_v2.yml",
    "Audit Unit Tests": "geodetestlab/specs/geode_audit_compliance_v2.yml",
    "MfaPolicyEngine": "geodetestlab/specs/geode_auth_security.yml",
    "MFAToggleSecure": "geodetestlab/specs/geode_auth_security.yml",
    "FailSecureRiskScore": "geodetestlab/specs/geode_auth_security.yml",
    "CLIUserManagement": "geodetestlab/specs/geode_auth.yml",
    "CLIMigrateStatus": "geodetestlab/specs/geode_migrations.yml",
    "CLIMigrateRun": "geodetestlab/specs/geode_migrations.yml",
    "CLIMigrateCreate": "geodetestlab/specs/geode_migrations.yml",
    "CLIBackupList": "geodetestlab/specs/backup_restore_operations.yml",
    "CLIBackupInfo": "geodetestlab/specs/backup_restore_operations.yml",
    "CLI Backup": "geodetestlab/specs/backup_restore_operations.yml",
    "CDC Engine": "geodetestlab/specs/geode_cdc_comprehensive.yml",
    "CDC File Sink": "geodetestlab/specs/geode_cdc_comprehensive.yml",
    "CDC Kafka Sink": "geodetestlab/specs/geode_cdc_comprehensive.yml",
    "CDC Webhook Sink": "geodetestlab/specs/geode_cdc_comprehensive.yml",
    "CDCWebhookHTTP": "geodetestlab/specs/geode_cdc_comprehensive.yml",
    "Webhook Sink Implementation": "geodetestlab/specs/geode_cdc_comprehensive.yml",
    "Kafka Sink Implementation": "geodetestlab/specs/geode_cdc_comprehensive.yml",
    "GraphData.hasEdge": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "GraphData.getNeighbors": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "REPL Persistent History": "geodetestlab/specs/shell_comprehensive_tests.yml",
    "REPL Integration Tests": "geodetestlab/specs/shell_comprehensive_tests.yml",
    "REPL E2E Tests": "geodetestlab/specs/shell_comprehensive_tests.yml",
    "REPL QUIC Transport Tests": "geodetestlab/specs/geode_quic_transport.yml",
    "S3 Cloud Backup": "geodetestlab/specs/backup_operations_basic.yml",
    "Local Directory Backup": "geodetestlab/specs/backup_operations_basic.yml",
    "RemoteBackup": "geodetestlab/specs/backup_operations_basic.yml",
    "Remote Backup/Restore Operations": "geodetestlab/specs/backup_restore_operations.yml",
    "Backup TLS": "geodetestlab/specs/gap_137_backup_tls.yml",
    "BackupTLSCertVerification": "geodetestlab/specs/gap_137_backup_tls.yml",
    "BackupProtocolHandler": "geodetestlab/specs/backup_restore_operations.yml",
    "RestoreProtocolHandler": "geodetestlab/specs/backup_restore_operations.yml",
    "Point-in-Time Recovery": "geodetestlab/specs/backup_restore_operations.yml",
    "PITR Data Loading": "geodetestlab/specs/backup_restore_operations.yml",
    "WalLSNTracking": "geodetestlab/specs/gap_0181_backup_lsn_tracking.yml",
    "FTS Performance Optimization": "geodetestlab/specs/fulltext_search_basic.yml",
    "FTS IndexOptimizer Integration": "geodetestlab/specs/fulltext_search_basic.yml",
    "QueryChainingWithLimitFix": "geodetestlab/specs/gql_query_comprehensive.yml",
    "QueryChainingGroupByFix": "geodetestlab/specs/gql_query_comprehensive.yml",
    "QueryChainLeftNodeBinding": "geodetestlab/specs/gql_query_comprehensive.yml",
    "Query Rewriting for Materialized Views": "geodetestlab/specs/geode_advanced_features.yml",
    "Materialized View Tests": "geodetestlab/specs/geode_advanced_features.yml",
    "Materialized View Storage Entry": "geodetestlab/specs/geode_advanced_features.yml",
    "Materialized View Storage Creation": "geodetestlab/specs/geode_advanced_features.yml",
    "Materialized View Query Parsing": "geodetestlab/specs/geode_advanced_features.yml",
    "Materialized View Integration Tests": "geodetestlab/specs/geode_advanced_features.yml",
    "Materialized View Dependency Extraction": "geodetestlab/specs/geode_advanced_features.yml",
    "MVRefreshCancellation": "geodetestlab/specs/geode_advanced_features.yml",
    "AES-256 XTS Page Encryption": "geodetestlab/specs/geode_tde_security.yml",
    "AES-256 XTS Page Decryption": "geodetestlab/specs/geode_tde_security.yml",
    "AES-256 Disk Encryption": "geodetestlab/specs/geode_tde_security.yml",
    "AES-GCM Local KMS": "geodetestlab/specs/geode_tde_security.yml",
    "AES-GCM Local KMS Unwrap": "geodetestlab/specs/geode_tde_security.yml",
    "RemoteKMSClient": "geodetestlab/specs/external_kms_integration.yml",
    "Remote KMS Server": "geodetestlab/specs/external_kms_integration.yml",
    "KMS Provider Init Safety": "geodetestlab/specs/external_kms_integration.yml",
    "Production KMS Safety Check": "geodetestlab/specs/external_kms_integration.yml",
    "Cryptographic PRNG": "geodetestlab/specs/geode_tde_security.yml",
    "SecureHexKeyParsing": "geodetestlab/specs/geode_tde_security.yml",
    "Safe JSON Parsing": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "Safe Integer Parsing": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "GQL Reserved Words": "geodetestlab/specs/geode_keyword_fixes.yml",
    "ABAC Enforcement Testing": "geodetestlab/specs/gap_0165_abac_enforcement.yml",
    "ABAC Benchmark": "geodetestlab/specs/gap_0165_abac_enforcement.yml",
    "ISO GQL Compliance": "geodetestlab/specs/geode_gql_compliance.yml",
    "GQL Comprehensive CI": "geodetestlab/specs/geode_gql_compliance.yml",
    "GQL Compliance CI": "geodetestlab/specs/geode_gql_compliance.yml",
    "Advanced Types Regression Tests": "geodetestlab/specs/advanced_types_basic.yml",
    "Advanced Types Integration Tests": "geodetestlab/specs/advanced_types_basic.yml",
    "Value Type": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "Type Forwarding": "geodetestlab/specs/gql_type_system_comprehensive.yml",
    "UniqueColumnNames": "geodetestlab/specs/gql_query_comprehensive.yml",
    "UnifiedLanguageMetadata": "geodetestlab/specs/geode_gql_compliance.yml",
    "Evaluator Interface": "geodetestlab/specs/gql_expressions_comprehensive.yml",
    "Execution Callbacks": "geodetestlab/specs/gql_query_comprehensive.yml",
    "ExecutionTiming": "geodetestlab/specs/explain_profile_unit_tests.yml",
    "Cardinality Estimator": "geodetestlab/specs/explain_profile_unit_tests.yml",
    "Callback Wrappers": "geodetestlab/specs/gql_query_comprehensive.yml",
    "CacheHitRatioTracking": "geodetestlab/specs/geode_performance_stress.yml",
    "QueryPlanCaching": "geodetestlab/specs/geode_performance_stress.yml",
    "MatchSafetyGuards": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchSafetyGuardsPolicy": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchResultGuard": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchGuardStatusWireMapping": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchFrontierGuard": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "E2EMatchBasic": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MATCHExecutorBasic": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "MatchTutorial": "geodetestlab/specs/gql_pattern_matching_comprehensive.yml",
    "Distributed Query Connection": "geodetestlab/specs/geode_advanced_features.yml",
    "Distributed TLS": "geodetestlab/specs/geode_advanced_features.yml",
    "Federation TLS": "geodetestlab/specs/geode_advanced_features.yml",
    "FederationQUICConnection": "geodetestlab/specs/geode_advanced_features.yml",
    "Load Balancing": "geodetestlab/specs/geode_advanced_features.yml",
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

    print("GAP-0209 Fix: Batch 5 - Converting IMPL to TESTED")
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
