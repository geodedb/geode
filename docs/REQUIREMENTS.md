# REQUIREMENTS — Geode v0.18.0

This page mirrors GitLab requirement issues. GitLab is the source of truth for status and details.

## Core Requirements
- [REQ-0001: Standards & Conformance Requirements](https://gitlab.com/devnw/geode/geode/-/issues/239)
- [REQ-0002: Language Surface Requirements](https://gitlab.com/devnw/geode/geode/-/issues/240)
- [REQ-0003: Engine Contract Requirements](https://gitlab.com/devnw/geode/geode/-/issues/241)
- [REQ-0004: Transactions & Storage Requirements](https://gitlab.com/devnw/geode/geode/-/issues/242)
- [REQ-0005: Security Requirements](https://gitlab.com/devnw/geode/geode/-/issues/243)
- [REQ-0006: Distributed & Ops Requirements](https://gitlab.com/devnw/geode/geode/-/issues/244)
- [REQ-0007: Tooling & Governance Requirements](https://gitlab.com/devnw/geode/geode/-/issues/245)
- [REQ-0008: Platform & Build Requirements](https://gitlab.com/devnw/geode/geode/-/issues/246)
- [REQ-0009: Performance Targets (Non-binding)](https://gitlab.com/devnw/geode/geode/-/issues/247)

## Security
- [REQ-DOC-ADVANCED_SECURITY_FEATURES_OCTOBER_2025: Advanced Security Features - October 2025 Requirements](https://gitlab.com/devnw/geode/geode/-/issues/280)
- [REQ-DOC-ARGON2ID_IMPLEMENTATION: Argon2id Password Hashing Implementation Requirements](https://gitlab.com/devnw/geode/geode/-/issues/281)
- [REQ-DOC-DESIGN_TDE_KMS: DESIGN_TDE_KMS.md - TDE Key Management & External KMS Stub Requirements](https://gitlab.com/devnw/geode/geode/-/issues/283)
- [REQ-DOC-FIELD_LEVEL_ENCRYPTION: Field-Level Encryption (FLE) for Geode Requirements](https://gitlab.com/devnw/geode/geode/-/issues/284)
- [REQ-DOC-SECURITY_PROGRESS: SECURITY_PROGRESS.md - Security & Hardening Matrix Requirements](https://gitlab.com/devnw/geode/geode/-/issues/285)
- [REQ-DOC-USER_AUTH: Geode User Authentication System Requirements](https://gitlab.com/devnw/geode/geode/-/issues/289)

## GQL Language & Conformance
- [REQ-DOC-EXPRESSION_OPERATORS: GQL Expression Operators Requirements](https://gitlab.com/devnw/geode/geode/-/issues/262)
- [REQ-DOC-TYPE_CONVERSION_FUNCTIONS: Type Conversion Functions Implementation Requirements](https://gitlab.com/devnw/geode/geode/-/issues/288)
- [REQ-DOC-UNICODE: UNICODE.md - Geode Unicode Support (v0.18.0) Requirements](https://gitlab.com/devnw/geode/geode/-/issues/268)
- [REQ-DOC-VALUES_MATCH_CHAINING_SPEC: VALUES -> MATCH Chaining Technical Specification Requirements](https://gitlab.com/devnw/geode/geode/-/issues/269)
- [REQ-DOC-GQL_CONFORMANCE_PROFILE: GQL Conformance Profile — MATCH (subset) Requirements](https://gitlab.com/devnw/geode/geode/-/issues/291)
- [REQ-DOC-MATCH_TUTORIAL: MATCH Subset Tutorial (Geode) Requirements](https://gitlab.com/devnw/geode/geode/-/issues/275)

## Engine & Features
- [REQ-DOC-SERVER_FEATURES: Geode Server Features Documentation Requirements](https://gitlab.com/devnw/geode/geode/-/issues/267)
- [REQ-DOC-MATERIALIZED_VIEWS: Materialized Views System Requirements](https://gitlab.com/devnw/geode/geode/-/issues/266)
- [REQ-DOC-BM25_INDEX_OPTIMIZER_INTEGRATION: BM25 IndexOptimizer Integration Requirements](https://gitlab.com/devnw/geode/geode/-/issues/261)
- [REQ-DOC-GRAPH_ALGORITHM_PERFORMANCE_ENHANCEMENTS: Graph Algorithm Performance Enhancements Requirements](https://gitlab.com/devnw/geode/geode/-/issues/264)
- [REQ-DOC-EVALUATION_PIPELINE: Geode Expression Evaluation Pipeline Requirements](https://gitlab.com/devnw/geode/geode/-/issues/290)
- [REQ-DOC-TELEMETRY: Streaming Telemetry (Paging Events) - v0.16.0 Requirements](https://gitlab.com/devnw/geode/geode/-/issues/286)
- [REQ-DOC-ALL_PHASES_COMPLETION_SUMMARY: All Phases Completion Summary Requirements](https://gitlab.com/devnw/geode/geode/-/issues/272)

## Transport & Protocol
- [REQ-DOC-BINARY_PROTOCOL: Binary Protocol — GQL Outcome & Diagnostics Mapping (v0.16.0) Requirements](https://gitlab.com/devnw/geode/geode/-/issues/260)
- [REQ-DOC-QUIC: Geode QUIC Transport Guide Requirements](https://gitlab.com/devnw/geode/geode/-/issues/277)
- [REQ-DOC-QUIC_INTEGRATION_SUMMARY: QUIC/TLS 1.3 Integration — Finalized (vendored module + geode wiring) Requirements](https://gitlab.com/devnw/geode/geode/-/issues/292)

## Tooling, Governance & Testing
- [REQ-DOC-GOVERNANCE: Governance Automation & Evidence Integrity - v0.16.0 Requirements](https://gitlab.com/devnw/geode/geode/-/issues/263)
- [REQ-DOC-STATUS_LEDGER: CANARY status.csv Requirement Ledger](https://gitlab.com/devnw/geode/geode/-/issues/293)
- [REQ-DOC-TESTING: Testing Documentation for Geode Requirements](https://gitlab.com/devnw/geode/geode/-/issues/287)
- [REQ-DOC-GEODE_TESTLAB_FIXES: Geode Test Lab Fixes Tracking Requirements](https://gitlab.com/devnw/geode/geode/-/issues/278)
- [REQ-DOC-SHELL_TEST_ISSUES: Shell Test Issues - December 2025 Requirements](https://gitlab.com/devnw/geode/geode/-/issues/279)
- [REQ-DOC-CONFORMANCE_SYNC: Conformance Sync Scanner Requirements](https://gitlab.com/devnw/geode/geode/-/issues/276)

## CLI, REPL, and Clients
- [REQ-DOC-CLI_SUBPROCESS_ELIMINATION: CLI Subprocess Elimination Implementation Requirements](https://gitlab.com/devnw/geode/geode/-/issues/282)
- [REQ-DOC-LSP_IMPLEMENTATION: Geode Language Server Protocol (LSP) Implementation Requirements](https://gitlab.com/devnw/geode/geode/-/issues/265)
- [REQ-DOC-REPL_ADVANCED_FEATURES: Advanced REPL Features Requirements](https://gitlab.com/devnw/geode/geode/-/issues/273)
- [REQ-DOC-REPL_FORMATTING_FIXES: REPL Formatting Fixes Requirements](https://gitlab.com/devnw/geode/geode/-/issues/274)
- [REQ-DOC-RUST_CLIENT_S2N_QUIC_FINDINGS: Rust Client Migration to s2n-quic - Findings Report Requirements](https://gitlab.com/devnw/geode/geode/-/issues/270)
- [REQ-DOC-ZIG_CLIENT_V2_COMPLETION_REPORT: Zig Client v2: Zig 0.15.1 Migration - Completion Report Requirements](https://gitlab.com/devnw/geode/geode/-/issues/271)
