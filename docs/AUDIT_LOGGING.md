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

- **Canonical keys** (order): `stream`, `hash_v`, `seq_no`, `timestamp`,
  `event_type`, `tenant`?, `actor`, `origin`, `resource` (`type`, `id`,
  `graph`?), `action`, `result` (these three not in a DIGEST), `session`?,
  `reason`?, `policy_id`?, `ip_address`?, `query_hash`?, `details`,
  `prev_hash`, `event_hash`, `signature`. `?` marks a field written only
  when it is set; `details` keys are sorted.
- **Hash algorithm**: SHA-256.
- **Chain**: `prev_hash` of record i equals `SHA-256(event_hash of i-1)`. First `prev_hash` is `SHA-256` of 32 zero bytes
- **Digest**: Every 100 events (configurable), a DIGEST record is appended containing the Merkle root over the event_hashes written since the last DIGEST (since the logger opened, after a restart) and an Ed25519 signature over its own event_hash. A clean close and a rotation also append one when records were written since the last DIGEST.

### What `event_hash` covers (hash format 2, SONNY-3147)

Every record the writer emits carries `"hash_v":2` and

```text
event_hash = SHA-256( "geode.audit.event_hash.v2" 0x00
                      || kind || 0x00
                      || prev_hash (32 raw bytes)
                      || body )
```

- `kind` is `event`, `digest` (`event_type` `DIGEST`) or `key_epoch`
  (`resource.type` `audit_key_epoch` and `action` `KEY_EPOCH`), so one kind
  of record cannot be passed off as another.
- `body` is the record line's exact bytes from `{` up to and including the
  `,` before `"prev_hash"`: every field the record carries, in the order
  above. The writer has one encoding: strings are JSON-escaped one way
  (`writeJsonString`), numbers are decimal without sign or exponent, the
  timestamp is `YYYY-MM-DDTHH:MM:SS.mmmZ`, `details` keys are sorted, an
  absent optional field is omitted and an empty one is written (`""`,
  `null` details vs `{}`), so absent and empty hash differently. The line
  ends `"prev_hash":"<64 hex>","event_hash":"<64 hex>","signature":null}` or
  `...,"signature":"<128 hex>"}`; a verifier splits a line from that fixed
  tail, never by searching for the field names.
- A change to any field of a record (the timestamp, actor, tenant, session,
  client address, reason, policy id, query hash, result, resource type, id
  or graph, action, event type, details) changes its event_hash.

**Format 1 (before SONNY-3147).** Records without `hash_v` were hashed as
`SHA-256(prev_hash || event_type || resource.id || action)` (for a DIGEST,
`"digest"` and `"EMIT_DIGEST"`). Their timestamp, actor, tenant, session,
client address, reason, result, resource type and details are **not
tamper-evident**. `geode audit verify` checks such records with the format-1
rule, counts them (`hash_v1=<n>`) and prints a `NOTICE` saying so. The first
record a new binary appends to an old log is format 2; a format-1 record
after a format-2 record fails verification (`HASH_VERSION_DOWNGRADE`).

**What a pass attests, and what it cannot.** The hashes are keyless: whoever
can rewrite the log can recompute a changed record's event_hash and every
later record's. What stops that is the signed DIGEST after it: its
event_hash depends on the whole chain before it and its signature needs the
seed. So, with the trusted `--pubkey` values:

- a changed field, a deleted, inserted or reordered record fails, at the
  record itself (event_hash, prev_hash, seq_no) when the attacker did not
  recompute, and at the next signed DIGEST when they did;
- records after the last signed DIGEST can be changed and re-hashed, or
  removed, without detection. A running server keeps up to
  `digest_interval - 1` (99 by default) such records; a cleanly closed or
  rotated log ends with a DIGEST. **Truncating the log back to an earlier
  DIGEST is never detectable from the log alone**: keep an external anchor
  (the last `seq_no` and `event_hash`, e.g. shipped to a SIEM) to detect it;
