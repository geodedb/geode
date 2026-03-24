// Thin compatibility wrapper — delegates to external audit library.
// CANARY: REQ=REQ-QUALITY-GAP-413-011; FEATURE="OrphanedTestRemediation"; ASPECT=Zig015API; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30

const audit_lib = @import("audit_lib");
const lib_time = audit_lib.time;

// Re-export all public types from the external library
pub const Clock = lib_time.Clock;
pub const SystemClock = lib_time.SystemClock;
pub const FixedClock = lib_time.FixedClock;
pub const IdGen = lib_time.IdGen;
pub const SystemIdGen = lib_time.SystemIdGen;
pub const FixedIdGen = lib_time.FixedIdGen;

// Re-export functions
pub const formatRfc3339 = lib_time.formatRfc3339;

// Re-export test constants
pub const TEST_TIMESTAMP_MS = lib_time.TEST_TIMESTAMP_MS;
pub const TEST_TRACE_ID = lib_time.TEST_TRACE_ID;
pub const TEST_SPAN_ID = lib_time.TEST_SPAN_ID;
pub const TEST_REQUEST_ID = lib_time.TEST_REQUEST_ID;
