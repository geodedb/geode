// Thin compatibility wrapper — delegates to external audit library.

const audit_lib = @import("audit_lib");
const lib_cef = audit_lib.cef;

// Re-export all public functions from the external library
pub const formatCef = lib_cef.formatCef;
pub const escapeCefString = lib_cef.escapeCefString;
