// Thin compatibility wrapper: delegates to the external gql library.
//
// CANARY: REQ=GQL-39075-RQ-0012; FEATURE="GQLStatus/SQLSTATE42004"; ASPECT=ConfusableIdentifier; STATUS=TESTED; TEST=GQL39075_RQ0012_sqlstate_42004_exists,GQL39075_RQ0012_confusable_identifier_helper; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0019; FEATURE="GQLStatus/SQLSTATE42501"; ASPECT=PrivilegeViolation; STATUS=TESTED; TEST=GQL39075_RQ0019_sqlstate_42501_privilege_violation,GQL39075_RQ0019_privilege_violation_helper; OWNER=conformance; UPDATED=2026-03-22
// CANARY: REQ=GQL-39075-RQ-0020; FEATURE="GQLStatus/SQLSTATE40003/08007"; ASPECT=ConnectionLoss; STATUS=TESTED; TEST=GQL39075_RQ0020_sqlstate_40003_exists,GQL39075_RQ0020_sqlstate_08007_exists; OWNER=conformance; UPDATED=2026-02-23

const gql_lib = @import("gql_lib");
const ext_status = gql_lib.status;

// Re-export all public types
pub const StatusClass = ext_status.StatusClass;
pub const GqlStatus = ext_status.GqlStatus;
pub const Diagnostic = ext_status.Diagnostic;
pub const SQLSTATE = ext_status.SQLSTATE;

// Re-export all public functions
pub const syntaxError = ext_status.syntaxError;
pub const undefinedIdentifier = ext_status.undefinedIdentifier;
pub const duplicateAlias = ext_status.duplicateAlias;
pub const featureNotSupported = ext_status.featureNotSupported;
pub const invalidCharacter = ext_status.invalidCharacter;
pub const success = ext_status.success;
pub const writeJson = ext_status.writeJson;
pub const confusableIdentifier = ext_status.confusableIdentifier;
pub const privilegeViolation = ext_status.privilegeViolation;
pub const connectionFailure = ext_status.connectionFailure;
pub const connectionFailureCommit = ext_status.connectionFailureCommit;
