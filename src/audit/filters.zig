// Thin compatibility wrapper — delegates to external audit library.
// CANARY: REQ=REQ-QUALITY-GAP-413-012; FEATURE="OrphanedTestRemediation"; ASPECT=AllocatorPassing; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30

const audit_lib = @import("audit_lib");
const lib_filters = audit_lib.filters;

// Re-export all public types from the external library
pub const FilterResult = lib_filters.FilterResult;
pub const RedactionToken = lib_filters.RedactionToken;

// Re-export public functions
pub const isSensitiveKey = lib_filters.isSensitiveKey;
pub const isJwt = lib_filters.isJwt;
pub const isPan = lib_filters.isPan;
pub const isEmail = lib_filters.isEmail;
pub const isPhone = lib_filters.isPhone;
pub const isPemPrivateKey = lib_filters.isPemPrivateKey;
pub const maskEmail = lib_filters.maskEmail;
pub const maskPhone = lib_filters.maskPhone;
pub const detectValueType = lib_filters.detectValueType;
pub const filterAndRedactMetadata = lib_filters.filterAndRedactMetadata;
