# msquic Implementation Roadmap

This document provides a detailed implementation guide for completing the msquic migration.

## Quick Start (When Resuming)

```bash
cd /home/benji/src/spyder/geode

# Test current foundation
LD_LIBRARY_PATH=/nix/store/wdyb7p8h2fpbrgli3i1czdxsib9bhfm5-libmsquic-2.5.4/lib:$LD_LIBRARY_PATH \
  ./test_msquic.sh

# Should see:
# ✅ msquic initialized successfully
# ✅ All 2 tests passed
```

## Implementation Order

### Step 1: Define C Structures (4-6 hours)

Create `src/transport/msquic_types.zig` with manual C definitions:

```zig
// Status codes
pub const QUIC_STATUS_SUCCESS: u32 = 0;
pub const QUIC_STATUS_PENDING: u32 = 0xC0000103;

// Event types
pub const QUIC_LISTENER_EVENT_NEW_CONNECTION: u32 = 0;
pub const QUIC_LISTENER_EVENT_STOP_COMPLETE: u32 = 1;

pub const QUIC_CONNECTION_EVENT_CONNECTED: u32 = 0;
pub const QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT: u32 = 1;
pub const QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER: u32 = 2;
pub const QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE: u32 = 3;
pub const QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED: u32 = 5;

pub const QUIC_STREAM_EVENT_START_COMPLETE: u32 = 0;
pub const QUIC_STREAM_EVENT_RECEIVE: u32 = 1;
pub const QUIC_STREAM_EVENT_SEND_COMPLETE: u32 = 2;
pub const QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN: u32 = 3;
pub const QUIC_STREAM_EVENT_PEER_SEND_ABORTED: u32 = 4;
pub const QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE: u32 = 6;

// Structures (simplified for Zig)
pub const QUIC_BUFFER = extern struct {
    Length: u32,
    Buffer: [*]u8,
};

pub const QUIC_NEW_CONNECTION_INFO = extern struct {
    QuicVersion: u32,
    LocalAddress: *const anyopaque,
    RemoteAddress: *const anyopaque,
    // ... more fields as needed
};

// Event structures - use tagged unions
pub const ListenerEvent = struct {
    event_type: u32,
    connection: ?*opaque{},
    info: ?*const QUIC_NEW_CONNECTION_INFO,
};

pub const ConnectionEvent = struct {
    event_type: u32,
    // Add fields as needed per event type
};

pub const StreamEvent = struct {
    event_type: u32,
    // Add fields as needed per event type
};
```

**Extract from msquic.h** using:
```bash
grep -A 50 "typedef struct QUIC_" /nix/store/.../include/msquic.h > msquic_structs.txt
# Then manually convert to Zig
```

### Step 2: Implement API Table Access (2 hours)

Update `src/transport/msquic_wrapper.zig`:

```zig
// API function pointer types
pub const RegistrationOpenFn = *const fn(
    config: *const anyopaque,
    registration: *?HQUIC
) callconv(.C) QUIC_STATUS;

pub const ConfigurationOpenFn = *const fn(
    registration: HQUIC,
    alpn_buffers: [*]const QUIC_BUFFER,
    alpn_buffer_count: u32,
    settings: *const anyopaque,
    settings_size: u32,
    context: ?*anyopaque,
    configuration: *?HQUIC
) callconv(.C) QUIC_STATUS;

// ... more function pointers

pub const QUIC_API_TABLE = extern struct {
    // Access function pointers from the table
    RegistrationOpen: RegistrationOpenFn,
    ConfigurationOpen: ConfigurationOpenFn,
    // ... etc
};

pub const MsQuic = struct {
    api: *const QUIC_API_TABLE,
    
    pub fn init(allocator: std.mem.Allocator) !*MsQuic {
        var api_ptr: ?*const anyopaque = null;
        const status = MsQuicOpenVersion(2, &api_ptr);
        
        // Cast to QUIC_API_TABLE
        const api_table: *const QUIC_API_TABLE = @ptrCast(@alignCast(api_ptr.?));
        
        self.api = api_table;
        // ...
    }
};
```

### Step 3: Implement Callbacks (4-6 hours)

Add to `src/transport/msquic_wrapper.zig`:

