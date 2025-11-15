const std = @import("std");

// MSQUIC MIGRATION COMPLETE - 2025-11-14
// This module now re-exports the msquic-based QUIC implementation
// The vendor QUIC implementation has been replaced with Microsoft MsQuic for:
// - Better security (active maintenance, CVE monitoring)
// - RFC 9000 compliance
// - Production-grade performance
// - Reduced maintenance burden

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICCore; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICCore; OWNER=wire; UPDATED=2025-11-14

// Re-export everything from the msquic implementation
pub usingnamespace @import("quic_msquic.zig");
