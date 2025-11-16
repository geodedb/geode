const std = @import("std");
const builtin = @import("builtin");
const types = @import("msquic_types.zig");

// MsQuic C API wrapper for Zig
// Provides a clean interface to Microsoft's msquic library

// Re-export types
pub const HQUIC = types.HQUIC;
pub const QUIC_STATUS = types.QUIC_STATUS;
pub const QUIC_BUFFER = types.QUIC_BUFFER;
pub const QUIC_SETTINGS = types.QUIC_SETTINGS;
pub const QUIC_REGISTRATION_CONFIG = types.QUIC_REGISTRATION_CONFIG;
pub const QUIC_CREDENTIAL_CONFIG = types.QUIC_CREDENTIAL_CONFIG;
pub const QUIC_CERTIFICATE_FILE = types.QUIC_CERTIFICATE_FILE;
pub const QUIC_CREDENTIAL_TYPE = types.QUIC_CREDENTIAL_TYPE;
pub const QUIC_ADDR = types.QUIC_ADDR;
pub const QUIC_LISTENER_EVENT_TYPE = types.QUIC_LISTENER_EVENT_TYPE;
pub const QUIC_CONNECTION_EVENT_TYPE = types.QUIC_CONNECTION_EVENT_TYPE;
pub const QUIC_STREAM_EVENT_TYPE = types.QUIC_STREAM_EVENT_TYPE;

// Re-export status codes
pub const QUIC_STATUS_SUCCESS = types.QUIC_STATUS_SUCCESS;
pub const QUIC_STATUS_PENDING = types.QUIC_STATUS_PENDING;
pub const QUIC_STATUS_ASYNC_PENDING = types.QUIC_STATUS_ASYNC_PENDING;

pub const QuicError = error{
    ConnectionFailed,
    StreamFailed,
    InvalidAddress,
    CertificateError,
    EndpointInitFailed,
    AcceptFailed,
    HandshakeFailed,
    TransportParametersFailed,
    FlowControlViolation,
    ProtocolViolation,
    IdleTimeout,
    ConnectionClosed,
    InitFailed,
    OpenFailed,
    StartFailed,
    ListenerStartFailed,
    ConfigurationLoadFailed,
    RegistrationFailed,
    WouldBlock,
};

// External function declarations
extern fn MsQuicOpenVersion(version: u32, api_table: *?*const anyopaque) QUIC_STATUS;
extern fn MsQuicClose(api_table: *const anyopaque) void;

pub fn QUIC_FAILED(status: QUIC_STATUS) bool {
    // Success (0x00000000), Pending (0xC0000103), and Async Pending (0xFFFFFFFE) are not failures
    return status != QUIC_STATUS_SUCCESS and status != QUIC_STATUS_PENDING and status != QUIC_STATUS_ASYNC_PENDING;
}
pub fn QUIC_SUCCEEDED(status: QUIC_STATUS) bool {
    return status == QUIC_STATUS_SUCCESS;
}

// API function pointer types
pub const RegistrationOpenFn = *const fn (
    config: *const QUIC_REGISTRATION_CONFIG,
    registration: *HQUIC,
) callconv(.c) QUIC_STATUS;

pub const RegistrationCloseFn = *const fn (registration: HQUIC) callconv(.c) void;

pub const ConfigurationOpenFn = *const fn (
    registration: HQUIC,
    alpn_buffers: [*]const QUIC_BUFFER,
    alpn_buffer_count: u32,
    settings: ?*const QUIC_SETTINGS,
    settings_size: u32,
    context: ?*anyopaque,
    configuration: *HQUIC,
) callconv(.c) QUIC_STATUS;

pub const ConfigurationCloseFn = *const fn (configuration: HQUIC) callconv(.c) void;

pub const ConfigurationLoadCredentialFn = *const fn (
    configuration: HQUIC,
    credential_config: *const QUIC_CREDENTIAL_CONFIG,
) callconv(.c) QUIC_STATUS;

pub const ListenerCallbackFn = *const fn (
    listener: HQUIC,
    context: ?*anyopaque,
    event: *const anyopaque,
) callconv(.c) QUIC_STATUS;

pub const ListenerOpenFn = *const fn (
    registration: HQUIC,
    handler: ListenerCallbackFn,
    context: ?*anyopaque,
    listener: *HQUIC,
) callconv(.c) QUIC_STATUS;

pub const ListenerCloseFn = *const fn (listener: HQUIC) callconv(.c) void;

pub const ListenerStartFn = *const fn (
    listener: HQUIC,
    alpn_buffers: [*]const QUIC_BUFFER,
    alpn_buffer_count: u32,
    local_address: ?*const QUIC_ADDR,
) callconv(.c) QUIC_STATUS;

