// msquic C types for Zig
// Manual definitions to avoid @cImport issues with complex unions

const std = @import("std");

// ============================================================================
// Basic Types
// ============================================================================

pub const HQUIC = ?*opaque {};
pub const QUIC_STATUS = u32;

pub fn QUIC_SUCCEEDED(status: QUIC_STATUS) bool {
    return status == QUIC_STATUS_SUCCESS;
}

pub fn QUIC_FAILED(status: QUIC_STATUS) bool {
    // QUIC_STATUS_PENDING and ASYNC_PENDING are not failures - they mean async operation in progress
    return status != QUIC_STATUS_SUCCESS and status != QUIC_STATUS_PENDING and status != QUIC_STATUS_ASYNC_PENDING;
}

// ============================================================================
// Status Codes
// ============================================================================

pub const QUIC_STATUS_SUCCESS: u32 = 0;
pub const QUIC_STATUS_PENDING: u32 = 0xC0000103;
pub const QUIC_STATUS_ASYNC_PENDING: u32 = 0xFFFFFFFE; // Async operation in progress (Linux/POSIX)
pub const QUIC_STATUS_CONTINUE: u32 = 0xC0000104;
pub const QUIC_STATUS_OUT_OF_MEMORY: u32 = 0xC0000017;
pub const QUIC_STATUS_INVALID_PARAMETER: u32 = 0xC000000D;
pub const QUIC_STATUS_INVALID_STATE: u32 = 0xC0000003;
pub const QUIC_STATUS_NOT_SUPPORTED: u32 = 0xC00000BB;
pub const QUIC_STATUS_NOT_FOUND: u32 = 0xC0000225;
pub const QUIC_STATUS_BUFFER_TOO_SMALL: u32 = 0xC0000023;
pub const QUIC_STATUS_HANDSHAKE_FAILURE: u32 = 0xC000035C;
pub const QUIC_STATUS_ABORTED: u32 = 0xC0000011;
pub const QUIC_STATUS_ADDRESS_IN_USE: u32 = 0xC0000048;
pub const QUIC_STATUS_CONNECTION_TIMEOUT: u32 = 0xC000038A;
pub const QUIC_STATUS_CONNECTION_IDLE: u32 = 0xC000038B;
pub const QUIC_STATUS_INTERNAL_ERROR: u32 = 0xC00002E4;
pub const QUIC_STATUS_CONNECTION_REFUSED: u32 = 0xC0000236;
pub const QUIC_STATUS_PROTOCOL_ERROR: u32 = 0xC000038D;
pub const QUIC_STATUS_VER_NEG_ERROR: u32 = 0xC000038E;
pub const QUIC_STATUS_UNREACHABLE: u32 = 0xC000023C;
pub const QUIC_STATUS_TLS_ERROR: u32 = 0xC000038F;
pub const QUIC_STATUS_USER_CANCELED: u32 = 0xC0000390;
pub const QUIC_STATUS_ALPN_NEG_FAILURE: u32 = 0xC0000391;
pub const QUIC_STATUS_STREAM_LIMIT_REACHED: u32 = 0xC0000392;

// ============================================================================
// Connection Parameters
// ============================================================================

pub const QUIC_PARAM_CONN_LOCAL_BIDI_STREAM_COUNT: u32 = 0x05000008;
pub const QUIC_PARAM_CONN_LOCAL_UNIDI_STREAM_COUNT: u32 = 0x05000009;

// ============================================================================
// Enums
// ============================================================================

pub const QUIC_EXECUTION_PROFILE = enum(c_int) {
    QUIC_EXECUTION_PROFILE_LOW_LATENCY = 0,
    QUIC_EXECUTION_PROFILE_TYPE_MAX_THROUGHPUT = 1,
    QUIC_EXECUTION_PROFILE_TYPE_SCAVENGER = 2,
    QUIC_EXECUTION_PROFILE_TYPE_REAL_TIME = 3,
};

