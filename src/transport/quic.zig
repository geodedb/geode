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
const quic_msquic = @import("quic_msquic.zig");

pub const QuicError = quic_msquic.QuicError;
pub const QuicTransport = quic_msquic.QuicTransport;
pub const QuicConnection = quic_msquic.QuicConnection;
pub const QuicStream = quic_msquic.QuicStream;
pub const QuicClient = quic_msquic.QuicClient;
pub const QuicClientStream = quic_msquic.QuicClientStream;