pub const ListenerStopFn = *const fn (listener: HQUIC) callconv(.c) void;

pub const ConnectionCallbackFn = *const fn (
    connection: HQUIC,
    context: ?*anyopaque,
    event: *const anyopaque,
) callconv(.c) QUIC_STATUS;

pub const ConnectionOpenFn = *const fn (
    registration: HQUIC,
    handler: ConnectionCallbackFn,
    context: ?*anyopaque,
    connection: *HQUIC,
) callconv(.c) QUIC_STATUS;

pub const ConnectionCloseFn = *const fn (connection: HQUIC) callconv(.c) void;

pub const ConnectionSetConfigurationFn = *const fn (
    connection: HQUIC,
    configuration: HQUIC,
) callconv(.c) QUIC_STATUS;

pub const StreamCallbackFn = *const fn (
    stream: HQUIC,
    context: ?*anyopaque,
    event: *const anyopaque,
) callconv(.c) QUIC_STATUS;

pub const StreamOpenFn = *const fn (
    connection: HQUIC,
    flags: u32,
    handler: StreamCallbackFn,
    context: ?*anyopaque,
    stream: *HQUIC,
) callconv(.c) QUIC_STATUS;

pub const StreamCloseFn = *const fn (stream: HQUIC) callconv(.c) void;

pub const StreamStartFn = *const fn (
    stream: HQUIC,
    flags: u32,
) callconv(.c) QUIC_STATUS;

pub const StreamSendFn = *const fn (
    stream: HQUIC,
    buffers: [*]const QUIC_BUFFER,
    buffer_count: u32,
    flags: u32,
    client_send_context: ?*anyopaque,
) callconv(.c) QUIC_STATUS;

pub const StreamReceiveCompleteFn = *const fn (
    stream: HQUIC,
    length: u64,
) callconv(.c) void;

pub const StreamReceiveSetEnabledFn = *const fn (
    stream: HQUIC,
    is_enabled: u8,
) callconv(.c) QUIC_STATUS;

pub const ConnectionStartFn = *const fn (
    connection: HQUIC,
    configuration: HQUIC, // ← WE WERE MISSING THIS!
    family: u16, // AF_INET = 2, AF_INET6 = 23
    server_name: [*:0]const u8,
    server_port: u16,
) callconv(.c) QUIC_STATUS;

pub const SetCallbackHandlerFn = *const fn (
    handle: HQUIC,
    handler: *const anyopaque,
    context: ?*anyopaque,
) callconv(.c) void;

pub const SetParamFn = *const fn (
    handle: HQUIC,
    param: u32,
    buffer_length: u32,
    buffer: *const anyopaque,
) callconv(.c) QUIC_STATUS;

// API Table structure
pub const QUIC_API_TABLE = extern struct {
    SetContext: ?*anyopaque,
    GetContext: ?*anyopaque,
    SetCallbackHandler: SetCallbackHandlerFn,
    
    SetParam: SetParamFn,
    GetParam: ?*anyopaque,
    
    RegistrationOpen: RegistrationOpenFn,
    RegistrationClose: RegistrationCloseFn,
    RegistrationShutdown: ?*anyopaque,
    
    ConfigurationOpen: ConfigurationOpenFn,
    ConfigurationClose: ConfigurationCloseFn,
    ConfigurationLoadCredential: ConfigurationLoadCredentialFn,
    
    ListenerOpen: ListenerOpenFn,
    ListenerClose: ListenerCloseFn,
    ListenerStart: ListenerStartFn,
    ListenerStop: ListenerStopFn,
    
    ConnectionOpen: ConnectionOpenFn,
    ConnectionClose: ConnectionCloseFn,
    ConnectionShutdown: ?*anyopaque,
    ConnectionStart: ConnectionStartFn,
    ConnectionSetConfiguration: ConnectionSetConfigurationFn,
    ConnectionSendResumptionTicket: ?*anyopaque,
    
    StreamOpen: StreamOpenFn,
    StreamClose: StreamCloseFn,
    StreamStart: StreamStartFn,
    StreamShutdown: ?*anyopaque,
    StreamSend: StreamSendFn,
    StreamReceiveComplete: StreamReceiveCompleteFn,
    StreamReceiveSetEnabled: StreamReceiveSetEnabledFn,
    
    // Additional functions exist but not all are needed initially
    DatagramSend: ?*anyopaque,
    ConnectionResolvePeerAddress: ?*anyopaque,
    
    // Padding for remaining API table entries
    _padding: [32]*anyopaque = undefined,
};