- without `--pubkey`, only consistency is checked (chain, record hashes,
  `seq_no`): a log rewritten from scratch passes.

### Signing Configuration

- Signing enabled by default
- Keys from environment: `GEODE_AUDIT_SEC`, the Ed25519 seed (64 hex
  characters; the legacy 128-character secret key is accepted), and
  `GEODE_AUDIT_PUB`, the public key of that seed (64 hex characters)
- Set both or neither (an empty value counts as unset). With neither, the
  log uses file-backed keys (below). Only one of them set, a malformed value,
  or a `GEODE_AUDIT_PUB` that is not the seed's public key is an error
  (SONNY-6422): `geode serve` refuses to start before it creates the data
  directory (`[startup] GEODE_AUDIT_PUB / GEODE_AUDIT_SEC unusable
  (AuditKeyPairIncomplete | AuditKeyInvalid | AuditKeyMismatch) ...`, no
  value printed), and the `__geode_security` graph does not open without
  its audit logger. One of the pair alone used to fall back silently to
  file-backed keys.

### File-Backed Keys and Key Epochs (SONNY-6322)

Without `GEODE_AUDIT_PUB`/`GEODE_AUDIT_SEC`, a log `F` (for example
`<data dir>/<graph uuid>/audit.jsonl` of the `__geode_security` graph) keeps
its keys beside it, created exclusive and no-follow, mode 0600:

- `F.key`: the Ed25519 seed that signs DIGEST records. **Backups never hold
  it** (at any depth): whoever reads a backup must not be able to sign
  forged audit entries.
- `F.pub`: the public key of epoch 0; `F.pub.<n>`: the public key of epoch n.

A log that has a public key but no seed (a restored store) starts a **new key
epoch** n+1 the first time it is opened: a new pair, the new public key in
`F.pub.<n+1>`, and a `KEY_EPOCH` record appended to the chain
(`event_type` `system_event`, `resource` `{"type":"audit_key_epoch",
"id":"epoch-<n>:<public key hex>"}`, both covered by `event_hash`, `action`
`KEY_EPOCH`, signed by the NEW key). The old public key files are never
changed, so the restored entries still verify. Old backups that still hold the
seed restore with a warning naming `audit.jsonl.key` (written 0600) and keep
signing in the same epoch.

What a verifier can and cannot attest across an epoch boundary:

- It can attest that every DIGEST before the boundary was signed by the
  previous epoch's key, every DIGEST after it by the new key, that the
  `KEY_EPOCH` record names exactly the trusted new key and is signed by it,
  and that the hash chain and `seq_no` run unbroken through the boundary.
- It cannot attest that the holder of the previous key handed over to the new
  one: the previous seed is not in the backup, so it cannot sign the hand-over.
  That the new epoch continues the same store is attested by the operator who
  restored it. Keep each epoch's public key in a trusted place (not only beside
  the log, where whoever can rewrite the log can rewrite the key file too).

### File Rotation

The server does not rotate its audit log: nothing acts on
`rotation_size_mb`. The rotation code was reachable only from the
`audit.configure_rotation` and `audit.test_rotation_continuity` procedures,
which rotated a logger of their own in the working directory, not the
server's log; SONNY-6340 refused those procedures and removed the code. A
rotated file (`audit.jsonl.<ms>`) from an earlier release continues the chain
of the file before it (see below), and `CALL audit.cleanup_log_files()`
deletes such files older than the logger's `retention_days`.

## Verification CLI

Use the unified `geode audit verify` subcommand to validate an audit file:

```bash
# Note: GAP-0159 - Updated to use unified CLI (geode audit verify)
zig build
./zig-out/bin/geode audit verify --file /var/log/geode/audit.jsonl --algo sha256 --pubkey $GEODE_AUDIT_PUB
# A log with key epochs: one --pubkey per epoch, in order
./zig-out/bin/geode audit verify --file <graph dir>/audit.jsonl \
  --pubkey "$(cat trusted/audit.jsonl.pub)" --pubkey "$(cat trusted/audit.jsonl.pub.1)"
```