pub const QUIC_CREDENTIAL_TYPE = enum(c_int) {
    QUIC_CREDENTIAL_TYPE_NONE = 0,
    QUIC_CREDENTIAL_TYPE_CERTIFICATE_HASH = 1,
    QUIC_CREDENTIAL_TYPE_CERTIFICATE_HASH_STORE = 2,
    QUIC_CREDENTIAL_TYPE_CERTIFICATE_CONTEXT = 3,
    QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE = 4,
    QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE_PROTECTED = 5,
    QUIC_CREDENTIAL_TYPE_CERTIFICATE_PKCS12 = 6,
};

pub const QUIC_CREDENTIAL_FLAGS = packed struct(u32) {
    CLIENT: bool = false,                                // 0x00000001
    LOAD_ASYNCHRONOUS: bool = false,                     // 0x00000002
    NO_CERTIFICATE_VALIDATION: bool = false,             // 0x00000004
    ENABLE_OCSP: bool = false,                           // 0x00000008
    INDICATE_CERTIFICATE_RECEIVED: bool = false,         // 0x00000010
    DEFER_CERTIFICATE_VALIDATION: bool = false,          // 0x00000020
    REQUIRE_CLIENT_AUTHENTICATION: bool = false,         // 0x00000040
    USE_TLS_BUILTIN_CERTIFICATE_VALIDATION: bool = false,// 0x00000080
    REVOCATION_CHECK_END_CERT: bool = false,             // 0x00000100
    REVOCATION_CHECK_CHAIN: bool = false,                // 0x00000200
    REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT: bool = false,   // 0x00000400
    IGNORE_NO_REVOCATION_CHECK: bool = false,            // 0x00000800
    IGNORE_REVOCATION_OFFLINE: bool = false,             // 0x00001000
    SET_ALLOWED_CIPHER_SUITES: bool = false,             // 0x00002000
    USE_PORTABLE_CERTIFICATES: bool = false,             // 0x00004000
    USE_SUPPLIED_CREDENTIALS: bool = false,              // 0x00008000
    USE_SYSTEM_MAPPER: bool = false,                     // 0x00010000
    CACHE_ONLY_URL_RETRIEVAL: bool = false,              // 0x00020000
    REVOCATION_CHECK_CACHE_ONLY: bool = false,           // 0x00040000
    INPROC_PEER_CERTIFICATE: bool = false,               // 0x00080000
    SET_CA_CERTIFICATE_FILE: bool = false,               // 0x00100000
    DISABLE_AIA: bool = false,                           // 0x00200000
    _padding: u10 = 0,
};

pub const QUIC_LISTENER_EVENT_TYPE = enum(c_int) {
    QUIC_LISTENER_EVENT_NEW_CONNECTION = 0,
    QUIC_LISTENER_EVENT_STOP_COMPLETE = 1,
    QUIC_LISTENER_EVENT_DOS_MODE_CHANGED = 2,
};

pub const QUIC_CONNECTION_EVENT_TYPE = enum(c_int) {
    QUIC_CONNECTION_EVENT_CONNECTED = 0,
    QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT = 1,
    QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER = 2,
    QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE = 3,
    QUIC_CONNECTION_EVENT_LOCAL_ADDRESS_CHANGED = 4,
    QUIC_CONNECTION_EVENT_PEER_ADDRESS_CHANGED = 5,
    QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED = 6,
    QUIC_CONNECTION_EVENT_STREAMS_AVAILABLE = 7,
    QUIC_CONNECTION_EVENT_PEER_NEEDS_STREAMS = 8,
    QUIC_CONNECTION_EVENT_IDEAL_PROCESSOR_CHANGED = 9,
    QUIC_CONNECTION_EVENT_DATAGRAM_STATE_CHANGED = 10,
    QUIC_CONNECTION_EVENT_DATAGRAM_RECEIVED = 11,
    QUIC_CONNECTION_EVENT_DATAGRAM_SEND_STATE_CHANGED = 12,
    QUIC_CONNECTION_EVENT_RESUMED = 13,
    QUIC_CONNECTION_EVENT_RESUMPTION_TICKET_RECEIVED = 14,
    QUIC_CONNECTION_EVENT_PEER_CERTIFICATE_RECEIVED = 15,
};

