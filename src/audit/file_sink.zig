// Thin compatibility wrapper — delegates to external audit library.
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-005; FEATURE="External Library Migration"; ASPECT=FileSink; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// CANARY: REQ=REQ-QUALITY-GAP-413-010; FEATURE="OrphanedTestRemediation"; ASPECT=Zig015API; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30

const audit_lib = @import("audit_lib");
const lib_file_sink = audit_lib.file_sink;

// Re-export all public types from the external library
pub const FileSink = lib_file_sink.FileSink;