With `--pubkey`, every DIGEST must verify with its epoch's key and every
`KEY_EPOCH` record must name the next trusted key; **any signature that does
not verify makes the command fail** (it used to report `signatures_failed=N`
and exit 0; an invalid `--pubkey` used to be ignored silently). A log with more
epochs than keys given fails (`UntrustedKeyEpoch`).

### Verification Outputs

One verdict: `OK chain ✅ ...` is printed only when everything verified
(chain, every record's hash, sequence, signatures); a failure prints the
first failing record and its class, then `FAILED ❌ ...`, and exits non-zero
(3 for a broken chain link, 1 for anything else). Until SONNY-3147 a
signature failure printed `OK chain` first. No record contents are printed.

- `OK chain` - records=N digests=D algo=sha256 record_hashes=verified hash_v2=N hash_v1=M (signatures_verified=S, or signatures=not_checked without `--pubkey`)
- `NOTICE` - M records use hash format 1 (see above)
- `TAMPER chain` - at_record=r reason=PREV_HASH_MISMATCH
- `TAMPER record` - at_record=r reason=EVENT_HASH_MISMATCH hash_v=v (a covered field changed, or the stored hash replaced)
- `TAMPER sequence` - at_record=r reason=SEQ_NO_MONOTONICITY
- `TAMPER hash_format` - at_record=r reason=HASH_VERSION_DOWNGRADE
- `SCHEMA_ERROR` - at_record=r field=name or reason (not one JSON object, a duplicate key, not the fixed record tail, an unknown `hash_v`)
- `KEY_EPOCH` - at_record=r epoch=n key=hex... (a key-epoch boundary; see above)
- `UNTRUSTED key_epoch` / `TAMPER key_epoch` - the epoch record names a key not
  given with `--pubkey`, epochs do not increase, or its `event_hash` does not
  match the record
- `SIGNATURE_ERROR` - a signature did not verify (the command fails)

The Merkle root in a DIGEST's `details` is covered by its event_hash and
signature but is not recomputed by the verifier (after a restart it covers
only the records since the logger opened). The server-side
`CALL audit.verify_hash_chain()` is not supported (SONNY-3147): it returned
`valid=true` for any log without comparing anything; verify with
`geode audit verify` and trusted keys.

A rotated file (`audit.jsonl.<ms>`) continues the chain of the file before
it, so it does not verify on its own (its first `prev_hash` follows the
previous file's last record, and its `seq_no` does not start at 1); verify the files concatenated in order.

### Audit Procedures (`CALL audit.*`)

What the server-side procedures do (SONNY-6340):

- `audit.get_merkle_digests()`: a Merkle root over the lines of the server's
  audit log (the process-global log, `GEODE_AUDIT_LOG_PATH` or
  `<data dir>/audit.jsonl`): SHA-256 of each non-empty line as the leaves,
  pairs hashed level by level, an odd node paired with itself. It is not an
  attestation (the log's signatures are checked only by `geode audit
  verify`). Refused (`0A000`) when the server writes no audit log
  (`GEODE_AUDIT_ENABLED` unset).
- `audit.cleanup_log_files()`: deletes the server audit log's rotated files
  older than its retention. Refused when the server writes no audit log.
- `audit.test_signature_verification()`: an Ed25519 sign/verify self-test
  with a fresh key pair; it does not read the log.
- `audit.test_file_output()`, `audit.test_auth_categories()`,
  `audit.cleanup_test_artifacts()`: write and remove private files in
  `<data dir>/audit-diagnostics/` only, never the server's log.

Every other `audit.*` procedure fails with `0A000` (unsupported). They
reported results they did not produce: `compliant`/`passed`/`valid` with no
check, export, report and forensic-package files under `/tmp` that were never
written, `logged=true` without logging, hard-coded "anomalies", "threat
indicators", SIEM alerts and privilege escalations, constant disk and memory
figures, synthetic events written into the server's real audit log, or a
"configuration" of a logger of their own that the server never used:
`configure`, `log_auth_event`, `log_lifecycle_event`, `get_recent_events`,
`verify_hash_chain`, `comprehensive_integrity_check`,
`test_command_categories`, `test_data_access_categories`,
`configure_rotation`, `configure_retention`, `simulate_windows_eventlog`,
`simulate_syslog_output`, `test_combined_output`, `test_siem_correlation`,
`test_siem_alerts`, `generate_compliance_report`,
`test_powershell_compatibility`, `test_rotation_continuity`,
`detect_anomalies`, `extract_threat_indicators`,
`detect_privilege_escalation`, `performance_test`, `memory_usage_test`,
`concurrent_access_test`, `test_disk_space_handling`,
`test_corruption_handling`, `test_invalid_config`, `export_for_verification`,
`prepare_forensic_package`, `compliance_verification`.

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

## Command audit (`geode --audit*`, `GEODE_AUDIT_*`)

Every `geode` command (including `geode serve`) can log its own start and
dispatch events, separately from the server's audit chain above. The sinks
come from the global flags `--audit`, `--audit-file <path>`,
`--audit-syslog <host>[:<port>]` and `--audit-eventlog [<source>]`, or from
the environment:

| Variable | Meaning |
| -------- | ------- |
| `GEODE_AUDIT_ENABLED` | turns command audit on. Every `GEODE_AUDIT_*_ENABLED` switch takes `1`/`0`, `true`/`false` or `yes`/`no` in any case; any other value is refused (SONNY-6511) |
| `GEODE_AUDIT_FILE_ENABLED`, `GEODE_AUDIT_FILE_PATH` | append JSON lines to the file (default `/var/log/geode/cli-audit.log`) |
| `GEODE_AUDIT_SYSLOG_ENABLED`, `GEODE_AUDIT_SYSLOG_HOST`, `GEODE_AUDIT_SYSLOG_PORT` | send RFC 5424 datagrams over UDP; the host is an IPv4 address, a bracketed IPv6 address (`[::1]`) or `localhost`, optionally with `:<port>`; the port defaults to 514 |
| `GEODE_AUDIT_WINDOWS_EVENTLOG_ENABLED`, `..._SOURCE`, `..._LOG` | Windows Event Log (Windows only) |

Command audit **fails closed** (SONNY-6494): a `GEODE_AUDIT_SYSLOG_PORT`
that is not a port, a `GEODE_AUDIT_SYSLOG_HOST` the sender cannot send to (a
host name, a bare IPv6 address), or a sink that cannot be opened (an audit
file whose directory or file cannot be created) makes the command exit
non-zero with a message naming the setting, before it does anything. A
`geode serve` asked to audit does not start, as it does when the server's
own audit file cannot be opened. These used to print a warning (or nothing:
a bad port became 514 and a host name dropped every message) and run
unaudited. The `--audit-syslog` flag is validated the same way (SONNY-6487).

## Design Rationale

- **Security-First Architecture**: Default-deny filtering with fail-closed behavior ensures no sensitive data can be accidentally logged, providing defense in depth against data leakage.

- **Standards Compliance**: RFC 5424 syslog with CEF:0 formatting ensures broad compatibility with existing SIEM systems and log management infrastructure.

- **Non-Blocking Design**: Bounded queues with overflow protection prevent audit logging from impacting application performance while maintaining delivery guarantees.

- **Deterministic Testing**: Injectable time and ID providers enable reproducible test cases with exact output validation, ensuring audit trail integrity.

- **Zero SQL Exposure**: Database adapter strictly prohibits SQL text/parameters, eliminating risk of query injection or sensitive data exposure through audit logs.

- **Configurable Redaction**: Multiple detection methods (key patterns, value analysis, content heuristics) with configurable PII/PCI modes provide flexible privacy protection.

- **Operational Robustness**: File rotation, queue management, and error handling designed for production environments with clear failure modes and recovery procedures.
