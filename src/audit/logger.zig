// Thin compatibility wrapper — delegates to external audit library.
// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-001; FEATURE="External Library Migration"; ASPECT=StructuredLogging; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-005; FEATURE="External Library Migration"; ASPECT=AuditLogger; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24

const audit_lib = @import("audit_lib");
const lib_logger = audit_lib.logger;

// Re-export all public types from the external library
pub const AuditLogger = lib_logger.AuditLogger;

// Re-export public functions
pub const buildAuditLogger = lib_logger.buildAuditLogger;
