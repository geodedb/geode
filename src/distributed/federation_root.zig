const fed_flag = @import("federation_flag.zig");

pub fn consumeMismatchFlag() bool {
    if (fed_flag.g_last_federation_mismatch.load(.acquire)) {
        fed_flag.g_last_federation_mismatch.store(false, .release);
        return true;
    }
    return false;
}

pub fn mismatchFlag() bool {
    return fed_flag.g_last_federation_mismatch.load(.acquire);
}

// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FederationMismatchFlagEmission; OWNER=federation; UPDATED=2025-09-23
