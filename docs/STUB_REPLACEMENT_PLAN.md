# Stub Procedure Replacement Plan
**Created**: October 19, 2025
**Status**: Phase 1-5 Complete! (33/60+ procedures implemented)
**Latest**: Phase 2-5 completed October 19, 2025 with complex real implementations

## Overview
This document tracks the replacement of stub/mock procedures in `path_and_call_operations.zig` with real implementations using existing infrastructure.

## Progress Tracking

### ✅ Completed (33/60+ procedures implemented)
**Initial Implementation** (9 procedures):
- [x] `audit.log_auth_event` - Real AuditLogger event logging
- [x] `audit.test_file_output` - Real file I/O with JSONL format
- [x] `audit.test_auth_categories` - Real authentication event logging
- [x] `audit.verify_hash_chain` - SHA-256 hash chain verification
- [x] `audit.test_signature_verification` - Ed25519 signature operations
- [x] `audit.get_merkle_digests` - Merkle tree construction
- [x] `tde.test_encryption` - AES-256-GCM encryption
- [x] `tde.test_decryption` - Real decryption with verification
- [x] `tde.test_key_rotation` - Key rotation simulation

**Phase 1** (5 procedures - October 19, 2025):
- [x] `audit.test_data_access_categories` - Real event categorization using AuditLogger
- [x] `audit.configure_rotation` - Real rotation configuration with file rotation
- [x] `audit.configure_retention` - Real retention policy configuration
- [x] `audit.cleanup_log_files` - Real log file cleanup with directory scanning
- [x] `audit.test_rotation_continuity` - Real rotation continuity testing

### ✅ Phase 1: Core Audit Logging (Complete - October 19, 2025)
- [x] `audit.test_data_access_categories` - Data access event categorization (TESTED)
- [x] `audit.configure_rotation` - Log rotation configuration (TESTED)
- [x] `audit.configure_retention` - Retention policy management (TESTED)
- [x] `audit.cleanup_log_files` - Old log deletion (TESTED)
- [x] `audit.test_rotation_continuity` - Rotation verification (TESTED)

### ✅ Phase 2: Platform Output (Complete - October 19, 2025)
- [x] `audit.simulate_windows_eventlog` - Windows Event Log format (TESTED)
- [x] `audit.simulate_syslog_output` - Syslog RFC3164/RFC5424 (TESTED)
- [x] `audit.test_combined_output` - Multi-format output (TESTED)

### ✅ Phase 3: Security Analysis (Complete - October 19, 2025)
- [x] `audit.detect_anomalies` - Anomaly detection with statistical analysis (TESTED)
- [x] `audit.extract_threat_indicators` - IOC extraction with confidence levels (TESTED)
- [x] `audit.detect_privilege_escalation` - Escalation detection patterns (TESTED)
- [x] `audit.test_siem_correlation` - SIEM event correlation (TESTED)
- [x] `audit.test_siem_alerts` - Alert generation with severity levels (TESTED)

### ✅ Phase 4: Performance Testing (Complete - October 19, 2025)
- [x] `audit.performance_test` - Throughput testing with real metrics (TESTED)
- [x] `audit.memory_usage_test` - Memory profiling with leak detection (TESTED)
- [x] `audit.concurrent_access_test` - Thread safety with atomics (TESTED)
- [x] `audit.test_disk_space_handling` - Disk full handling with compression (TESTED)
- [x] `audit.test_corruption_handling` - Corruption recovery (TESTED)
- [x] `audit.test_invalid_config` - Config validation with auto-fix (TESTED)

### ✅ Phase 5: Compliance (Complete - October 19, 2025)
- [x] `audit.generate_compliance_report` - Compliance reports (TESTED)
- [x] `audit.prepare_forensic_package` - Forensic packages (TESTED)
- [x] `audit.export_for_verification` - Export for validation (TESTED)
- [x] `audit.compliance_verification` - GDPR/SOX/HIPAA/PCI checks (TESTED)
- [x] `audit.test_powershell_compatibility` - PowerShell cmdlet testing (TESTED)

### 📋 Phase 6: TDE Core (Planned)
- [ ] `tde.initialize_key_hierarchy` - Key hierarchy setup
- [ ] `tde.rotate_keys` - Key rotation
- [ ] `tde.get_encryption_status` - Status queries
- [ ] `tde.configure_kms` - KMS configuration
- [ ] `tde.verify_encrypted_state` - Encryption verification

### 📋 Phase 7: TDE Advanced (Planned)
- [ ] `tde.benchmark_encryption` - Performance benchmarks
- [ ] `tde.backup_encrypted` - Encrypted backups
- [ ] `tde.configure_key_provider` - Provider setup
- [ ] `tde.derive_data_key` - Key derivation
- [ ] `tde.derive_wal_key` - WAL keys
- [ ] (20+ more TDE procedures)

## Implementation Guidelines

### Principles
1. **NO MOCK DATA** - Use real implementations from existing modules
2. **COMPLEX LOGIC** - Implement actual functionality, not stubs
3. **USE INFRASTRUCTURE** - Leverage existing security modules
4. **TEST COMPATIBILITY** - Ensure procedures work with geodetestlab tests

### Common Patterns

#### Audit Event Logging
```zig
// Use global audit logger
if (global_audit_logger == null) {
    global_audit_logger_mutex.lock();
    defer global_audit_logger_mutex.unlock();
    global_audit_logger = try audit_mod.AuditLogger.init(allocator, .{});
}

// Log real events
try global_audit_logger.?.logEvent(.{
    .timestamp = std.time.milliTimestamp(),
    .event_type = .data_access,
    .resource = "table_name",
    // ... real data
});
```

#### TDE Operations
```zig
// Enable TDE for operations
tde_mod.enableForTests();
defer tde_mod.disableForTests();

// Perform real encryption/decryption
const ciphertext = try tde_mod.encrypt(allocator, plaintext, aad);
defer allocator.free(ciphertext.data);
```

#### File Operations
```zig
// Real file I/O
const file = try std.fs.cwd().createFile(path, .{});
defer file.close();
try file.writeAll(content);
```

## Test Coverage Impact

Current test status:
- **Before stub replacement**: 1568 passing tests
- **After initial replacement**: 1582-1597 passing tests
- **Target after all phases**: 1620+ passing tests

## Notes

- Each phase should be completed and tested before moving to the next
- Prioritize high-impact procedures that affect test pass rates
- Document any new infrastructure modules needed
- Update CANARY markers when implementations change from IMPL to TESTED