pub const QUIC_STREAM_EVENT_TYPE = enum(c_int) {
    QUIC_STREAM_EVENT_START_COMPLETE = 0,
    QUIC_STREAM_EVENT_RECEIVE = 1,
    QUIC_STREAM_EVENT_SEND_COMPLETE = 2,
    QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN = 3,
    QUIC_STREAM_EVENT_PEER_SEND_ABORTED = 4,
    QUIC_STREAM_EVENT_PEER_RECEIVE_ABORTED = 5,
    QUIC_STREAM_EVENT_SEND_SHUTDOWN_COMPLETE = 6,
    QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE = 7,
    QUIC_STREAM_EVENT_IDEAL_SEND_BUFFER_SIZE = 8,
    QUIC_STREAM_EVENT_PEER_ACCEPTED = 9,
    QUIC_STREAM_EVENT_CANCEL_ON_LOSS = 10,
};

pub const QUIC_SEND_FLAGS = packed struct(u32) {
    NONE: bool = false,
    ALLOW_0_RTT: bool = false,
    START: bool = false,
    FIN: bool = false,
    DGRAM_PRIORITY: bool = false,
    DELAY_SEND: bool = false,
    CANCEL_ON_LOSS: bool = false,
    _padding: u25 = 0,
};

pub const QUIC_SEND_FLAG_NONE: u32 = 0;
pub const QUIC_SEND_FLAG_ALLOW_0_RTT: u32 = 1;
pub const QUIC_SEND_FLAG_START: u32 = 2;
pub const QUIC_SEND_FLAG_FIN: u32 = 4;

pub const QUIC_STREAM_OPEN_FLAGS = packed struct(u32) {
    NONE: bool = false,
    UNIDIRECTIONAL: bool = false,
    ZERO_RTT: bool = false,
    DELAY_ID_FC_UPDATES: bool = false,
    _padding: u28 = 0,
};

pub const QUIC_STREAM_OPEN_FLAG_NONE: u32 = 0;
pub const QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL: u32 = 1;
pub const QUIC_STREAM_OPEN_FLAG_0_RTT: u32 = 2;

pub const QUIC_STREAM_START_FLAGS = packed struct(u32) {
    NONE: bool = false,
    IMMEDIATE: bool = false,
    FAIL_BLOCKED: bool = false,
    SHUTDOWN_ON_FAIL: bool = false,
    INDICATE_PEER_ACCEPT: bool = false,
    _padding: u27 = 0,
};

pub const QUIC_STREAM_START_FLAG_NONE: u32 = 0;
pub const QUIC_STREAM_START_FLAG_IMMEDIATE: u32 = 1;
pub const QUIC_STREAM_START_FLAG_FAIL_BLOCKED: u32 = 2;

pub const QUIC_STREAM_SHUTDOWN_FLAGS = packed struct(u32) {
    NONE: bool = false,
    GRACEFUL: bool = false,
    ABORT_SEND: bool = false,
    ABORT_RECEIVE: bool = false,
    ABORT: bool = false,
    IMMEDIATE: bool = false,
    _padding: u26 = 0,
};

pub const QUIC_STREAM_SHUTDOWN_FLAG_NONE: u32 = 0;
pub const QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL: u32 = 1;
pub const QUIC_STREAM_SHUTDOWN_FLAG_ABORT_SEND: u32 = 2;
pub const QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE: u32 = 4;
pub const QUIC_STREAM_SHUTDOWN_FLAG_ABORT: u32 = 6;

// ============================================================================
// Structures
// ============================================================================

pub const QUIC_BUFFER = extern struct {
    Length: u32,
    Buffer: [*]u8,
};

pub const QUIC_REGISTRATION_CONFIG = extern struct {
    AppName: [*:0]const u8,
    ExecutionProfile: QUIC_EXECUTION_PROFILE,
};

