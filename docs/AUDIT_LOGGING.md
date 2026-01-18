# Audit Logging & Tracing System

A comprehensive, security-first audit logging and tracing subsystem for Geode. This system instruments authentication actions and database operations, emitting structured logs with tamper-evident guarantees.

## Key Features

- **Security-First Design**: Default-deny filtration with built-in sensitive data redaction
- **Tamper-Evident Logging**: Hash-chained JSONL with Merkle digests and Ed25519 signatures
- **RFC 5424 Syslog**: UDP/TCP transport with CEF:0 (Common Event Format) payloads
- **Structured Logging**: JSON-Lines format with deterministic field ordering
- **File Rotation**: Size-based rotation with configurable backup retention
- **W3C Tracing**: Distributed tracing with trace_id and span_id propagation
- **DB-Agnostic Auditing**: Never logs SQL text/parameters, only metadata
- **Non-Blocking Operations**: Bounded queues with overflow protection
- **Fail-Closed Security**: Drops events if redaction cannot guarantee safety

## Hash Chain & Verification

Geode's audit stream is a canonical JSON Lines (JSONL) append-only log. Each record carries seq_no, a hash chain, and periodic Merkle digests signed with Ed25519 (default ON).

### Record Structure

- **Canonical keys** (order): `["stream","seq_no","timestamp","event_type","actor","origin","resource","action","result","details","prev_hash","event_hash","signature"]`
- **Hash algorithm**: SHA-256 (default) or BLAKE3. `event_hash` excludes `prev_hash` to avoid circularity
- **Chain**: `prev_hash` of record i equals `hash(event_hash of i-1)`. First `prev_hash` is 32 zero bytes
- **Digest**: Every 100 events (configurable), a DIGEST record is appended containing the Merkle root over the last N event_hashes and an Ed25519 signature

### Signing Configuration

- Signing enabled by default
- Keys from environment: `GEODE_AUDIT_PUB` (hex32), `GEODE_AUDIT_SEC` (hex64)
- If missing in non-test builds: CONFIG_ERROR SIGNING_KEYS_MISSING (exit 78)
- Test builds derive a deterministic key from a fixed seed

### File Rotation

- Time/size rotation continues `seq_no`
- First record of new file uses `prev_hash` from the prior file's tail
- PII redaction and `log_denies_only` preserved across rotation

## Verification CLI

Use the unified `geode audit verify` subcommand to validate an audit file:

```bash
# Note: GAP-0159 - Updated to use unified CLI (geode audit verify)
zig build
./zig-out/bin/geode audit verify --file /var/log/geode/audit.jsonl --algo sha256 --pubkey $GEODE_AUDIT_PUB
```

### Verification Outputs

- `OK chain` - records=N digests=D algo=sha256|blake3
- `TAMPER chain` - at_seq=s reason=PREV_HASH_MISMATCH expected=hex got=hex
- `TAMPER digest` - at_seq=s reason=DIGEST_MISMATCH expected=hex got=hex
- `SCHEMA_ERROR` - at_seq=s field=name detail=msg
- `WARN ignored trailing partial record` (non-fatal)

## Quick Start

### Basic Usage

```zig
const std = @import("std");
const audit = @import("audit/logger.zig");
const config = @import("audit/config.zig");
const events = @import("audit/events.zig");
const time = @import("audit/time.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    const audit_config = try config.loadConfig(allocator, "config/logging.json");
    defer audit_config.deinit();

    // Initialize logger with system clock and ID generation
    var sys_clock = time.SystemClock{};
    var sys_id_gen = time.SystemIdGen.init();

    const logger = try audit.AuditLogger.init(
        allocator,
        audit_config,
        sys_clock.clock(),
        sys_id_gen.idGen()
    );
    defer logger.deinit();

    // Create and emit audit event
    const auth_event = events.AuditEvent{
        .category = "auth",
        .action = "login",
        .outcome = .success,
        .ts_unix_ms = 0, // Auto-filled
        .severity = .INFO,
        .actor_id = "user@example.com",
        .subject_id = null,
        .request_id = "req-12345",
        .session_id = "ses-abcdef",
        .source_ip = "192.168.1.100",
        .trace_id = null, // Auto-generated
        .span_id = null,  // Auto-generated
        .metadata = null,
    };

    try logger.audit(&auth_event);
}
```

## Configuration

The system is configured via a JSON file. Default location: `config/logging.json`

### Schema

```json
{
  "version": 1,
  "service": {
    "name": "authsvc",
    "host": "app-host",
    "pid": 1234
  },
  "identity": {
    "cef": {
      "vendor": "DEVNW",
      "product": "GEODE",
      "version": "0.1.0"
    }
  },
  "sinks": {
    "file": {
      "enabled": true,
      "path": "zig-out/tmp/audit.log",
      "max_bytes": 1048576,
      "backup_count": 5
    },
    "syslog": {
      "enabled": true,
      "protocol": "udp",
      "host": "{{SYSLOG_HOST}}",
      "port": 514,
      "rfc5424": {
        "facility": "local4"
      }
    }
  },
  "filters": {
    "default_deny": true,
    "allow_fields": [
      "actor_id", "subject_id", "request_id", "session_id", "source_ip",
      "trace_id", "span_id", "category", "action", "outcome", "severity",
      "db.operation", "db.table", "db.rowCount", "duration_ms"
    ],
    "deny_key_patterns": ["password", "secret"],
    "pii_mode": "mask",
    "pci_mode": true
  }
}
```

## Testing

```bash
# Format code
zig fmt .

# Run all tests
zig build test --summary all

# Run demo application
zig build run
```

## Security Considerations

### Never Log Sensitive Information

The system is designed with multiple layers of protection:

1. **Key Detection**: Automatic detection of sensitive key patterns
2. **Value Analysis**: Content-based detection of sensitive data patterns
3. **Default Deny**: Only explicitly allowed fields are logged
4. **Fail Closed**: Drop entire event if redaction cannot guarantee safety
5. **No SQL**: Database adapter never accepts SQL text or parameters

## Operational Notes

- Files are opened 0600, append-only
- On startup, tail scan resumes last_seq/last_hash and tolerates one trailing partial line (WARN)
- SIGNING_KEY_ROTATION events are emitted when keys change
- Limits: RSS <= 512 MiB; append latency <= 500 us (excluding fsync)

## Design Rationale

- **Security-First Architecture**: Default-deny filtering with fail-closed behavior ensures no sensitive data can be accidentally logged, providing defense in depth against data leakage.

- **Standards Compliance**: RFC 5424 syslog with CEF:0 formatting ensures broad compatibility with existing SIEM systems and log management infrastructure.

- **Non-Blocking Design**: Bounded queues with overflow protection prevent audit logging from impacting application performance while maintaining delivery guarantees.

- **Deterministic Testing**: Injectable time and ID providers enable reproducible test cases with exact output validation, ensuring audit trail integrity.

- **Zero SQL Exposure**: Database adapter strictly prohibits SQL text/parameters, eliminating risk of query injection or sensitive data exposure through audit logs.

- **Configurable Redaction**: Multiple detection methods (key patterns, value analysis, content heuristics) with configurable PII/PCI modes provide flexible privacy protection.

- **Operational Robustness**: File rotation, queue management, and error handling designed for production environments with clear failure modes and recovery procedures.