// Listener context for callbacks
pub const ListenerContext = struct {
    allocator: std.mem.Allocator,
    pending_connections: std.ArrayList(PendingConnection),
    mutex: std.Thread.Mutex = .{},
    api: *const QUIC_API_TABLE,
    configuration: HQUIC,

    pub const PendingConnection = struct {
        handle: HQUIC,
        context: *ConnectionContext,
    };

    pub fn init(allocator: std.mem.Allocator, api: *const QUIC_API_TABLE, configuration: HQUIC) !*ListenerContext {
        const ctx = try allocator.create(ListenerContext);
        ctx.* = .{
            .allocator = allocator,
            .pending_connections = try std.ArrayList(PendingConnection).initCapacity(allocator, 0),
            .mutex = .{},
            .api = api,
            .configuration = configuration,
        };
        return ctx;
    }

    pub fn deinit(self: *ListenerContext) void {
        self.pending_connections.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// Connection context
pub const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    pending_streams: std.ArrayList(PendingStream),
    mutex: std.Thread.Mutex = .{},
    connected: bool = false,
    api: ?*const QUIC_API_TABLE,
    connection: ?HQUIC,

    pub const PendingStream = struct {
        handle: HQUIC,
        context: *StreamContext,
    };

    pub fn init(allocator: std.mem.Allocator, api: ?*const QUIC_API_TABLE, connection: ?HQUIC) !*ConnectionContext {
        const ctx = try allocator.create(ConnectionContext);
        ctx.* = .{
            .allocator = allocator,
            .pending_streams = try std.ArrayList(PendingStream).initCapacity(allocator, 0),
            .mutex = .{},
            .connected = false,
            .api = api,
            .connection = connection,
        };
        return ctx;
    }

    pub fn deinit(self: *ConnectionContext) void {
        // Clean up any remaining pending streams
        for (self.pending_streams.items) |pending| {
            pending.context.deinit();
        }
        self.pending_streams.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// Stream context
pub const StreamContext = struct {
    allocator: std.mem.Allocator,
    recv_buffer: std.ArrayList(u8),
    send_buffers: std.ArrayList([]u8),
    send_buffer_structs: std.ArrayList(*QUIC_BUFFER),
    mutex: std.Thread.Mutex = .{},
    recv_complete: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*StreamContext {
        const ctx = try allocator.create(StreamContext);
        ctx.* = .{
            .allocator = allocator,
            .recv_buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
            .send_buffers = try std.ArrayList([]u8).initCapacity(allocator, 0),
            .send_buffer_structs = try std.ArrayList(*QUIC_BUFFER).initCapacity(allocator, 0),
            .mutex = .{},
            .recv_complete = false,
        };
        return ctx;
    }

    pub fn deinit(self: *StreamContext) void {
        self.recv_buffer.deinit(self.allocator);
        // Free any remaining send buffers
        for (self.send_buffers.items) |buf| {
            self.allocator.free(buf);
        }
        self.send_buffers.deinit(self.allocator);
        // Free any remaining buffer structs
        for (self.send_buffer_structs.items) |buf_struct| {
            self.allocator.destroy(buf_struct);
        }
        self.send_buffer_structs.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// Callback functions
pub fn listenerCallback(
    listener: HQUIC,
    context: ?*anyopaque,
    event_ptr: *const anyopaque,
) callconv(.c) QUIC_STATUS {
    _ = listener;
    
    const ctx: *ListenerContext = @ptrCast(@alignCast(context.?));
    
    // Event structure has Type field first (4 bytes for c_int), then union
    const event_type_ptr: *const c_int = @ptrCast(@alignCast(event_ptr));
    const event_type_int = event_type_ptr.*;
    const event_type: QUIC_LISTENER_EVENT_TYPE = @enumFromInt(event_type_int);
    
    std.debug.print("[LISTENER_CALLBACK] Event type: {}\n", .{event_type});

    switch (event_type) {
        .QUIC_LISTENER_EVENT_NEW_CONNECTION => {
            // Event structure:
            // Type (4 bytes c_int) + padding (4 bytes for alignment)
            // Info pointer (8 bytes) + Connection handle (8 bytes)
            // Total offset to Connection: 8 (Type+padding) + 8 (Info) = 16
            const event_bytes: [*]const u8 = @ptrCast(event_ptr);
            const conn_ptr: *const HQUIC = @ptrCast(@alignCast(event_bytes + 16));
            const connection = conn_ptr.*;

            std.debug.print("[LISTENER_CALLBACK] NEW_CONNECTION: handle={*}\n", .{connection});
            
            // Configure connection immediately in callback (required by msquic)
            // 1. Create connection context
            const conn_ctx = ConnectionContext.init(ctx.allocator, ctx.api, connection) catch {
                // DEBUG: std.debug.print("[LISTENER_CALLBACK] Failed to create connection context\n", .{});
                return types.QUIC_STATUS_OUT_OF_MEMORY;
            };
            
            // 2. Set connection callback handler
            ctx.api.SetCallbackHandler(
                connection,
                @ptrCast(&connectionCallback),
                conn_ctx,
            );
            
            // DEBUG: std.debug.print("[LISTENER_CALLBACK] Set connection callback\n", .{});
            
            // 3. Set configuration on connection
            const set_cfg_status = ctx.api.ConnectionSetConfiguration(
                connection,
                ctx.configuration,
            );
            
            // DEBUG: std.debug.print("[LISTENER_CALLBACK] ConnectionSetConfiguration status={}\n", .{set_cfg_status});
            
            if (QUIC_FAILED(set_cfg_status)) {
                // DEBUG: std.debug.print("[LISTENER_CALLBACK] ConnectionSetConfiguration failed: {}\n", .{set_cfg_status});
                conn_ctx.deinit();
                return set_cfg_status;
            }
            
            // 4. Add to pending queue for accept() to retrieve
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            std.debug.print("[LISTENER_CALLBACK] Pre-append: ListenerContext={*}, queue len={}, capacity={}\n", .{ctx, ctx.pending_connections.items.len, ctx.pending_connections.capacity});
            const pending = ListenerContext.PendingConnection{
                .handle = connection,
                .context = conn_ctx,
            };
            const append_result = ctx.pending_connections.append(ctx.allocator, pending);
            if (append_result) |_| {
                std.debug.print("[LISTENER_CALLBACK] ✅ Append SUCCESS: queue len={}, capacity={}\n", .{ctx.pending_connections.items.len, ctx.pending_connections.capacity});
            } else |err| {
                std.debug.print("[LISTENER_CALLBACK] ❌ Append FAILED: error={}\n", .{err});
            }
            std.debug.print("[LISTENER_CALLBACK] Post-append: Connection configured and queued, count={}\n", .{ctx.pending_connections.items.len});
            
            return QUIC_STATUS_SUCCESS;
        },
        .QUIC_LISTENER_EVENT_STOP_COMPLETE => {
            // DEBUG: std.debug.print("[LISTENER_CALLBACK] STOP_COMPLETE\n", .{});
            return QUIC_STATUS_SUCCESS;
        },
        else => {
            // DEBUG: std.debug.print("[LISTENER_CALLBACK] Unhandled event type: {}\n", .{event_type});
            return QUIC_STATUS_SUCCESS;
        },
    }
}

pub fn connectionCallback(
    connection: HQUIC,
    context: ?*anyopaque,
    event_ptr: *const anyopaque,
) callconv(.c) QUIC_STATUS {
    _ = connection;
    
    // DEBUG: std.debug.print("[CALLBACK] connectionCallback INVOKED!\n", .{});

    const ctx: *ConnectionContext = @ptrCast(@alignCast(context.?));

    // Event structure has Type field first (4 bytes for c_int), then union
    const event_type_ptr: *const c_int = @ptrCast(@alignCast(event_ptr));
    const event_type_int = event_type_ptr.*;
    const event_type: QUIC_CONNECTION_EVENT_TYPE = @enumFromInt(event_type_int);

    // DEBUG: std.debug.print("[CALLBACK] Event type: {}\n", .{event_type});

    switch (event_type) {
        .QUIC_CONNECTION_EVENT_CONNECTED => {
            // DEBUG: std.debug.print("[CALLBACK] ✅ CONNECTED event!\n", .{});
            ctx.mutex.lock();
            ctx.connected = true;
            ctx.mutex.unlock();
            
            // Note: PeerBidiStreamCount is already set in the configuration (100 streams)
            // No need to call SetParam here - configuration settings are sufficient
            
            return QUIC_STATUS_SUCCESS;
        },
        .QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED => {
            // Stream handle is in union after Type field (offset 8 for alignment)
            const event_bytes: [*]const u8 = @ptrCast(event_ptr);
            const stream_ptr: *const HQUIC = @ptrCast(@alignCast(event_bytes + 8));
            const stream = stream_ptr.*;
            
            // DEBUG: std.debug.print("[CALLBACK] ⭐ PEER_STREAM_STARTED: stream handle={*}\n", .{stream});
            
            // Create stream context immediately and set callback
            // This prevents crashes if data arrives before acceptStream() is called
            const stream_ctx = StreamContext.init(ctx.allocator) catch {
                // DEBUG: std.debug.print("[CALLBACK] Failed to create stream context\n", .{});
                return types.QUIC_STATUS_OUT_OF_MEMORY;
            };
            
            // Set stream callback immediately
            if (ctx.api) |api| {
                api.SetCallbackHandler(
                    stream,
                    @ptrCast(&streamCallback),
                    stream_ctx,
                );
                // DEBUG: std.debug.print("[CALLBACK] Stream callback set\n", .{});
            }
            
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            
            const pending = ConnectionContext.PendingStream{
                .handle = stream,
                .context = stream_ctx,
            };
            ctx.pending_streams.append(ctx.allocator, pending) catch {};
            
            // DEBUG: std.debug.print("[CALLBACK] ⭐ Stream queued for accept, count={}\n", .{ctx.pending_streams.items.len});
            
            return QUIC_STATUS_SUCCESS;
        },
        .QUIC_CONNECTION_EVENT_STREAMS_AVAILABLE => {
            // DEBUG: std.debug.print("[CALLBACK] STREAMS_AVAILABLE event (informational)\n", .{});
            return QUIC_STATUS_SUCCESS;
        },
        .QUIC_CONNECTION_EVENT_PEER_NEEDS_STREAMS => {
            // DEBUG: std.debug.print("[CALLBACK] PEER_NEEDS_STREAMS event (peer wants more streams)\n", .{});
            // This is informational - peer wants to open streams but may be blocked
            // According to MsQuic docs, we should ensure our settings allow streams
            return QUIC_STATUS_SUCCESS;
        },
        .QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE => {
            // DEBUG: std.debug.print("[CALLBACK] SHUTDOWN_COMPLETE event\n", .{});
            return QUIC_STATUS_SUCCESS;
        },
        .QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT,
        .QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER => {
            // DEBUG: std.debug.print("[CALLBACK] SHUTDOWN_INITIATED event\n", .{});
            return QUIC_STATUS_SUCCESS;
        },
        else => {
            // DEBUG: std.debug.print("[CALLBACK] Unhandled event type: {}\n", .{event_type});
            return QUIC_STATUS_SUCCESS;
        },
    }
}

pub fn streamCallback(
    stream: HQUIC,
    context: ?*anyopaque,
    event_ptr: *const anyopaque,
) callconv(.c) QUIC_STATUS {
    _ = stream;
    
    const ctx: *StreamContext = @ptrCast(@alignCast(context.?));
    
    // Event structure has Type field first (4 bytes for c_int), then union
    const event_type_ptr: *const c_int = @ptrCast(@alignCast(event_ptr));
    const event_type_int = event_type_ptr.*;
    const event_type: QUIC_STREAM_EVENT_TYPE = @enumFromInt(event_type_int);
    
    // DEBUG: std.debug.print("[STREAM_CALLBACK] Event type: {}\n", .{event_type});
    
    switch (event_type) {
        .QUIC_STREAM_EVENT_RECEIVE => {
            // RECEIVE event structure:
            // - c_int Type (4 bytes)
            // - padding to 8-byte boundary (4 bytes)
            // - union RECEIVE {
            //     uint64_t AbsoluteOffset;      // offset 8
            //     uint64_t TotalBufferLength;   // offset 16
            //     const QUIC_BUFFER* Buffers;   // offset 24
            //     uint32_t BufferCount;         // offset 32
            //     QUIC_RECEIVE_FLAGS Flags;     // offset 36
            //   }
            const event_bytes: [*]const u8 = @ptrCast(event_ptr);
            
            // Skip Type (4 bytes) + padding (4 bytes) + AbsoluteOffset (8 bytes) + TotalBufferLength (8 bytes) = 24 bytes
            // Buffers pointer at offset 24
            const buffers_ptr_ptr: *const ?[*]const QUIC_BUFFER = @ptrCast(@alignCast(event_bytes + 24));
            const buffers_opt = buffers_ptr_ptr.*;
            
            // BufferCount at offset 32 (24 + 8 for pointer)
            const buffer_count_ptr: *const u32 = @ptrCast(@alignCast(event_bytes + 32));
            const buffer_count = buffer_count_ptr.*;
            
            // DEBUG: std.debug.print("[STREAM_CALLBACK] RECEIVE: buffer_count={}\n", .{buffer_count});
            
            if (buffer_count == 0 or buffers_opt == null) {
                // DEBUG: std.debug.print("[STREAM_CALLBACK] No buffers to process\n", .{});
                return QUIC_STATUS_SUCCESS;
            }
            
            const buffers = buffers_opt.?;
            
            // Copy all buffers to receive buffer
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            
            var i: u32 = 0;
            while (i < buffer_count) : (i += 1) {
                const buf = buffers[i];
                // DEBUG: std.debug.print("[STREAM_CALLBACK] Buffer[{}]: length={}\n", .{i, buf.Length});
                
                // Append to receive buffer
                ctx.recv_buffer.appendSlice(ctx.allocator, buf.Buffer[0..buf.Length]) catch {
                    // DEBUG: std.debug.print("[STREAM_CALLBACK] Failed to append to recv buffer\n", .{});
                    return types.QUIC_STATUS_OUT_OF_MEMORY;
                };
            }
            
            // DEBUG: std.debug.print("[STREAM_CALLBACK] Total recv buffer size: {}\n", .{ctx.recv_buffer.items.len});
            return QUIC_STATUS_SUCCESS;
        },
        .QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN => {
            // DEBUG: std.debug.print("[STREAM_CALLBACK] PEER_SEND_SHUTDOWN\n", .{});
            ctx.mutex.lock();
            ctx.recv_complete = true;
            ctx.mutex.unlock();
            return QUIC_STATUS_SUCCESS;
        },
        .QUIC_STREAM_EVENT_START_COMPLETE,
        .QUIC_STREAM_EVENT_SEND_COMPLETE,
        .QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE => {
            // DEBUG: std.debug.print("[STREAM_CALLBACK] Event: {}\n", .{event_type});
            
            // Free the specific send buffer on SEND_COMPLETE
            // SEND_COMPLETE event structure has ClientContext at offset 8+4 (after Type + padding + Canceled bool)
            if (event_type == .QUIC_STREAM_EVENT_SEND_COMPLETE) {
                const event_bytes: [*]const u8 = @ptrCast(event_ptr);
                // Skip Type (4) + padding (4) + Canceled (1) + padding to alignment = 16 bytes
                const context_ptr_ptr: *const ?*anyopaque = @ptrCast(@alignCast(event_bytes + 16));
                const send_context_opt = context_ptr_ptr.*;
                
                if (send_context_opt) |send_ctx| {
                    const buffer_ptr: [*]u8 = @ptrCast(@alignCast(send_ctx));
                    
                    ctx.mutex.lock();
                    defer ctx.mutex.unlock();
                    
                    // Find and remove the buffer with this pointer
                    for (ctx.send_buffers.items, 0..) |buf, i| {
                        if (buf.ptr == buffer_ptr) {
                            _ = ctx.send_buffers.swapRemove(i);
                            const buf_struct = ctx.send_buffer_structs.swapRemove(i);
                            ctx.allocator.free(buf);
                            ctx.allocator.destroy(buf_struct);
                            // DEBUG: std.debug.print("[STREAM_CALLBACK] Freed send buffer, {} remaining\n", .{ctx.send_buffers.items.len});
                            break;
                        }
                    }
                }
            }
            
            return QUIC_STATUS_SUCCESS;
        },
        else => {
            // DEBUG: std.debug.print("[STREAM_CALLBACK] Unhandled event type: {}\n", .{event_type});
            return QUIC_STATUS_SUCCESS;
        },
    }
}

// Main MsQuic wrapper
pub const MsQuic = struct {
    api: *const QUIC_API_TABLE,
    registration: HQUIC = null,
    configuration: HQUIC = null,
    listener: HQUIC = null,
    listener_ctx: ?*ListenerContext = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*MsQuic {
        const self = try allocator.create(MsQuic);
        errdefer allocator.destroy(self);

        // Open MsQuic API (version 2)
        var api_table: ?*const anyopaque = null;
        const status = MsQuicOpenVersion(2, &api_table);
        if (QUIC_FAILED(status) or api_table == null) {
            std.debug.print("MsQuicOpenVersion failed: status={}\n", .{status});
            return QuicError.InitFailed;
        }

        // Cast to QUIC_API_TABLE
        const api: *const QUIC_API_TABLE = @ptrCast(@alignCast(api_table.?));

        self.* = .{
            .api = api,
            .allocator = allocator,
        };

        // Create registration
        const reg_config = QUIC_REGISTRATION_CONFIG{
            .AppName = "geode",
            .ExecutionProfile = .QUIC_EXECUTION_PROFILE_LOW_LATENCY,
        };

        const reg_status = self.api.RegistrationOpen(&reg_config, &self.registration);
        if (QUIC_FAILED(reg_status)) {
            std.debug.print("RegistrationOpen failed: status={}\n", .{reg_status});
            MsQuicClose(api_table.?);
            return QuicError.RegistrationFailed;
        }

        return self;
    }

    pub fn deinit(self: *MsQuic) void {
        if (self.listener_ctx) |ctx| {
            ctx.deinit();
        }
        
        if (self.listener != null) {
            self.api.ListenerClose(self.listener);
            self.listener = null;
        }
        if (self.configuration != null) {
            self.api.ConfigurationClose(self.configuration);
            self.configuration = null;
        }
        if (self.registration != null) {
            self.api.RegistrationClose(self.registration);
            self.registration = null;
        }
        
        MsQuicClose(@ptrCast(self.api));
        self.allocator.destroy(self);
    }

    pub fn createServerConfiguration(
        self: *MsQuic,
        cert_file: []const u8,
        key_file: []const u8,
        alpn: []const u8,
    ) !void {
        // Create configuration
        var alpn_buffers: [1]QUIC_BUFFER = undefined;
        alpn_buffers[0] = .{
            .Length = @intCast(alpn.len),
            .Buffer = @constCast(alpn.ptr),
        };

        // Simple settings
        var settings = std.mem.zeroes(QUIC_SETTINGS);
        
        // Set IdleTimeout
        settings.IsSetFlags |= types.QUIC_SETTINGS_IsSet_IdleTimeoutMs;
        settings.IdleTimeoutMs = 30000;
        
        // Enable bidirectional streams from client
        settings.IsSetFlags |= types.QUIC_SETTINGS_IsSet_PeerBidiStreamCount;
        settings.PeerBidiStreamCount = 100; // Allow up to 100 concurrent bidirectional streams
        
        // Enable unidirectional streams as well
        settings.IsSetFlags |= types.QUIC_SETTINGS_IsSet_PeerUnidiStreamCount;
        settings.PeerUnidiStreamCount = 100;

        const status = self.api.ConfigurationOpen(
            self.registration,
            &alpn_buffers,
            1,
            &settings,
            @sizeOf(QUIC_SETTINGS),
            null,
            &self.configuration,
        );

        if (QUIC_FAILED(status)) {
            std.debug.print("ConfigurationOpen failed: status={}\n", .{status});
            return QuicError.ConfigurationLoadFailed;
        }

        // Load server certificate
        const cert_file_z = try self.allocator.dupeZ(u8, cert_file);
        defer self.allocator.free(cert_file_z);
        const key_file_z = try self.allocator.dupeZ(u8, key_file);
        defer self.allocator.free(key_file_z);

        var cert_file_config = QUIC_CERTIFICATE_FILE{
            .CertificateFile = cert_file_z.ptr,
            .PrivateKeyFile = key_file_z.ptr,
        };

        var cred_config = std.mem.zeroes(QUIC_CREDENTIAL_CONFIG);
        cred_config.Type = .QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE;
        cred_config.Flags = 0;
        cred_config.Certificate = .{ .CertificateFile = &cert_file_config };
        cred_config.Principal = "";
        cred_config.Reserved = null;
        cred_config.AsyncHandler = null;
        cred_config.AllowedCipherSuites = 0;
        cred_config.CaCertificateFile = "";

        const load_status = self.api.ConfigurationLoadCredential(
            self.configuration,
            &cred_config,
        );

        if (QUIC_FAILED(load_status)) {
            std.debug.print("ConfigurationLoadCredential failed: status={}\n", .{load_status});
            return QuicError.CertificateError;
        }
    }

    pub fn createClientConfiguration(
        self: *MsQuic,
        alpn: []const u8,
        insecure: bool,
    ) !void {
        var alpn_buffers: [1]QUIC_BUFFER = undefined;
        alpn_buffers[0] = .{
            .Length = @intCast(alpn.len),
            .Buffer = @constCast(alpn.ptr),
        };

        var settings = std.mem.zeroes(QUIC_SETTINGS);
        settings.IsSetFlags |= types.QUIC_SETTINGS_IsSet_IdleTimeoutMs;
        settings.IdleTimeoutMs = 30000;

        const status = self.api.ConfigurationOpen(
            self.registration,
            &alpn_buffers,
            1,
            &settings,
            @sizeOf(QUIC_SETTINGS),
            null,
            &self.configuration,
        );

        if (QUIC_FAILED(status)) {
            return QuicError.ConfigurationLoadFailed;
        }

        // Client credential configuration
        var cred_config = std.mem.zeroes(QUIC_CREDENTIAL_CONFIG);
        cred_config.Type = .QUIC_CREDENTIAL_TYPE_NONE;
        if (insecure) {
            cred_config.Flags = 0x00000001 | 0x00000004; // CLIENT | NO_CERTIFICATE_VALIDATION
        } else {
            cred_config.Flags = 0x00000001; // CLIENT only
        }
        cred_config.Certificate = .{ .CertificateHash = null };
        cred_config.Principal = "";
        cred_config.Reserved = null;
        cred_config.AsyncHandler = null;
        cred_config.AllowedCipherSuites = 0;
        cred_config.CaCertificateFile = "";

        const load_status = self.api.ConfigurationLoadCredential(
            self.configuration,
            &cred_config,
        );

        if (QUIC_FAILED(load_status)) {
            return QuicError.ConfigurationLoadFailed;
        }
    }
    
    pub fn startListener(
        self: *MsQuic,
        address: []const u8,
        port: u16,
        alpn: []const u8,
    ) !void {
        // Create listener context with API and configuration handles
        self.listener_ctx = try ListenerContext.init(self.allocator, self.api, self.configuration);
        std.debug.print("[startListener] Created ListenerContext={*}\n", .{self.listener_ctx.?});
        errdefer if (self.listener_ctx) |ctx| ctx.deinit();
        
        // Open listener
        const open_status = self.api.ListenerOpen(
            self.registration,
            listenerCallback,
            self.listener_ctx,
            &self.listener,
        );
        
        if (QUIC_FAILED(open_status)) {
            std.debug.print("ListenerOpen failed: status={}\n", .{open_status});
            return QuicError.ListenerStartFailed;
        }
        
        // Prepare ALPN buffer
        var alpn_buffers: [1]QUIC_BUFFER = undefined;
        alpn_buffers[0] = .{
            .Length = @intCast(alpn.len),
            .Buffer = @constCast(alpn.ptr),
        };
        
        // Prepare address
        var addr = std.mem.zeroes(QUIC_ADDR);
        addr.sin_family = 2; // AF_INET
        addr.sin_port = @byteSwap(port); // Network byte order
        
        // Parse address (simple IPv4)
        if (std.mem.eql(u8, address, "0.0.0.0")) {
            @memset(addr.sin_addr[0..4], 0);
        } else {
            // For now, just use 0.0.0.0
            @memset(addr.sin_addr[0..4], 0);
        }
        
        // Start listener
        const start_status = self.api.ListenerStart(
            self.listener,
            &alpn_buffers,
            1,
            &addr,
        );
        
        if (QUIC_FAILED(start_status)) {
            std.debug.print("ListenerStart failed: status={}\n", .{start_status});
            return QuicError.ListenerStartFailed;
        }
        
        std.debug.print("✅ Listener started on port {}\n", .{port});
    }
};

pub const MsQuicConnection = struct {
    handle: HQUIC,
    api: *const QUIC_API_TABLE,
    context: *ConnectionContext,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MsQuicConnection) void {
        self.api.ConnectionClose(self.handle);
        self.context.deinit();
        self.allocator.destroy(self);
    }
};

pub const MsQuicStream = struct {
    handle: HQUIC,
    api: *const QUIC_API_TABLE,
    context: *StreamContext,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MsQuicStream) void {
        self.api.StreamClose(self.handle);
        self.context.deinit();
        self.allocator.destroy(self);
    }

    pub fn write(self: *MsQuicStream, data: []const u8) !usize {
        var buffer = QUIC_BUFFER{
            .Length = @intCast(data.len),
            .Buffer = @constCast(data.ptr),
        };

        const status = self.api.StreamSend(
            self.handle,
            &buffer,
            1,
            types.QUIC_SEND_FLAG_NONE,
            null,
        );

        if (QUIC_FAILED(status)) {
            return QuicError.StreamFailed;
        }

        return data.len;
    }
    
    pub fn read(self: *MsQuicStream, buf: []u8) !usize {
        self.context.mutex.lock();
        defer self.context.mutex.unlock();
        
        if (self.context.recv_buffer.items.len == 0) {
            return 0;
        }
        
        const to_copy = @min(buf.len, self.context.recv_buffer.items.len);
        @memcpy(buf[0..to_copy], self.context.recv_buffer.items[0..to_copy]);
        
        // Remove copied data
        if (to_copy < self.context.recv_buffer.items.len) {
            std.mem.copyForwards(
                u8,
                self.context.recv_buffer.items,
                self.context.recv_buffer.items[to_copy..],
            );
        }
        self.context.recv_buffer.shrinkRetainingCapacity(
            self.context.recv_buffer.items.len - to_copy
        );
        
        return to_copy;
    }
};