```zig
// Callback context - stores Zig state
pub const ListenerContext = struct {
    allocator: std.mem.Allocator,
    pending_connections: std.ArrayList(*opaque{}),
    mutex: std.Thread.Mutex = .{},
};

// Listener callback
pub fn listenerCallback(
    listener: HQUIC,
    context: ?*anyopaque,
    event_ptr: *const anyopaque
) callconv(.C) QUIC_STATUS {
    _ = listener;
    
    const ctx: *ListenerContext = @ptrCast(@alignCast(context.?));
    const event: *const ListenerEvent = @ptrCast(@alignCast(event_ptr));
    
    switch (event.event_type) {
        QUIC_LISTENER_EVENT_NEW_CONNECTION => {
            // Accept the connection
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.pending_connections.append(event.connection.?) catch {};
            return QUIC_STATUS_SUCCESS;
        },
        QUIC_LISTENER_EVENT_STOP_COMPLETE => {
            return QUIC_STATUS_SUCCESS;
        },
        else => return QUIC_STATUS_SUCCESS,
    }
}

// Similar for connection and stream callbacks
pub fn connectionCallback(...) callconv(.C) QUIC_STATUS { ... }
pub fn streamCallback(...) callconv(.C) QUIC_STATUS { ... }
```

### Step 4: Implement Server Listen (3-4 hours)

Update `src/transport/quic_msquic.zig`:

```zig
pub fn listen(self: *QuicTransport) !void {
    // 1. Create registration
    const reg_config = ...; // Define QUIC_REGISTRATION_CONFIG
    try self.msquic.api.RegistrationOpen(&reg_config, &self.msquic.registration);
    
    // 2. Create configuration
    const settings = ...; // Define QUIC_SETTINGS
    try self.msquic.api.ConfigurationOpen(...);
    
    // 3. Load credentials (TLS cert)
    const cred_config = ...; // Define QUIC_CREDENTIAL_CONFIG
    try self.msquic.api.ConfigurationLoadCredential(...);
    
    // 4. Create listener
    const listener_ctx = try self.allocator.create(ListenerContext);
    listener_ctx.* = .{
        .allocator = self.allocator,
        .pending_connections = std.ArrayList(*opaque{}).init(self.allocator),
    };
    
    try self.msquic.api.ListenerOpen(
        self.msquic.registration,
        msquic.listenerCallback,
        listener_ctx,
        &self.msquic.listener
    );
    
    // 5. Start listening
    const addr = ...; // Convert address:port to QUIC_ADDR
    try self.msquic.api.ListenerStart(
        self.msquic.listener,
        &alpn_buffers,
        1,
        &addr
    );
}
```

### Step 5: Implement Connection Accept (2-3 hours)

```zig
pub fn accept(self: *QuicTransport) !*QuicConnection {
    // Poll pending connections from listener context
    while (true) {
        self.listener_ctx.mutex.lock();
        if (self.listener_ctx.pending_connections.items.len > 0) {
            const conn_handle = self.listener_ctx.pending_connections.pop();
            self.listener_ctx.mutex.unlock();
            
            // Set connection callback
            try self.msquic.api.SetCallbackHandler(
                conn_handle,
                connectionCallback,
                conn_ctx
            );
            
            // Create Zig connection wrapper
            const conn = try self.allocator.create(QuicConnection);
            conn.* = .{
                .allocator = self.allocator,
                .msquic_conn = conn_handle,
                ...
            };
            
            try self.connections.append(conn);
            return conn;
        }
        self.listener_ctx.mutex.unlock();
        
        // Wait for event or timeout
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}
```

### Step 6: Implement Stream Operations (4-6 hours)

```zig
pub fn write(self: *QuicStream, data: []const u8) !void {
    var buffer = QUIC_BUFFER{
        .Length = @intCast(data.len),
        .Buffer = @constCast(data.ptr),
    };
    
    const status = self.msquic.api.StreamSend(
        self.handle,
        &buffer,
        1,
        QUIC_SEND_FLAG_NONE,
        null
    );
    
    if (status != QUIC_STATUS_SUCCESS) {
        return error.StreamFailed;
    }
}

pub fn read(self: *QuicStream, buf: []u8) !usize {
    // Read from receive buffer populated by callback
    self.recv_mutex.lock();
    defer self.recv_mutex.unlock();
    
    if (self.recv_buffer.items.len == 0) {
        return 0; // Would block
    }
    
    const to_copy = @min(buf.len, self.recv_buffer.items.len);
    @memcpy(buf[0..to_copy], self.recv_buffer.items[0..to_copy]);
    
    // Remove copied data
    std.mem.copyForwards(
        u8,
        self.recv_buffer.items,
        self.recv_buffer.items[to_copy..]
    );
    self.recv_buffer.shrinkRetainingCapacity(
        self.recv_buffer.items.len - to_copy
    );
    
    return to_copy;
}
```