pub const QUIC_CERTIFICATE_FILE = extern struct {
    PrivateKeyFile: [*:0]const u8,
    CertificateFile: [*:0]const u8,
};

pub const QUIC_CERTIFICATE_FILE_PROTECTED = extern struct {
    PrivateKeyFile: [*:0]const u8,
    CertificateFile: [*:0]const u8,
    PrivateKeyPassword: [*:0]const u8,
};

pub const QUIC_CREDENTIAL_CONFIG_UNION = extern union {
    CertificateHash: ?*anyopaque,
    CertificateHashStore: ?*anyopaque,
    CertificateContext: ?*anyopaque,
    CertificateFile: *QUIC_CERTIFICATE_FILE,
    CertificateFileProtected: *QUIC_CERTIFICATE_FILE_PROTECTED,
    CertificatePkcs12: ?*anyopaque,
};

pub const QUIC_CREDENTIAL_CONFIG = extern struct {
    Type: QUIC_CREDENTIAL_TYPE,
    Flags: u32, // Use u32 for compatibility
    Certificate: QUIC_CREDENTIAL_CONFIG_UNION,
    Principal: [*:0]const u8,
    Reserved: ?*anyopaque,
    AsyncHandler: ?*anyopaque,
    AllowedCipherSuites: u32,
    CaCertificateFile: [*:0]const u8,
};

// Settings structure - matches C layout exactly
// Note: IsSet is a bitfield union, we use a u64 to manipulate bits
pub const QUIC_SETTINGS = extern struct {
    // IsSet flags (64-bit bitfield)
    IsSetFlags: u64,
    
    // Actual settings values
    MaxBytesPerKey: u64,
    HandshakeIdleTimeoutMs: u64,
    IdleTimeoutMs: u64,
    MtuDiscoverySearchCompleteTimeoutUs: u64,
    TlsClientMaxSendBuffer: u32,
    TlsServerMaxSendBuffer: u32,
    StreamRecvWindowDefault: u32,
    StreamRecvBufferDefault: u32,
    ConnFlowControlWindow: u32,
    MaxWorkerQueueDelayUs: u32,
    MaxStatelessOperations: u32,
    InitialWindowPackets: u32,
    SendIdleTimeoutMs: u32,
    InitialRttMs: u32,
    MaxAckDelayMs: u32,
    DisconnectTimeoutMs: u32,
    KeepAliveIntervalMs: u32,
    CongestionControlAlgorithm: u16,
    PeerBidiStreamCount: u16,
    PeerUnidiStreamCount: u16,
    MaxBindingStatelessOperations: u16,
    StatelessOperationExpirationMs: u16,
    MinimumMtu: u16,
    MaximumMtu: u16,
    SendBufferingEnabled: u8,
    PacingEnabled: u8,
    MigrationEnabled: u8,
    DatagramReceiveEnabled: u8,
    ServerResumptionLevel: u8,
    GreaseQuicBitEnabled: u8,
    EcnEnabled: u8,
    MaxOperationsPerDrain: u8,
    MtuDiscoveryMissingProbeCount: u8,
    DestCidUpdateIdleTimeoutMs: u32,
    Flags: u64, // Additional flags
};

// Bit positions for IsSetFlags
pub const QUIC_SETTINGS_IsSet_IdleTimeoutMs: u64 = 1 << 2;
pub const QUIC_SETTINGS_IsSet_PeerBidiStreamCount: u64 = 1 << 18;
pub const QUIC_SETTINGS_IsSet_PeerUnidiStreamCount: u64 = 1 << 19;

// Address family
pub const QUIC_ADDRESS_FAMILY = enum(c_int) {
    QUIC_ADDRESS_FAMILY_UNSPEC = 0,
    QUIC_ADDRESS_FAMILY_INET = 2,
    QUIC_ADDRESS_FAMILY_INET6 = 23,
};

// Simple address structure
pub const QUIC_ADDR = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: [16]u8, // Enough for IPv6
};
