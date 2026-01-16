const federation = @import("federation.zig");

pub fn consumeMismatchFlag() bool {
    if (federation.g_last_federation_mismatch) {
        federation.g_last_federation_mismatch = false;
        return true;
    }
    return false;
}

pub fn mismatchFlag() bool {
    return federation.g_last_federation_mismatch;
}

// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FederationMismatchFlagEmission; OWNER=federation; UPDATED=2025-09-23