### Step 7: Testing Strategy

#### Unit Tests
```bash
# Test each component
zig test src/transport/msquic_types.zig
zig test src/transport/msquic_wrapper.zig  
zig test src/transport/quic_msquic.zig
```

#### Integration Tests
```zig
// tests/test_msquic_server.zig
test "msquic server startup" {
    var transport = try QuicTransport.init(allocator, .{});
    defer transport.deinit();
    
    try transport.listen();
    // Server should be listening
}

test "msquic accept connection" {
    // Start server in thread
    // Connect with client
    // Accept connection
    // Verify connection established
}

test "msquic bidirectional stream" {
    // Establish connection
    // Open stream
    // Write data
    // Read data
    // Verify round-trip
}
```

#### Client Tests
```bash
# Python
cd clients/python
python test_msquic_client.py

# Go
cd clients/go
go test ./...

# Rust
cd clients/rust
cargo test
```

## Common Pitfalls

### 1. Pointer Alignment
```zig
// WRONG
const api: *QUIC_API_TABLE = @ptrCast(api_ptr);

// RIGHT
const api: *QUIC_API_TABLE = @ptrCast(@alignCast(api_ptr));
```

### 2. Callback Context Lifetime
```zig
// Ensure context lives as long as the callback is registered
// Use allocator.create() not stack allocation
const ctx = try allocator.create(Context);
// Later: allocator.destroy(ctx)
```

### 3. Async Event Handling
```zig
// Use mutex for shared state between callbacks and main thread
pub const ConnectionState = struct {
    mutex: std.Thread.Mutex = .{},
    recv_buffer: std.ArrayList(u8),
    // ...
};
```

### 4. Error Handling
```zig
// Check ALL return statuses
const status = api.SomeFunction(...);
if (status != QUIC_STATUS_SUCCESS and status != QUIC_STATUS_PENDING) {
    return error.OperationFailed;
}
```

## Debugging Tips

### Enable msquic Logging
```bash
export CLOG_CONFIG_FILE=/path/to/msquic/clog.txt
# Run with detailed logs
```

### Trace Callbacks
```zig
pub fn listenerCallback(...) callconv(.C) QUIC_STATUS {
    std.debug.print("CALLBACK: listener event={}\n", .{event.type});
    // ...
}
```

### Use Valgrind
```bash
valgrind --leak-check=full ./zig-out/bin/geode
# Check for memory leaks in callbacks
```

## Performance Considerations

1. **Buffer Pooling**: Reuse QUIC_BUFFER structures
2. **Batch Operations**: Use StreamSend with multiple buffers
3. **Zero-Copy**: Use scatter-gather I/O where possible
4. **Connection Pooling**: Reuse connections when appropriate

## Success Criteria

- [ ] Server starts and listens on port 7567
- [ ] Accepts connections from standard QUIC clients
- [ ] TLS handshake completes successfully
- [ ] Bidirectional streams work correctly
- [ ] All client libraries (Python/Go/Rust) connect successfully
- [ ] Performance comparable to vendor QUIC (within 10%)
- [ ] No memory leaks under load
- [ ] Graceful shutdown works

## Time Estimates

| Task | Hours | Status |
|------|-------|--------|
| Define C structures | 4-6 | ⏳ |
| API table access | 2 | ⏳ |
| Implement callbacks | 4-6 | ⏳ |
| Server listen | 3-4 | ⏳ |
| Connection accept | 2-3 | ⏳ |
| Stream operations | 4-6 | ⏳ |
| Client implementation | 4-6 | ⏳ |
| Testing & debugging | 4-6 | ⏳ |
| **TOTAL** | **27-43 hours** | |

**Realistic estimate**: 3-5 full working days

## References

- [msquic API Reference](https://github.com/microsoft/msquic/blob/main/docs/API.md)
- [msquic Sample Server](https://github.com/microsoft/msquic/blob/main/src/tools/sample/sample.c)
- [Zig C Interop Guide](https://ziglang.org/documentation/master/#C)
- [QUIC RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html)

---

**Created**: 2025-11-14
**Status**: Ready for implementation
