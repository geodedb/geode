// Audit module bundle - exports all audit components via external audit library.
// CANARY: REQ=REQ-QUALITY-GAP-413-007; FEATURE="OrphanedTestRemediation"; ASPECT=AuditBundle; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
// Created to support test modules with proper Zig 0.15 module semantics

pub const filters = @import("filters.zig");
pub const config = @import("config.zig");
pub const events = @import("events.zig");
pub const syslog = @import("syslog.zig");
pub const file_sink = @import("file_sink.zig");
pub const time = @import("time.zig");
pub const cef = @import("cef.zig");
pub const logger = @import("logger.zig");

// Re-export json_util from the external library for consumers that need it
pub const json_util = @import("audit_lib").json_util;
