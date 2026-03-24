// Thin compatibility wrapper — delegates to external audit library.

const audit_lib = @import("audit_lib");
const lib_events = audit_lib.events;

// Re-export all public types from the external library
pub const Severity = lib_events.Severity;
pub const Outcome = lib_events.Outcome;
pub const AuditEvent = lib_events.AuditEvent;
