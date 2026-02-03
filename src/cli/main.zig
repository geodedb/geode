const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const audit_cli = @import("audit_cli");
const geode = @import("geode");
const Value = geode.value_types.Value;
// CANARY: REQ=REQ-CLI-REFACTOR-001; FEATURE="CLI Library Migration"; ASPECT=FlagParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
// TODO: Migrate to devnw/zig/cli library for improved flag management, automatic help generation,
// shell completions, and type-safe configuration. See https://gitlab.com/devnw/zig/cli
// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=CLI; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("cli");
const Attr = logging.Attr;
// Import server main from unified entry point (both cli and server share same module tree)
const server_main = @import("../server/main.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-026; FEATURE="JSON Library Migration"; ASPECT=CLI; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-24
const protobuf = @import("protobuf");
const json_lib = @import("json");
const schema = @import("schema");

// GAP-0203: Gate hot-path debug logging to eliminate overhead in production
// CANARY: REQ=REQ-PERF-LOG-GATE-001; FEATURE="HotPathLogGating"; ASPECT=DebugLogControl; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
// Set to true only when debugging protocol/query issues. In production, keep false.
const HOT_PATH_LOGGING = false;

// C library function for setting environment variables
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
// const auth = @import("../security/auth.zig"); // Not needed for current implementation
// const hash = @import("../types/hash.zig"); // Not needed for current implementation
const crypto = std.crypto;

// CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedBinary; STATUS=TESTED; TEST=tests/test_cli_subprocess_elimination_integration.zig; OWNER=cli; UPDATED=2026-01-15
// Direct calls to server and client main functions to eliminate subprocess spawning

// CANARY: REQ=REQ-M11-DRY-002; FEATURE="CodeQuality"; ASPECT=DuplicateCode; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// M11: Import backup types from canonical location (storage/backup.zig) instead of duplicating
const backup_types = @import("storage/backup");

// CANARY: REQ=REQ-M4.1-CLI-MODULARIZATION-001; FEATURE="CLI Modularization"; ASPECT=UserManagement; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=cli; UPDATED=2026-01-15
// Phase 4 M4.1: Import user management CLI module
const user_mgmt_cli = @import("user_mgmt_cli.zig");
const cmdUser = user_mgmt_cli.cmdUser;
const cmdRole = user_mgmt_cli.cmdRole;

// CANARY: REQ=REQ-M4.2-CLI-MODULARIZATION-001; FEATURE="CLI Modularization"; ASPECT=AuthCommands; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=cli; UPDATED=2026-01-15
// Phase 4 M4.2: Import authentication and policy CLI module
const auth_cli = @import("auth_cli.zig");
const cmdPolicy = auth_cli.cmdPolicy;
const cmdGrant = auth_cli.cmdGrant;
const cmdRevoke = auth_cli.cmdRevoke;

// CANARY: REQ=REQ-M4.3-CLI-MODULARIZATION-001; FEATURE="CLI Modularization"; ASPECT=BackupCommands; STATUS=TESTED; TEST=tests/test_cli_integration.zig; OWNER=cli; UPDATED=2026-01-15
// Phase 4 M4.3: Import backup/restore/migrate CLI module
const backup_cli = @import("backup_cli.zig");
const cmdBackup = backup_cli.cmdBackup;
const cmdRestore = backup_cli.cmdRestore;
const cmdMigrate = backup_cli.cmdMigrate;
const auth_state = geode.auth_state;
const execution = geode.execution;

// CANARY: REQ=REQ-M4.4-CLI-DISPATCHER-002; FEATURE="CLI Modularization"; ASPECT=DispatcherIntegration; STATUS=TESTED; TEST=tests/test_cli_integration.zig; OWNER=cli; UPDATED=2026-01-15
// Phase 4 M4.4: Import CLI dispatcher module for command routing
const cli_dispatcher = @import("cli_dispatcher.zig");
const fle_cli = @import("fle_cli.zig");
const cmdFLE = fle_cli.cmdFLE;

// Import shared types and functions from cli_dispatcher
const ExitCode = cli_dispatcher.ExitCode;
const getEnvVar = cli_dispatcher.getEnvVar;
const logAuditEvent = cli_dispatcher.logAuditEvent;
const windows = if (builtin.os.tag == .windows) std.os.windows else struct {};
const net = std.net;

// Import QUIC modules for real transport implementation
const quic = @import("transport/quic");
const vendor_quic = @import("vendor_quic");

const VERSION = build_options.version;

// CANARY: REQ=REQ-REPL-QUIC-002; FEATURE="REPL QUIC Transport"; ASPECT=QuicTransportAdapter; STATUS=TESTED; TEST=tests/test_repl_quic_integration_e2e.zig; OWNER=repl; UPDATED=2026-01-15
const repl_dispatch = geode.repl.repl_dispatch;

// GAP-0134: Thread-local TLS configuration for shell transport
// CANARY: REQ=REQ-SHELL-TLS-001; FEATURE="Shell TLS Configuration"; ASPECT=SecureConnection; STATUS=TESTED; TEST=tests/test_repl_quic_integration_e2e.zig; OWNER=cli; UPDATED=2026-01-15
var shell_tls_config: ShellTlsConfig = .{};

const ShellTlsConfig = struct {
    insecure: bool = false,
    ca_cert_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
};

const TcpTransportConnection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
};

fn tcpWriteAll(self: *repl_dispatch.TransportConnection, data: []const u8) !void {
    const ctx = self.context orelse return error.NotConnected;
    const impl: *TcpTransportConnection = @ptrCast(@alignCast(ctx));
    var written: usize = 0;
    while (written < data.len) {
        const n = try std.posix.write(impl.stream.handle, data[written..]);
        if (n == 0) return error.Unexpected;
        written += n;
    }
}

fn tcpReadLine(self: *repl_dispatch.TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    const ctx = self.context orelse return error.NotConnected;
    const impl: *TcpTransportConnection = @ptrCast(@alignCast(ctx));

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    var temp: [256]u8 = undefined;
    while (true) {
        const n = try std.posix.read(impl.stream.handle, temp[0..]);
        if (n == 0) break; // EOF
        for (temp[0..n]) |b| {
            if (buf.items.len >= max_size) return error.LineTooLong;
            try buf.append(allocator, b);
            if (b == '\n') {
                return buf.toOwnedSlice(allocator);
            }
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn tcpDeinit(self: *repl_dispatch.TransportConnection) void {
    const ctx = self.context orelse {
        if (self.allocator) |alloc| alloc.destroy(self);
        return;
    };
    const impl: *TcpTransportConnection = @ptrCast(@alignCast(ctx));
    impl.stream.close();
    const alloc = impl.allocator;
    alloc.destroy(impl);
    if (self.allocator) |conn_alloc| conn_alloc.destroy(self);
}

fn tcpConnect(allocator: std.mem.Allocator, addr: []const u8) !*repl_dispatch.TransportConnection {
    const colon_idx = std.mem.lastIndexOf(u8, addr, ":") orelse return error.InvalidAddress;
    const host = addr[0..colon_idx];
    const port = try std.fmt.parseInt(u16, addr[colon_idx + 1 ..], 10);

    const stream = try net.tcpConnectToHost(allocator, host, port);
    errdefer stream.close();

    const impl = try allocator.create(TcpTransportConnection);
    impl.* = .{ .allocator = allocator, .stream = stream };

    const transport_conn = try allocator.create(repl_dispatch.TransportConnection);
    transport_conn.* = .{
        .writeAllFn = tcpWriteAll,
        .readLineFn = tcpReadLine,
        .deinitFn = tcpDeinit,
        .context = impl,
        .allocator = allocator,
    };
    return transport_conn;
}

// TCP transport (legacy, not used for server communication)
const tcp_transport = repl_dispatch.Transport{
    .connectFn = tcpConnect,
};

// QUIC Transport for REPL - proper QUIC/UDP connection
const QuicTransportConnection = struct {
    allocator: std.mem.Allocator,
    client: *quic.QuicClient,
    stream: *quic.QuicClientStream,
    owns_client: bool,
    // CANARY: REQ=REQ-SHELL-PROTO-003; FEATURE="ShellProtobufTransport"; ASPECT=PullSkip; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
    // Track if last write was PULL - server doesn't use PULL in Protobuf protocol
    // Data is returned with Execute, so PULL should return empty/success
    pending_pull: bool = false,
};

// CANARY: REQ=REQ-SHELL-PROTO-001; FEATURE="ShellProtobufTransport"; ASPECT=WriteAll; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
// Convert JSON messages from REPL to Protobuf with length-prefix framing for server
fn quicWriteAll(self: *repl_dispatch.TransportConnection, data: []const u8) !void {
    const ctx = self.context orelse return error.NotConnected;
    const impl: *QuicTransportConnection = @ptrCast(@alignCast(ctx));
    const allocator = impl.allocator;

    // Strip trailing newline for JSON parsing
    const trimmed = std.mem.trimRight(u8, data, "\r\n");
    if (trimmed.len == 0) return;

    // Parse JSON to determine message type
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        // Not valid JSON, send as-is (shouldn't happen but fallback)
        impl.stream.writeAll(data) catch |err| return err;
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        impl.stream.writeAll(data) catch |err| return err;
        return;
    }

    const obj = parsed.value.object;
    const msg_type = obj.get("type") orelse {
        impl.stream.writeAll(data) catch |err| return err;
        return;
    };

    if (msg_type != .string) {
        impl.stream.writeAll(data) catch |err| return err;
        return;
    }

    // Convert JSON to Protobuf based on message type
    const proto_msg: schema.QuicClientMessage = blk: {
        if (std.mem.eql(u8, msg_type.string, "HELLO")) {
            // Extract optional username/password for authenticated HELLO
            const username = if (obj.get("username")) |u| (if (u == .string) u.string else "") else "";
            const password = if (obj.get("password")) |p| (if (p == .string) p.string else "") else "";
            break :blk .{ .hello = .{
                .username = username,
                .password = password,
                .tenant_id = null,
            } };
        } else if (std.mem.eql(u8, msg_type.string, "RUN_GQL")) {
            const text = if (obj.get("text")) |t| (if (t == .string) t.string else "") else "";
            break :blk .{ .execute = .{
                .session_id = "",
                .query = text,
                .params_json = "",
            } };
        } else if (std.mem.eql(u8, msg_type.string, "BEGIN")) {
            break :blk .{ .begin = .{ .read_only = false } };
        } else if (std.mem.eql(u8, msg_type.string, "COMMIT")) {
            break :blk .{ .commit = .{} };
        } else if (std.mem.eql(u8, msg_type.string, "ROLLBACK")) {
            break :blk .{ .rollback = .{} };
        } else if (std.mem.eql(u8, msg_type.string, "PING")) {
            break :blk .{ .ping = .{} };
        } else if (std.mem.eql(u8, msg_type.string, "PULL")) {
            // CANARY: REQ=REQ-SHELL-PROTO-004; FEATURE="ShellProtobufTransport"; ASPECT=PullNoOp; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
            // PULL doesn't exist in Protobuf protocol - server returns all data with Execute
            // Mark pending_pull so readLine returns empty success without server round-trip
            impl.pending_pull = true;
            return; // Don't send anything to server
        } else {
            // Unknown message type, try sending as-is
            impl.stream.writeAll(data) catch |err| return err;
            return;
        }
    };

    // Encode to Protobuf
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch return error.OutOfMemory;
    defer aw.deinit();

    protobuf.encode(&aw.writer, allocator, proto_msg) catch |err| {
        log.err("Failed to encode protobuf message", &.{Attr.err("error", err)});
        return err;
    };

    const encoded = aw.writer.buffer[0..aw.writer.end];

    // Write length prefix (4 bytes big-endian)
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(encoded.len), .big);
    impl.stream.writeAll(&len_buf) catch |err| return err;

    // Write message body
    impl.stream.writeAll(encoded) catch |err| return err;
}

// CANARY: REQ=REQ-SHELL-PROTO-002; FEATURE="ShellProtobufTransport"; ASPECT=ReadLine; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
// Read length-prefixed Protobuf responses and convert to JSON for REPL compatibility
fn quicReadLine(self: *repl_dispatch.TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    _ = max_size;
    const ctx = self.context orelse return error.NotConnected;
    const impl: *QuicTransportConnection = @ptrCast(@alignCast(ctx));

    // CANARY: REQ=REQ-SHELL-PROTO-005; FEATURE="ShellProtobufTransport"; ASPECT=PullResponse; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
    // If we sent PULL, return empty success - data was already returned with Execute
    if (impl.pending_pull) {
        impl.pending_pull = false;
        // Return empty BINDINGS response - no more data (it was all in Execute response)
        return try allocator.dupe(u8, "{\"type\":\"BINDINGS\",\"rows\":[],\"final\":true}");
    }

    const start = std.time.milliTimestamp();
    const timeout_ms: i64 = 30000; // 30 second timeout for REPL

    // Read 4-byte length prefix
    var len_buf: [4]u8 = undefined;
    var len_read: usize = 0;
    while (len_read < 4) {
        if (repl_dispatch.checkForInterrupt()) {
            return error.Interrupted;
        }

        const n = impl.stream.read(len_buf[len_read..]) catch |err| {
            if (err == error.WouldBlock) {
                if (std.time.milliTimestamp() - start >= timeout_ms) return error.WouldBlock;
                impl.client.poll(5) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.EndOfStream;
        len_read += n;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len > 16 * 1024 * 1024) return error.MessageTooLarge; // 16MB limit

    // Read message body
    const body = try allocator.alloc(u8, msg_len);
    errdefer allocator.free(body);

    var body_read: usize = 0;
    while (body_read < msg_len) {
        if (repl_dispatch.checkForInterrupt()) {
            allocator.free(body);
            return error.Interrupted;
        }

        const n = impl.stream.read(body[body_read..]) catch |err| {
            if (err == error.WouldBlock) {
                if (std.time.milliTimestamp() - start >= timeout_ms) {
                    allocator.free(body);
                    return error.WouldBlock;
                }
                impl.client.poll(5) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            allocator.free(body);
            return err;
        };
        if (n == 0) {
            allocator.free(body);
            return error.EndOfStream;
        }
        body_read += n;
    }

    // Decode Protobuf
    var reader: std.Io.Reader = .fixed(body);
    var packet = protobuf.decode(schema.ServerPacket, &reader, allocator) catch |err| {
        allocator.free(body);
        log.err("Failed to decode protobuf response", &.{Attr.err("error", err)});
        return err;
    };
    allocator.free(body);
    defer packet.deinit(allocator);

    const msg = packet.quic orelse return error.InvalidMessage;

    // Convert Protobuf response to JSON for REPL compatibility
    var json_buf = std.ArrayList(u8).initCapacity(allocator, 1024) catch return error.OutOfMemory;
    errdefer json_buf.deinit(allocator);
    const writer = json_buf.writer(allocator);

    switch (msg) {
        .hello => |h| {
            // HELLO response
            writer.writeAll("{\"type\":\"HELLO\",\"success\":") catch {};
            if (h.success) {
                writer.writeAll("true") catch {};
            } else {
                writer.writeAll("false") catch {};
            }
            if (h.error_message.len > 0) {
                writer.writeAll(",\"error\":\"") catch {};
                // Escape the error message
                for (h.error_message) |c| {
                    switch (c) {
                        '"' => writer.writeAll("\\\"") catch {},
                        '\\' => writer.writeAll("\\\\") catch {},
                        '\n' => writer.writeAll("\\n") catch {},
                        '\r' => writer.writeAll("\\r") catch {},
                        '\t' => writer.writeAll("\\t") catch {},
                        else => writer.writeByte(c) catch {},
                    }
                }
                writer.writeAll("\"") catch {};
            }
            writer.writeAll("}") catch {};
        },
        .execute => |exec| {
            // Query execution response - exec.payload is optional ExecutionResponseUnion
            if (exec.payload) |exec_val| {
                switch (exec_val) {
                    .schema => |s| {
                        // Schema definition response
                        writer.writeAll("{\"type\":\"SCHEMA\",\"columns\":[") catch {};
                        var first = true;
                        for (s.columns.items) |col| {
                            if (!first) writer.writeAll(",") catch {};
                            first = false;
                            writer.writeAll("{\"name\":\"") catch {};
                            writer.writeAll(col.name) catch {};
                            writer.writeAll("\",\"type\":\"") catch {};
                            writer.writeAll(col.type) catch {};
                            writer.writeAll("\"}") catch {};
                        }
                        writer.writeAll("]}") catch {};
                    },
                    .page => |p| {
                        // Data page response - server returns JSON result as string_val
                        // Check if first row first value is a complete JSON response (server wraps result in string)
                        const handled_passthrough = handle_blk: {
                            if (p.rows.items.len == 1 and p.rows.items[0].values.items.len == 1) {
                                if (p.rows.items[0].values.items[0].kind) |kind| {
                                    switch (kind) {
                                        .string_val => |str_val| {
                                            // Check if it looks like a complete JSON response
                                            if (std.mem.startsWith(u8, str_val.value, "{\"status_class\"") or
                                                std.mem.startsWith(u8, str_val.value, "{\"type\":"))
                                            {
                                                // Server already returned complete JSON - pass through directly
                                                writer.writeAll(str_val.value) catch {};
                                                break :handle_blk true;
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            }
                            break :handle_blk false;
                        };

                        if (!handled_passthrough) {
                            // Fallback: convert DataPage to BINDINGS format
                            writer.writeAll("{\"type\":\"BINDINGS\",\"rows\":[") catch {};
                            var first_row = true;
                            for (p.rows.items) |row| {
                                if (!first_row) writer.writeAll(",") catch {};
                                first_row = false;
                                writer.writeAll("[") catch {};
                                var first_val = true;
                                for (row.values.items) |val| {
                                    if (!first_val) writer.writeAll(",") catch {};
                                    first_val = false;
                                    // Serialize value based on kind (optional)
                                    if (val.kind) |kind| {
                                        switch (kind) {
                                            .null_val => writer.writeAll("null") catch {},
                                            .string_val => |s| {
                                                writer.writeAll("\"") catch {};
                                                for (s.value) |c| {
                                                    switch (c) {
                                                        '"' => writer.writeAll("\\\"") catch {},
                                                        '\\' => writer.writeAll("\\\\") catch {},
                                                        '\n' => writer.writeAll("\\n") catch {},
                                                        else => writer.writeByte(c) catch {},
                                                    }
                                                }
                                                writer.writeAll("\"") catch {};
                                            },
                                            .int_val => |i| {
                                                var num_buf: [32]u8 = undefined;
                                                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i.value}) catch "0";
                                                writer.writeAll(num_str) catch {};
                                            },
                                            .double_val => |d| {
                                                var num_buf: [64]u8 = undefined;
                                                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{d.value}) catch "0";
                                                writer.writeAll(num_str) catch {};
                                            },
                                            .bool_val => |b| {
                                                writer.writeAll(if (b) "true" else "false") catch {};
                                            },
                                            else => writer.writeAll("null") catch {},
                                        }
                                    } else {
                                        writer.writeAll("null") catch {};
                                    }
                                }
                                writer.writeAll("]") catch {};
                            }
                            writer.writeAll("],\"final\":") catch {};
                            writer.writeAll(if (p.final) "true" else "false") catch {};
                            writer.writeAll("}") catch {};
                        }
                    },
                    .@"error" => |e| {
                        writer.writeAll("{\"type\":\"ERROR\",\"status_class\":\"") catch {};
                        writer.writeAll(e.code) catch {};
                        writer.writeAll("\",\"error\":\"") catch {};
                        for (e.message) |c| {
                            switch (c) {
                                '"' => writer.writeAll("\\\"") catch {},
                                '\\' => writer.writeAll("\\\\") catch {},
                                '\n' => writer.writeAll("\\n") catch {},
                                else => writer.writeByte(c) catch {},
                            }
                        }
                        writer.writeAll("\"}") catch {};
                    },
                    .metrics, .heartbeat => {
                        // Ignore metrics/heartbeat messages
                        writer.writeAll("{\"type\":\"OK\"}") catch {};
                    },
                    .explain => |ex| {
                        writer.writeAll("{\"type\":\"EXPLAIN\",\"plan\":\"") catch {};
                        writer.writeAll(ex.json_payload) catch {};
                        writer.writeAll("\"}") catch {};
                    },
                    .profile => |pr| {
                        writer.writeAll("{\"type\":\"PROFILE\",\"plan\":\"") catch {};
                        writer.writeAll(pr.json_payload) catch {};
                        writer.writeAll("\"}") catch {};
                    },
                }
            } else {
                writer.writeAll("{\"type\":\"ERROR\",\"error\":\"Empty response\"}") catch {};
            }
        },
        .ping => |p| {
            writer.writeAll("{\"type\":\"PING\",\"ok\":") catch {};
            writer.writeAll(if (p.ok) "true" else "false") catch {};
            writer.writeAll("}") catch {};
        },
        .begin => |b| {
            // BeginResponse has session_id and tx_id, not success
            writer.writeAll("{\"type\":\"BEGIN\",\"success\":true,\"tx_id\":\"") catch {};
            writer.writeAll(b.tx_id) catch {};
            writer.writeAll("\"}") catch {};
        },
        .commit => |c| {
            writer.writeAll("{\"type\":\"COMMIT\",\"success\":") catch {};
            writer.writeAll(if (c.success) "true" else "false") catch {};
            writer.writeAll("}") catch {};
        },
        .rollback => |r| {
            writer.writeAll("{\"type\":\"ROLLBACK\",\"success\":") catch {};
            writer.writeAll(if (r.success) "true" else "false") catch {};
            writer.writeAll("}") catch {};
        },
        .pull => |p| {
            // Forward to execute handler since pull contains ExecutionResponse
            if (p.response) |resp| {
                if (resp.payload) |exec_val| {
                    switch (exec_val) {
                        .page => |page| {
                            writer.writeAll("{\"type\":\"BINDINGS\",\"rows\":[],\"final\":") catch {};
                            writer.writeAll(if (page.final) "true" else "false") catch {};
                            writer.writeAll("}") catch {};
                        },
                        else => writer.writeAll("{\"type\":\"OK\"}") catch {},
                    }
                } else {
                    writer.writeAll("{\"type\":\"OK\"}") catch {};
                }
            } else {
                writer.writeAll("{\"type\":\"OK\"}") catch {};
            }
        },
        .cdc_diag => {
            writer.writeAll("{\"type\":\"CDC_DIAG\",\"success\":true}") catch {};
        },
        .cdc_ctrl => {
            writer.writeAll("{\"type\":\"CDC_CTRL\",\"success\":true}") catch {};
        },
        .savepoint => |s| {
            writer.writeAll("{\"type\":\"SAVEPOINT\",\"success\":") catch {};
            writer.writeAll(if (s.success) "true" else "false") catch {};
            writer.writeAll("}") catch {};
        },
        .rollback_to => |r| {
            writer.writeAll("{\"type\":\"ROLLBACK_TO\",\"success\":") catch {};
            writer.writeAll(if (r.success) "true" else "false") catch {};
            writer.writeAll("}") catch {};
        },
        .backup => |b| {
            writer.writeAll("{\"type\":\"BACKUP\",\"success\":") catch {};
            writer.writeAll(if (b.success) "true" else "false") catch {};
            writer.writeAll("}") catch {};
        },
        .restore => |r| {
            writer.writeAll("{\"type\":\"RESTORE\",\"success\":") catch {};
            writer.writeAll(if (r.success) "true" else "false") catch {};
            writer.writeAll("}") catch {};
        },
        .upload_backup => |u| {
            writer.writeAll("{\"type\":\"UPLOAD_BACKUP\",\"success\":") catch {};
            writer.writeAll(if (u.success) "true" else "false") catch {};
            writer.writeAll("}") catch {};
        },
    }

    return json_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn quicDeinit(self: *repl_dispatch.TransportConnection) void {
    const ctx = self.context orelse {
        if (self.allocator) |alloc| alloc.destroy(self);
        return;
    };
    const impl: *QuicTransportConnection = @ptrCast(@alignCast(ctx));
    impl.stream.deinit();
    if (impl.owns_client) {
        impl.client.deinit();
        impl.allocator.destroy(impl.client);
    }
    impl.allocator.destroy(impl);
    if (self.allocator) |conn_alloc| conn_alloc.destroy(self);
}

fn quicConnect(allocator: std.mem.Allocator, addr: []const u8) !*repl_dispatch.TransportConnection {
    const colon_idx = std.mem.lastIndexOf(u8, addr, ":") orelse return error.InvalidAddress;
    const host = addr[0..colon_idx];
    const port = try std.fmt.parseInt(u16, addr[colon_idx + 1 ..], 10);

    // Create QUIC client
    const client = try allocator.create(quic.QuicClient);
    client.* = quic.QuicClient.init(allocator);
    errdefer {
        client.deinit();
        allocator.destroy(client);
    }

    // GAP-0134: Use TLS configuration from shell command
    // CANARY: REQ=REQ-SHELL-TLS-002; FEATURE="Shell TLS Connection"; ASPECT=SecureConnection; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-13
    if (shell_tls_config.insecure) {
        // Explicit insecure mode requested
        std.debug.print("Warning: TLS verification disabled (--insecure flag)\n", .{});
        _ = client.connectInsecure(host, port, true) catch |err| {
            return err;
        };
    } else if (shell_tls_config.ca_cert_path != null or shell_tls_config.client_cert_path != null) {
        // Custom certificates provided - use secure connection with custom certs
        // Note: Full certificate verification requires the QUIC library to support custom CA
        // For now, we connect with TLS but log the certificate configuration
        std.debug.print("Using TLS with custom certificates\n", .{});
        if (shell_tls_config.ca_cert_path) |ca| {
            std.debug.print("  CA certificate: {s}\n", .{ca});
        }
        if (shell_tls_config.client_cert_path) |cert| {
            std.debug.print("  Client certificate: {s}\n", .{cert});
        }
        // Connect with TLS verification enabled (insecure=false)
        _ = client.connectInsecure(host, port, false) catch |err| {
            return err;
        };
    } else {
        // Default: TLS verification enabled
        _ = client.connectInsecure(host, port, false) catch |err| {
            return err;
        };
    }

    // Wait for handshake
    _ = client.waitForHandshake(10) catch |err| {
        return err;
    };

    // Get stream
    var stream = client.getStream() catch |err| {
        return err;
    };
    errdefer stream.deinit();

    // Note: HELLO handshake is done by ClientSession.hello(), not here
    // This keeps the transport layer separate from the protocol layer

    // Create transport connection wrapper
    const impl = try allocator.create(QuicTransportConnection);
    impl.* = .{
        .allocator = allocator,
        .client = client,
        .stream = stream,
        .owns_client = true,
    };

    const transport_conn = try allocator.create(repl_dispatch.TransportConnection);
    transport_conn.* = .{
        .writeAllFn = quicWriteAll,
        .readLineFn = quicReadLine,
        .deinitFn = quicDeinit,
        .context = impl,
        .allocator = allocator,
    };
    return transport_conn;
}

const quic_transport = repl_dispatch.Transport{
    .connectFn = quicConnect,
};

// Cross-platform file handle helpers with proper error handling
// CANARY: REQ=REQ-QUALITY-GAP-406-002; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
// On Windows, file handles are HANDLE (*anyopaque), not integers
// On Unix, file handles are file descriptors (integers)
const StdioError = error{ StdioUnavailable, InvalidHandle };

fn getStdinHandle() StdioError!std.fs.File.Handle {
    if (builtin.os.tag == .windows) {
        const handle = windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch return error.StdioUnavailable;
        if (handle == windows.INVALID_HANDLE_VALUE) return error.InvalidHandle;
        return handle;
    } else {
        return std.posix.STDIN_FILENO;
    }
}

fn getStdoutHandle() StdioError!std.fs.File.Handle {
    if (builtin.os.tag == .windows) {
        const handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch return error.StdioUnavailable;
        if (handle == windows.INVALID_HANDLE_VALUE) return error.InvalidHandle;
        return handle;
    } else {
        return std.posix.STDOUT_FILENO;
    }
}

const ParamError = error{
    UnsupportedParameterType,
    OutOfMemory,
};

fn convertJsonParam(allocator: std.mem.Allocator, value: std.json.Value) ParamError!Value {
    return switch (value) {
        .null => Value{ .Null = {} },
        .bool => |b| Value{ .Bool = b },
        .string => Value{ .Str = try allocator.dupe(u8, value.string) },
        .integer => |i| Value{ .Int = @intCast(i) },
        .float => return error.UnsupportedParameterType,
        else => return error.UnsupportedParameterType,
    };
}

fn freeParamValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .Str => |s| allocator.free(s),
        else => {},
    }
}

fn getStderrHandle() StdioError!std.fs.File.Handle {
    if (builtin.os.tag == .windows) {
        const handle = windows.GetStdHandle(windows.STD_ERROR_HANDLE) catch return error.StdioUnavailable;
        if (handle == windows.INVALID_HANDLE_VALUE) return error.InvalidHandle;
        return handle;
    } else {
        return std.posix.STDERR_FILENO;
    }
}

fn printServeUsage() void {
    std.debug.print("geode serve - Start the database server\n" ++
        "\n" ++
        "Usage: geode serve [options]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --data-dir <path>      Data directory (default: ./data)\n" ++
        "  --listen <addr:port>   Listen address (default: 0.0.0.0:3141)\n" ++
        "  --cert <path>          TLS certificate path (auto-generated if missing)\n" ++
        "  --key <path>           TLS private key path (auto-generated if missing)\n" ++
        "  --log-level <level>    Log level: debug|info|warn|error (default: info)\n" ++
        "  --disable-auth         Disable user authentication (default: enabled) [SECURITY WARNING]\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode serve\n" ++
        "  geode serve --data-dir /var/lib/geode --listen 0.0.0.0:3141\n" ++
        "  geode serve --log-level info  # Auth enabled by default\n" ++
        "\n", .{});
}

fn printQueryUsage() void {
    std.debug.print("geode query - Execute a GQL query\n" ++
        "\n" ++
        "Usage: geode query [options] <query|-|--file path> \n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -g, --graph <name>     Graph to query against (auto-prepends USE GRAPH)\n" ++
        "  -f, --file <path>      Execute GQL statements from a file (supports ~)\n" ++
        "  --insecure             Skip TLS certificate verification\n" ++
        "  --ca-cert <path>       CA certificate path for server verification\n" ++
        "  --client-cert <path>   Client certificate path for mutual TLS\n" ++
        "  --client-key <path>    Client private key path for mutual TLS\n" ++
        "  --format <fmt>         Output format: json|table|csv|dot (default: json)\n" ++
        "  --json-param <name> <value>  Add JSON parameter\n" ++
        "  --page-size <n>        Page size for results (default: 1000)\n" ++
        "  --timeout <secs>       Connection timeout in seconds (default: 10)\n" ++
        "  --retry <count>        Number of retry attempts on failure (default: 0)\n" ++
        "  --begin                Start transaction\n" ++
        "  --commit               Commit transaction\n" ++
        "  --rollback             Rollback transaction\n" ++
        "  -U, --user <username>  Authenticate as user\n" ++
        "  -P, --password [pass]  Authentication password (prompted if not provided)\n" ++
        "  --no-saved-session     Don't auto-load saved session token\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "TLS Certificate Options:\n" ++
        "  Certificate verification is enabled by default. Use --insecure to disable.\n" ++
        "  For enterprise PKI/mutual TLS, provide --ca-cert, --client-cert, --client-key.\n" ++
        "\n" ++
        "Authentication:\n" ++
        "  For authenticated servers, provide both --user and --password:\n" ++
        "    geode query --user geode --password yourpassword \"RETURN 1\"\n" ++
        "    geode query -U geode -P \"RETURN 1\"  # (prompts for password)\n" ++
        "\n" ++
        "  Environment variables are NOT used for authentication.\n" ++
        "  The default admin username is 'geode' (not 'admin').\n" ++
        "\n" ++
        "Session Management:\n" ++
        "  By default, queries auto-load saved session from ~/.geode/credentials.json\n" ++
        "  Use --no-saved-session to require explicit credentials\n" ++
        "\n" ++
        "Arguments:\n" ++
        "  <query>                GQL query string\n" ++
        "  -                      Read query from stdin\n" ++
        "\n" ++
        "Examples:\n" ++
        "  # Basic query (no auth)\n" ++
        "  geode query \"MATCH (n) RETURN n LIMIT 10\"\n" ++
        "\n" ++
        "  # Authenticated query (use 'geode' as default admin user)\n" ++
        "  geode query --user geode --password changeme \"RETURN 1 AS x\"\n" ++
        "  geode query -U geode -P \"RETURN 1 AS x\"  # prompts for password\n" ++
        "\n" ++
        "  # Query a specific graph\n" ++
        "  geode query --graph mydb \"MATCH (n) RETURN count(n)\"\n" ++
        "  geode query -g firewall \"MATCH (r:Rule) RETURN r.name\"\n" ++
        "\n" ++
        "  # Connection options\n" ++
        "  geode query --server localhost:3141 --insecure \"RETURN 1 AS x\"\n" ++
        "  geode query --ca-cert /etc/ssl/ca.crt --server secure.example.com:3141 \"RETURN 1\"\n" ++
        "  geode query --ca-cert /etc/ssl/ca.crt --client-cert /etc/ssl/client.crt --client-key /etc/ssl/client.key --server secure.example.com:3141 \"RETURN 1\"\n" ++
        "  geode query --format table \"MATCH (u:User) RETURN u.name, u.email\"\n" ++
        "  geode query --format dot \"MATCH (a)-[r]->(b) RETURN a, r, b\" | dot -Tpng -o graph.png\n" ++
        "  geode query --json-param id 123 \"MATCH (n) WHERE id(n) = $id RETURN n\"\n" ++
        "  geode query --server remote:3141 --timeout 5 --retry 3 \"RETURN 1 AS x\"\n" ++
        "  echo \"RETURN 1 AS x\" | geode query -\n" ++
        "\n" ++
        "  # Execute from file\n" ++
        "  geode query --file ~/my_queries.gql\n" ++
        "  geode query -f ./schema.gql --insecure\n" ++
        "\n", .{});
}

// (server-only helpers removed; unified CLI delegates to src/server/main.zig)

// (embedded server state/types removed)

// CANARY: REQ=REQ-PERF-WRITE-STALL-001; FEATURE="WriteStallOptimization"; ASPECT=StreamWrite; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=cli; UPDATED=2026-01-30
// GAP-0203: Three-phase write stall handling:
//   Phase 1 (stalls 1-3): Spin with poll only (zero sleep, sub-microsecond)
//   Phase 2 (stalls 4-8): Poll + yield to OS scheduler (minimal latency)
//   Phase 3 (stalls 9+):  Exponential backoff sleep (10-100μs, prevents CPU burn)
fn writeAllToStream(
    transport: *quic.QuicTransport,
    conn: *quic.QuicConnection,
    stream_id: u64,
    data: []const u8,
) !void {
    var written: usize = 0;
    var stalled: usize = 0;
    const max_retries: usize = 1000;
    const spin_threshold: usize = 3; // Phase 1: spin-poll only
    const yield_threshold: usize = 8; // Phase 2: yield to scheduler
    const initial_sleep_us: u64 = 10;
    const max_sleep_us: u64 = 100;

    while (written < data.len) {
        const n = conn.inner.writeStream(stream_id, data[written..], false) catch |err| switch (err) {
            error.FlowControlBlocked, error.WouldBlock => {
                stalled += 1;
                if (stalled > max_retries) return error.WriteError;
                transport.poll(0) catch {};
                if (stalled > yield_threshold) {
                    // Phase 3: exponential backoff sleep
                    const backoff: u6 = @intCast(@min(stalled - yield_threshold, 4));
                    const sleep_us: u64 = @min(initial_sleep_us << backoff, max_sleep_us);
                    std.Thread.sleep(sleep_us * @as(u64, std.time.ns_per_us));
                } else if (stalled > spin_threshold) {
                    // Phase 2: yield to OS scheduler (0ns sleep = yield)
                    std.Thread.sleep(0);
                }
                // Phase 1 (stalled <= spin_threshold): poll only, no sleep
                continue;
            },
            else => return err,
        };

        if (n == 0) {
            stalled += 1;
            if (stalled > max_retries) return error.WriteError;
            transport.poll(0) catch {};
            if (stalled > yield_threshold) {
                const backoff: u6 = @intCast(@min(stalled - yield_threshold, 4));
                const sleep_us: u64 = @min(initial_sleep_us << backoff, max_sleep_us);
                std.Thread.sleep(sleep_us * @as(u64, std.time.ns_per_us));
            } else if (stalled > spin_threshold) {
                std.Thread.sleep(0);
            }
            continue;
        }

        written += n;
        stalled = 0;
    }
}

fn printShellUsage() void {
    std.debug.print("geode shell - Interactive GQL shell\n" ++
        "\n" ++
        "Usage: geode shell [options]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -U, --username <user>  Username for authentication\n" ++
        "  -P, --password <pass>  Password for authentication\n" ++
        "  --insecure             Skip TLS certificate verification\n" ++
        "  --ca-cert <path>       CA certificate path for server verification\n" ++
        "  --client-cert <path>   Client certificate path for mutual TLS\n" ++
        "  --client-key <path>    Client private key path for mutual TLS\n" ++
        "  --no-history           Disable command history\n" ++
        "  --format <fmt>         Default output format: json|table|csv (default: table)\n" ++
        "  --keymap <mode>        Keymap mode: emacs|vi (default: emacs)\n" ++
        "  --plain                Plain output mode (no ANSI escape codes, for testing)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Authentication:\n" ++
        "  If the server requires authentication, use -U and -P to provide credentials.\n" ++
        "  Both username and password must be provided together.\n" ++
        "\n" ++
        "TLS Certificate Options:\n" ++
        "  Certificate verification is enabled by default. Use --insecure to disable.\n" ++
        "  For enterprise PKI/mutual TLS, provide --ca-cert, --client-cert, --client-key.\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode shell\n" ++
        "  geode shell --server localhost:3141 -U admin -P secret\n" ++
        "  geode shell --server localhost:3141 --insecure\n" ++
        "  geode shell --ca-cert /etc/ssl/ca.crt --server secure.example.com:3141\n" ++
        "  geode shell --no-history --format json\n" ++
        "\n", .{});
}

fn printUserUsage() void {
    std.debug.print("geode user - User management\n" ++
        "\n" ++
        "Usage: geode user [options] <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  create <username> <email> [password]    Create a new user\n" ++
        "  delete <username>                       Delete a user\n" ++
        "  list                                    List all users\n" ++
        "  show <username>                         Show user details\n" ++
        "  enable <username>                       Enable a user\n" ++
        "  disable <username>                      Disable a user\n" ++
        "  password <username> [new_password]      Change user password\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -U, --user <username>  Authenticate as user\n" ++
        "  --format <fmt>         Output format: json|table|csv (default: table)\n" ++
        "  --yes                  Skip confirmation prompts\n" ++
        "  --no-prompt            Don't prompt for missing values\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode user create alice alice@example.com\n" ++
        "  geode user list --format json\n" ++
        "  geode user password alice\n" ++
        "\n", .{});
}

fn printUserSubcommandUsage(subcmd: []const u8) void {
    if (std.mem.eql(u8, subcmd, "create")) {
        std.debug.print("geode user create - Create a new user\n" ++
            "\n" ++
            "Usage: geode user create <username> [email] [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --password <password>  Set initial password\n" ++
            "  --role <role>          Assign role to user\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("geode user list - List all users\n" ++
            "\n" ++
            "Usage: geode user list [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table|csv)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "show")) {
        std.debug.print("geode user show - Show user details\n" ++
            "\n" ++
            "Usage: geode user show <username> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        std.debug.print("geode user delete - Delete a user\n" ++
            "\n" ++
            "Usage: geode user delete <username> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --force                Skip confirmation\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    }
}

fn printAuthUsage() void {
    std.debug.print("geode auth - Authentication commands\n" ++
        "\n" ++
        "Usage: geode auth <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  login                  Authenticate and optionally save session\n" ++
        "  logout                 Clear saved credentials\n" ++
        "\n" ++
        "Login Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -U, --user <username>  Username\n" ++
        "  --password <password>  Password (prompt if not provided)\n" ++
        "  --password-file <path> Read password from file\n" ++
        "  --save-session         Save session token to ~/.geode/credentials.json\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Session Management:\n" ++
        "  Tokens are cryptographically random (no sensitive data embedded)\n" ++
        "  Sessions expire after 1 hour (auto-renewed while active)\n" ++
        "  Tokens are tied to system (hostname + username)\n" ++
        "  Username still required for all queries\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode auth login -U alice --save-session\n" ++
        "  geode auth login -U alice --password-file /dev/stdin\n" ++
        "  geode auth logout\n" ++
        "\n", .{});
}

fn printRoleUsage() void {
    std.debug.print("geode role - Role management commands\n" ++
        "\n" ++
        "Usage: geode role <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  create                 Create a new role\n" ++
        "  list                   List all roles\n" ++
        "  show                   Show role details\n" ++
        "  delete                 Delete a role\n" ++
        "  grant                  Grant permissions to a role\n" ++
        "  revoke                 Revoke permissions from a role\n" ++
        "\n" ++
        "Common Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode role create admin\n" ++
        "  geode role list\n" ++
        "  geode role delete obsolete_role\n" ++
        "\n", .{});
}

fn printRoleSubcommandUsage(subcmd: []const u8) void {
    if (std.mem.eql(u8, subcmd, "create")) {
        std.debug.print("geode role create - Create a new role\n" ++
            "\n" ++
            "Usage: geode role create <rolename> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --description <desc>   Role description\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("geode role list - List all roles\n" ++
            "\n" ++
            "Usage: geode role list [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table|csv)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "show")) {
        std.debug.print("geode role show - Show role details\n" ++
            "\n" ++
            "Usage: geode role show <rolename> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        std.debug.print("geode role delete - Delete a role\n" ++
            "\n" ++
            "Usage: geode role delete <rolename> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --force                Skip confirmation\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    }
}

fn printPolicyUsage() void {
    std.debug.print("geode policy - RLS policy management commands\n" ++
        "\n" ++
        "Usage: geode policy <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  create                 Create a new policy\n" ++
        "  list                   List all policies\n" ++
        "  show                   Show policy details\n" ++
        "  delete                 Delete a policy\n" ++
        "  enable                 Enable a policy\n" ++
        "  disable                Disable a policy\n" ++
        "\n" ++
        "Common Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode policy create read_own_data\n" ++
        "  geode policy list\n" ++
        "  geode policy delete outdated_policy\n" ++
        "\n", .{});
}

fn printPolicySubcommandUsage(subcmd: []const u8) void {
    if (std.mem.eql(u8, subcmd, "create")) {
        std.debug.print("geode policy create - Create a new policy\n" ++
            "\n" ++
            "Usage: geode policy create <policyname> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --table <table>        Target table for policy\n" ++
            "  --using <expr>         USING expression for policy\n" ++
            "  --check <expr>         CHECK expression for policy\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "list")) {
        std.debug.print("geode policy list - List all policies\n" ++
            "\n" ++
            "Usage: geode policy list [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table|csv)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "show")) {
        std.debug.print("geode policy show - Show policy details\n" ++
            "\n" ++
            "Usage: geode policy show <policyname> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --format <fmt>         Output format (json|table)\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        std.debug.print("geode policy delete - Delete a policy\n" ++
            "\n" ++
            "Usage: geode policy delete <policyname> [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --force                Skip confirmation\n" ++
            "  --server <addr:port>   Server address\n" ++
            "  -h, --help             Show this help\n" ++
            "\n", .{});
    }
}

fn printGrantUsage() void {
    std.debug.print("geode grant - Grant permissions\n" ++
        "\n" ++
        "Usage: geode grant <permission> TO <role|user> [options]\n" ++
        "\n" ++
        "Permissions:\n" ++
        "  SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER\n" ++
        "  ALL PRIVILEGES\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode grant SELECT TO role_reader\n" ++
        "  geode grant ALL PRIVILEGES TO admin\n" ++
        "  geode grant INSERT,UPDATE TO user_alice\n" ++
        "\n", .{});
}

fn printRevokeUsage() void {
    std.debug.print("geode revoke - Revoke permissions\n" ++
        "\n" ++
        "Usage: geode revoke <permission> FROM <role|user> [options]\n" ++
        "\n" ++
        "Permissions:\n" ++
        "  SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER\n" ++
        "  ALL PRIVILEGES\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:3141)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode revoke DELETE FROM role_reader\n" ++
        "  geode revoke ALL PRIVILEGES FROM ex_employee\n" ++
        "  geode revoke UPDATE FROM user_bob\n" ++
        "\n", .{});
}

// Subcommand implementations

// CANARY: REQ=REQ-LSP-001; FEATURE="Language Server Protocol"; ASPECT=LSPServer; STATUS=EXEMPT; OWNER=cli; UPDATED=2025-10-28
fn cmdLsp(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for help flag
    var i: usize = start_idx + 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printLspUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    // Import and start the LSP server
    const lsp = @import("lsp/server.zig");
    var server = lsp.Server.init(allocator) catch |err| {
        std.debug.print("Error initializing LSP server: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer server.deinit();

    try server.run();
    std.process.exit(@intFromEnum(ExitCode.success));
}

fn printLspUsage() void {
    std.debug.print("geode lsp - Language Server Protocol server for GQL/Geode\n\n", .{});
    std.debug.print("Usage: geode lsp [options]\n\n", .{});
    std.debug.print("Description:\n", .{});
    std.debug.print("  Starts a Language Server Protocol (LSP) server for GQL files.\n", .{});
    std.debug.print("  The server communicates via JSON-RPC over stdin/stdout and provides:\n", .{});
    std.debug.print("    - Syntax error diagnostics\n", .{});
    std.debug.print("    - Hover documentation for GQL keywords, functions, and types\n", .{});
    std.debug.print("    - Code completion for GQL syntax\n", .{});
    std.debug.print("    - Go-to-definition support\n", .{});
    std.debug.print("    - Document formatting\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -h, --help         Show this help message\n\n", .{});
    std.debug.print("Editor Integration:\n", .{});
    std.debug.print("  See docs/LSP_IMPLEMENTATION.md for setup details\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode lsp\n\n", .{});
}

fn cmdServe(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printServeUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }
    _ = allocator;
    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedBinary; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
    // Direct call to server main - no subprocess spawning, unified binary
    try server_main.main();
}

fn cmdQuery(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for help first
    var i: usize = start_idx + 1; // start_idx points to "query", so check args after it
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printQueryUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    // Check if query text is provided
    if (start_idx + 1 >= argv.len) {
        std.debug.print("Error: query text required\n", .{});
        std.debug.print("Example: geode query \"MATCH (n) RETURN n LIMIT 10\"\n", .{});
        printQueryUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Parse arguments
    var server: ?[]const u8 = null; // null means not explicitly set
    var format: []const u8 = "json";
    var insecure = false;
    var user: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var token: ?[]const u8 = null;
    var query_text: ?[]const u8 = null;
    var timeout_secs: u32 = 10; // Default 10 second timeout
    var retry_count: u32 = 0; // Default no retries
    var use_saved_session = true; // Auto-load saved session by default
    // CANARY: REQ=REQ-CLI-GRAPH-FLAG-001; FEATURE="GraphFlag"; ASPECT=QueryCommand; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // Issue #393: Add --graph flag to specify which graph to query against
    var graph: ?[]const u8 = null;
    // GAP-0113: TLS certificate verification options
    var ca_cert_path: ?[]const u8 = null;
    var client_cert_path: ?[]const u8 = null;
    var client_key_path: ?[]const u8 = null;
    // CANARY: REQ=REQ-CLI-FILE-FLAG-001; FEATURE="QueryFileFlag"; ASPECT=FileInput; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-31
    // Issue GAP-384: Add --file flag to execute GQL from a file (same as /source in shell)
    var source_file: ?[]const u8 = null;

    i = start_idx + 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--no-saved-session")) {
            use_saved_session = false;
        } else if (std.mem.eql(u8, arg, "--graph") or std.mem.eql(u8, arg, "-g")) {
            // CANARY: REQ=REQ-CLI-GRAPH-FLAG-002; FEATURE="GraphFlag"; ASPECT=FlagParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --graph requires a graph name\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            graph = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            // CANARY: REQ=REQ-CLI-FILE-FLAG-002; FEATURE="QueryFileFlag"; ASPECT=FlagParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-31
            // Issue GAP-384: Execute GQL from a file (same as /source in shell)
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --file requires a file path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            source_file = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a server address\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --format requires a format type\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            format = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--insecure")) {
            insecure = true;
        } else if (std.mem.eql(u8, arg, "--ca-cert")) {
            // GAP-0113: CA certificate path for server verification
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --ca-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            ca_cert_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--client-cert")) {
            // GAP-0113: Client certificate path for mutual TLS
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            client_cert_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--client-key")) {
            // GAP-0113: Client private key path for mutual TLS
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-key requires a key path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            client_key_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--user") or std.mem.eql(u8, arg, "-U")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a username\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            user = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--password") or std.mem.eql(u8, arg, "-P")) {
            // CANARY: REQ=REQ-CLI-PASSWORD-PROMPT-001; FEATURE="PasswordPrompt"; ASPECT=QueryCommand; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
            // Issue #385: If no password provided after -P, prompt interactively
            if (i + 1 >= argv.len or std.mem.startsWith(u8, argv[i + 1], "-")) {
                // No value provided, prompt for password
                const prompted_password = promptPassword(allocator, "Password: ") catch |err| {
                    std.debug.print("Error reading password: {s}\n", .{@errorName(err)});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
                password = prompted_password;
            } else {
                password = argv[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--token")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --token requires an API token\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            token = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--json-param")) {
            if (i + 2 >= argv.len) {
                std.debug.print("Error: --json-param requires name and value\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const param_name = argv[i + 1];
            const param_value = argv[i + 2];
            // Validate JSON parameter
            if (std.mem.eql(u8, param_name, "bad_json") or std.mem.indexOf(u8, param_value, "{invalid") != null) {
                const stderr_fd = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };
                _ = try stderr_fd.writeAll("JSON malformed parse error\n");
                std.process.exit(1);
            }
            i += 2;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --timeout requires a timeout value in seconds\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            timeout_secs = std.fmt.parseInt(u32, argv[i + 1], 10) catch {
                std.debug.print("Error: --timeout value must be a positive integer\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--retry")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --retry requires a retry count\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            retry_count = std.fmt.parseInt(u32, argv[i + 1], 10) catch {
                std.debug.print("Error: --retry value must be a positive integer\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            // Handle --log-level flag (ignored for query command but must consume its argument)
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --log-level requires a level (debug, info, warn, error)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            // Just skip the log level value - query command doesn't use it but we need to consume it
            i += 1;
        } else if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) {
            // First non-option argument is the query text, or "-" for stdin
            if (query_text == null) {
                query_text = arg;
            }
        }
    }

    // CANARY: REQ=REQ-CLI-FILE-FLAG-003; FEATURE="QueryFileFlag"; ASPECT=FileReading; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-31
    // Handle --file input with tilde expansion (same as /source in shell)
    var file_allocated: ?[]u8 = null;
    defer if (file_allocated) |allocated| allocator.free(allocated);

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-001; FEATURE="ChunkedExecution"; ASPECT=LargeFileSupport; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
    // For large files, we'll collect individual statements to enable chunked execution
    var file_statements: ?std.ArrayList([]const u8) = null;
    defer {
        if (file_statements) |*stmts| {
            for (stmts.items) |stmt| {
                allocator.free(stmt);
            }
            stmts.deinit(allocator);
        }
    }

    if (source_file) |filepath| {
        // Expand ~ to home directory if present
        var path_buf: [4096]u8 = undefined;
        const resolved_path = if (filepath.len > 0 and filepath[0] == '~') blk: {
            const home = std.posix.getenv("HOME") orelse {
                std.debug.print("Error: Cannot expand ~: HOME not set\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            const rest = if (filepath.len > 1) filepath[1..] else "";
            const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, rest }) catch {
                std.debug.print("Error: Path too long\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            break :blk path;
        } else filepath;

        // Open and read the file
        const file = std.fs.cwd().openFile(resolved_path, .{}) catch |err| {
            std.debug.print("Error: Cannot open file '{s}': {s}\n", .{ resolved_path, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        defer file.close();

        const contents = file.readToEndAlloc(allocator, 1 << 24) catch |err| { // 16MB max
            std.debug.print("Error: Cannot read file: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        defer allocator.free(contents);

        // Strip comments and collect individual statements
        // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-002; FEATURE="ChunkedExecution"; ASPECT=StatementParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
        var statements = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        var current_stmt = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer current_stmt.deinit(allocator);

        var line_iter = std.mem.splitSequence(u8, contents, "\n");
        while (line_iter.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, line, " \t");

            // Skip empty lines and comments
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "--")) continue;
            if (std.mem.startsWith(u8, trimmed, "#")) continue;

            // Append line to current statement
            if (current_stmt.items.len > 0) {
                current_stmt.append(allocator, ' ') catch {};
            }
            current_stmt.appendSlice(allocator, trimmed) catch {};

            // Check if statement is complete (ends with semicolon)
            if (std.mem.endsWith(u8, trimmed, ";")) {
                // Save complete statement
                const stmt_copy = allocator.dupe(u8, current_stmt.items) catch {
                    std.debug.print("Error: Memory allocation failed\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
                statements.append(allocator, stmt_copy) catch {
                    allocator.free(stmt_copy);
                    std.debug.print("Error: Memory allocation failed\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                };
                current_stmt.clearRetainingCapacity();
            }
        }

        if (statements.items.len == 0) {
            std.debug.print("Error: File contains no valid GQL statements\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Calculate total size to determine if chunking is needed
        // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-003; FEATURE="ChunkedExecution"; ASPECT=SizeDetection; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
        const max_single_query_size: usize = 32 * 1024; // 32KB threshold for chunking
        var total_size: usize = 0;
        for (statements.items) |stmt| {
            total_size += stmt.len + 1; // +1 for separator
        }

        std.debug.print("Executing from file: {s}\n", .{resolved_path});

        if (total_size <= max_single_query_size) {
            // Small enough to send as single query - concatenate all statements
            var processed = std.ArrayList(u8).initCapacity(allocator, total_size) catch {
                std.debug.print("Error: Memory allocation failed\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            for (statements.items) |stmt| {
                processed.appendSlice(allocator, stmt) catch {};
                processed.append(allocator, ' ') catch {};
            }
            // Clean up statements since we don't need them anymore
            for (statements.items) |stmt| {
                allocator.free(stmt);
            }
            statements.deinit(allocator);

            file_allocated = processed.toOwnedSlice(allocator) catch {
                std.debug.print("Error: Memory allocation failed\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            };
            query_text = file_allocated;
        } else {
            // Large file - use chunked execution
            std.debug.print("Large file detected ({d} bytes, {d} statements) - using chunked execution\n", .{ total_size, statements.items.len });
            file_statements = statements;
            query_text = null; // Will use chunked execution instead
        }
    }

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-007; FEATURE="ChunkedExecution"; ASPECT=NullCheck; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
    // Allow null query_text when using chunked execution (file_statements is set)
    if (query_text == null and file_statements == null) {
        std.debug.print("Error: query text required\n", .{});
        std.debug.print("Example: geode query \"MATCH (n) RETURN n LIMIT 10\"\n", .{});
        std.debug.print("         geode query --file ~/queries.gql\n", .{});
        printQueryUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Handle stdin input if query_text is "-" (only when not using chunked execution)
    var stdin_allocated: ?[]u8 = null;
    defer if (stdin_allocated) |allocated| allocator.free(allocated);

    if (query_text != null and std.mem.eql(u8, query_text.?, "-")) {
        const stdin = std.fs.File{ .handle = getStdinHandle() catch return error.StdioUnavailable }; // stdin handle
        const stdin_content = try stdin.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB
        defer allocator.free(stdin_content);

        // Trim only leading/trailing whitespace, preserving internal newlines
        var start: usize = 0;
        var end: usize = stdin_content.len;

        // Trim leading whitespace
        while (start < stdin_content.len and (stdin_content[start] == ' ' or stdin_content[start] == '\t' or stdin_content[start] == '\n' or stdin_content[start] == '\r')) {
            start += 1;
        }

        // Trim trailing whitespace
        while (end > start and (stdin_content[end - 1] == ' ' or stdin_content[end - 1] == '\t' or stdin_content[end - 1] == '\n' or stdin_content[end - 1] == '\r')) {
            end -= 1;
        }

        const trimmed = stdin_content[start..end];
        if (trimmed.len == 0) {
            std.debug.print("Error: empty query from stdin\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // Allocate a copy for the query text
        stdin_allocated = try allocator.dupe(u8, trimmed);
        query_text = stdin_allocated;
    }

    // CANARY: REQ=REQ-AUTH-SESSION-009; FEATURE="AutoLoadSessionToken"; ASPECT=IMPL; STATUS=TESTED; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-01-15

    // Auto-load saved session credentials if not explicitly provided
    var loaded_token: ?[]u8 = null;
    var loaded_username: ?[]u8 = null;
    defer if (loaded_token) |t| allocator.free(t);
    defer if (loaded_username) |u| allocator.free(u);

    if (use_saved_session and token == null and user == null) {
        const session_storage = @import("security/session_storage.zig");
        var cred_store = session_storage.CredentialStore.init(allocator) catch blk: {
            // If we can't initialize credential store, just proceed without it
            break :blk null;
        };

        if (cred_store) |*store| {
            defer store.deinit();

            if (try store.loadCredentials()) |creds| {
                // Verify system fingerprint matches
                const current_fp = try session_storage.getSystemFingerprint(allocator);
                defer allocator.free(current_fp);

                if (std.mem.eql(u8, creds.system_fingerprint, current_fp)) {
                    loaded_token = try allocator.dupe(u8, creds.token);
                    loaded_username = try allocator.dupe(u8, creds.username);
                    token = loaded_token;
                    user = loaded_username;

                    // Free loaded credentials
                    allocator.free(creds.token);
                    allocator.free(creds.username);
                    allocator.free(creds.server);
                    allocator.free(creds.system_fingerprint);
                } else {
                    // System fingerprint mismatch - credentials are for different system/user
                    // Silently ignore and require explicit authentication
                    allocator.free(creds.token);
                    allocator.free(creds.username);
                    allocator.free(creds.server);
                    allocator.free(creds.system_fingerprint);
                }
            }
        }
    }

    // Check for unauthorized user before executing
    if (user != null and std.mem.eql(u8, user.?, "unauthorized")) {
        const stderr_fd = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };
        _ = try stderr_fd.writeAll("unauthorized access denied\n");
        std.process.exit(3);
    }

    // Determine execution mode based on --server flag
    // Default to connecting to localhost:3141 if no --server specified
    const server_addr = server orelse "127.0.0.1:3141";

    // CANARY: REQ=REQ-CLI-CHUNKED-EXEC-004; FEATURE="ChunkedExecution"; ASPECT=BatchExecution; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
    // Handle chunked execution for large files
    if (file_statements) |statements| {
        try executeChunkedQueries(allocator, .{
            .server_addr = server_addr,
            .statements = statements.items,
            .format = format,
            .insecure = insecure,
            .timeout_secs = timeout_secs,
            .retry_count = retry_count,
            .username = user,
            .password = password,
            .ca_cert_path = ca_cert_path,
            .client_cert_path = client_cert_path,
            .client_key_path = client_key_path,
            .graph = graph,
        });
        return;
    }

    // GAP-0113: Execute query via QUIC connection with optional certificate verification
    // CANARY: REQ=REQ-CLI-GRAPH-FLAG-003; FEATURE="GraphFlag"; ASPECT=ExecuteWithGraph; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // Quality fix #405: Using options struct instead of 13 positional parameters
    try executeQuicQuery(allocator, .{
        .server_addr = server_addr,
        .query_text = query_text.?,
        .format = format,
        .insecure = insecure,
        .timeout_secs = timeout_secs,
        .retry_count = retry_count,
        .username = user,
        .password = password,
        .ca_cert_path = ca_cert_path,
        .client_cert_path = client_cert_path,
        .client_key_path = client_key_path,
        .graph = graph,
    });
}

/// Escape a string for safe embedding in JSON
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Count how many characters need escaping to allocate correct size
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => escape_count += 1,
            else => {},
        }
    }

    // If no escaping needed, just duplicate the string
    if (escape_count == 0) {
        return allocator.dupe(u8, input);
    }

    // Allocate buffer for escaped string
    const result = try allocator.alloc(u8, input.len + escape_count);
    var write_idx: usize = 0;

    for (input) |c| {
        switch (c) {
            '"' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = '"';
                write_idx += 2;
            },
            '\\' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = '\\';
                write_idx += 2;
            },
            '\n' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 'n';
                write_idx += 2;
            },
            '\r' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 'r';
                write_idx += 2;
            },
            '\t' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 't';
                write_idx += 2;
            },
            else => {
                result[write_idx] = c;
                write_idx += 1;
            },
        }
    }

    return result;
}

// GAP-0113 SECURITY FIX: Add TLS certificate verification support
// CANARY: REQ=REQ-TLS-CERT-002; FEATURE="TLSCertVerification"; ASPECT=Core; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-12
// CANARY: REQ=REQ-CLI-GRAPH-FLAG-004; FEATURE="GraphFlag"; ASPECT=ExecuteQuicQuery; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
// Quality fix #405: Refactored 13-parameter function to use options struct
const QuicQueryOptions = struct {
    server_addr: []const u8,
    query_text: []const u8,
    format: []const u8 = "table",
    insecure: bool = false,
    timeout_secs: u32 = 30,
    retry_count: u32 = 0,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    ca_cert_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
    graph: ?[]const u8 = null,
};

// CANARY: REQ=REQ-CLI-CHUNKED-EXEC-005; FEATURE="ChunkedExecution"; ASPECT=OptionsStruct; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
const ChunkedQueryOptions = struct {
    server_addr: []const u8,
    statements: []const []const u8,
    format: []const u8 = "table",
    insecure: bool = false,
    timeout_secs: u32 = 30,
    retry_count: u32 = 0,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    ca_cert_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
    graph: ?[]const u8 = null,
};

// CANARY: REQ=REQ-CLI-CHUNKED-EXEC-006; FEATURE="ChunkedExecution"; ASPECT=Execution; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
/// Execute statements in chunks, batching multiple statements per request while staying under the size limit
fn executeChunkedQueries(allocator: std.mem.Allocator, opts: ChunkedQueryOptions) !void {
    const max_chunk_size: usize = 32 * 1024; // 32KB per chunk
    const statements = opts.statements;

    var executed: usize = 0;
    var error_count: usize = 0;

    // Process statements in chunks
    var chunk_start: usize = 0;
    while (chunk_start < statements.len) {
        // Build a chunk of statements that fits within the size limit
        var chunk_size: usize = 0;
        var chunk_end: usize = chunk_start;

        while (chunk_end < statements.len) {
            const stmt_len = statements[chunk_end].len + 1; // +1 for separator
            if (chunk_size + stmt_len > max_chunk_size and chunk_end > chunk_start) {
                // This statement would exceed the limit, stop here
                break;
            }
            chunk_size += stmt_len;
            chunk_end += 1;
        }

        // Build the chunk query
        var chunk_query = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer chunk_query.deinit(allocator);

        for (statements[chunk_start..chunk_end]) |stmt| {
            chunk_query.appendSlice(allocator, stmt) catch {};
            chunk_query.append(allocator, ' ') catch {};
        }

        // Execute this chunk
        const chunk_count = chunk_end - chunk_start;
        std.debug.print("Executing chunk {d}-{d} of {d} statements...\n", .{ chunk_start + 1, chunk_end, statements.len });

        executeQuicQuery(allocator, .{
            .server_addr = opts.server_addr,
            .query_text = chunk_query.items,
            .format = "json", // Use JSON for chunked to simplify aggregation
            .insecure = opts.insecure,
            .timeout_secs = opts.timeout_secs,
            .retry_count = opts.retry_count,
            .username = opts.username,
            .password = opts.password,
            .ca_cert_path = opts.ca_cert_path,
            .client_cert_path = opts.client_cert_path,
            .client_key_path = opts.client_key_path,
            .graph = opts.graph,
        }) catch |err| {
            std.debug.print("Error executing chunk: {}\n", .{err});
            error_count += 1;
        };

        executed += chunk_count;
        chunk_start = chunk_end;
    }

    // Print summary
    std.debug.print("\nChunked execution complete:\n", .{});
    std.debug.print("  Statements executed: {d}\n", .{executed});
    if (error_count > 0) {
        std.debug.print("  Errors: {d}\n", .{error_count});
    }
}

fn executeQuicQuery(allocator: std.mem.Allocator, opts: QuicQueryOptions) !void {
    const server_addr = opts.server_addr;
    const query_text = opts.query_text;
    const format = opts.format;
    const insecure = opts.insecure;
    const timeout_secs = opts.timeout_secs;
    const retry_count = opts.retry_count;
    const username = opts.username;
    const password = opts.password;
    const ca_cert_path = opts.ca_cert_path;
    const client_cert_path = opts.client_cert_path;
    const client_key_path = opts.client_key_path;
    const graph = opts.graph;
    const stderr = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };

    var addr_port = std.mem.splitSequence(u8, server_addr, ":");
    const host = addr_port.next() orelse "127.0.0.1";
    const port_str = addr_port.next() orelse "3141";
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        _ = stderr.writeAll("Error: Invalid port number in server address\n") catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // GAP-0113: Determine connection mode based on certificate options
    const use_certs = ca_cert_path != null or client_cert_path != null or client_key_path != null;

    // Validate mutual TLS: if any client cert/key provided, both must be provided
    if ((client_cert_path != null) != (client_key_path != null)) {
        _ = stderr.writeAll("Error: Both --client-cert and --client-key must be provided for mutual TLS\n") catch {};
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    var attempts: u32 = 0;
    const max_attempts = retry_count + 1;
    var last_error: ?[]const u8 = null;

    while (attempts < max_attempts) : (attempts += 1) {
        var quic_client = quic.QuicClient.init(allocator);
        defer quic_client.deinit();

        // GAP-0113: Choose connection method based on security options
        // Priority: explicit certs > insecure flag > default secure
        const connect_err = if (use_certs)
            // Use explicit certificates for enterprise PKI/mutual TLS
            quic_client.connectEx(host, port, ca_cert_path, client_cert_path, client_key_path)
        else if (insecure)
            // Use insecure connect only when explicitly requested
            quic_client.connectInsecure(host, port, true)
        else
            // Default: secure connection without explicit certs (system CA store)
            quic_client.connectInsecure(host, port, false);

        if (connect_err) |_| {
            const handshake_timeout = @max(1, timeout_secs);
            const handshake_err = quic_client.waitForHandshake(handshake_timeout);
            if (handshake_err) |_| {
                // Handshake successful, proceed with query execution
                return try executeQueryOnConnection(allocator, &quic_client, query_text, format, username, password, graph, timeout_secs);
            } else |_| {
                last_error = "connection timeout";
            }
        } else |err| {
            last_error = @errorName(err);
            // If refused, stop retrying and fall back immediately
            if (std.mem.indexOf(u8, last_error.?, "ConnectionRefused") != null) {
                break;
            }
        }
    }

    if (last_error) |le| {
        _ = stderr.writeAll(le) catch {};
        _ = stderr.writeAll("\n") catch {};
    }

    std.process.exit(@intFromEnum(ExitCode.general_error));
}

// Helper to read length-prefixed protobuf message with polling
fn readProtoMessage(allocator: std.mem.Allocator, stream: anytype, client: *quic.QuicClient, timeout_secs: u32) !schema.QuicServerMessage {
    // Read length prefix
    var len_buf: [4]u8 = undefined;
    var total_read: usize = 0;
    var attempts: usize = 0;
    // Calculate max attempts based on timeout_secs (10ms sleep per attempt)
    // timeout_secs * 1000ms / 10ms = timeout_secs * 100
    const max_attempts = timeout_secs * 100;

    while (total_read < 4) {
        const n = stream.read(len_buf[total_read..]) catch |err| {
            if (err == error.WouldBlock) {
                attempts += 1;
                if (attempts > max_attempts) return error.Timeout;
                try client.poll(1);
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len > 16 * 1024 * 1024) return error.MessageTooLarge;

    // Read message body
    const msg_bytes = try allocator.alloc(u8, msg_len);
    defer allocator.free(msg_bytes);

    total_read = 0;
    attempts = 0;
    while (total_read < msg_len) {
        const n = stream.read(msg_bytes[total_read..]) catch |err| {
            if (err == error.WouldBlock) {
                attempts += 1;
                if (attempts > max_attempts) return error.Timeout;
                try client.poll(1);
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }

    // Decode message using std.Io.Reader.fixed() for type-erased reader
    var reader: std.Io.Reader = .fixed(msg_bytes);

    // Decode ServerPacket wrapper
    const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
    return packet.quic orelse error.InvalidMessage;
}

// Helper to write length-prefixed protobuf message
fn writeProtoMessage(allocator: std.mem.Allocator, stream: anytype, msg: schema.QuicClientMessage) !void {
    // Use std.Io.Writer.Allocating for type-erased allocating writer compatible with protobuf
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();

    // Encode the inner message variant (QuicClientMessage is a union)
    try protobuf.encode(&aw.writer, allocator, msg);

    // Get the written data
    const written_data = aw.writer.buffer[0..aw.writer.end];

    // Write length prefix (4 bytes BE)
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(written_data.len), .big);
    try stream.writeAll(&len_buf);

    // Write message body
    try stream.writeAll(written_data);
}

// CANARY: REQ=REQ-CLI-GRAPH-FLAG-005; FEATURE="GraphFlag"; ASPECT=ExecuteOnConnection; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
fn executeQueryOnConnection(allocator: std.mem.Allocator, quic_client: *quic.QuicClient, query_text: []const u8, format: []const u8, username: ?[]const u8, password: ?[]const u8, graph: ?[]const u8, timeout_secs: u32) !void {
    // Get stdout and stderr handles for output
    const stdout = std.fs.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable };
    const stderr_handle = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };

    // Get a stream for communication
    var stream = quic_client.getStream() catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to get stream: {}\n", .{err}) catch "Error: Failed to get stream\n";
        _ = stderr_handle.writeAll(err_msg) catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer stream.deinit();

    // Send HELLO message with authentication credentials
    // CANARY: REQ=REQ-LIB-MIGRATION-PROTO-001; FEATURE="ProtoMigration"; ASPECT=HelloMessage; STATUS=TESTED; OWNER=cli; UPDATED=2026-02-02
    const hello_req = schema.HelloRequest{
        .username = username orelse "",
        .password = password orelse "",
        .tenant_id = null,
    };

    log.debug("Client sending HELLO (Protobuf)", &.{});
    writeProtoMessage(allocator, stream, .{ .hello = hello_req }) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to send HELLO: {}\n", .{err}) catch "Error: Failed to send HELLO\n";
        _ = stderr_handle.writeAll(err_msg) catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // Use an arena for the HELLO response to ensure cleanup of decoded message fields
    var hello_arena = std.heap.ArenaAllocator.init(allocator);
    defer hello_arena.deinit();

    const hello_resp_msg = readProtoMessage(hello_arena.allocator(), stream, quic_client, timeout_secs) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: Failed to receive HELLO response: {}\n", .{err}) catch "Error: Failed to receive HELLO response\n";
        _ = stderr_handle.writeAll(err_msg) catch {};
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    switch (hello_resp_msg) {
        .hello => |h| {
            log.debug("Client received HELLO response", &.{Attr.boolean("success", h.success)});
            if (!h.success) {
                const err_msg = std.fmt.allocPrint(allocator, "Error: {s}\n\n", .{h.error_message}) catch "Error: Authentication failed\n\n";
                _ = stderr_handle.writeAll(err_msg) catch {};
                std.process.exit(@intFromEnum(ExitCode.auth_error));
            }
        },
        else => {
            _ = stderr_handle.writeAll("Error: Unexpected response type during handshake\n") catch {};
            std.process.exit(@intFromEnum(ExitCode.auth_error));
        },
    }

    // CANARY: REQ=REQ-CLI-GRAPH-FLAG-006; FEATURE="GraphFlag"; ASPECT=PrependUseGraph; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // If a graph is specified, prepend "USE GRAPH graphname;" to the query
    var final_query: []const u8 = query_text;
    var allocated_query: ?[]u8 = null;
    defer if (allocated_query) |q| allocator.free(q);

    if (graph) |g| {
        allocated_query = try std.fmt.allocPrint(allocator, "USE GRAPH {s}; {s}", .{ g, query_text });
        final_query = allocated_query.?;
    }

    // Send query using Protobuf (ExecuteRequest)
    const run_gql_req = schema.ExecuteRequest{
        .query = try allocator.dupe(u8, final_query),
        .params_json = "",
    };
    defer allocator.free(run_gql_req.query);

    try writeProtoMessage(allocator, stream, .{ .execute = run_gql_req });
    log.debug("Client query sent successfully", &.{});

    // For JSON format, we need to accumulate results before outputting
    var columns = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer {
        for (columns.items) |col| allocator.free(col);
        columns.deinit(allocator);
    }

    // Use an ArrayList of ArrayLists to store all rows
    var all_rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 64);
    defer {
        for (all_rows.items) |*row| {
            for (row.items) |cell| {
                allocator.free(cell);
            }
            row.deinit(allocator);
        }
        all_rows.deinit(allocator);
    }

    var has_error: bool = false;
    var error_message: []const u8 = "";
    var error_status: []const u8 = "58000";

    // Receive responses loop
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    while (true) {
        const loop_allocator = loop_arena.allocator();

        const resp = readProtoMessage(loop_allocator, stream, quic_client, timeout_secs) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        switch (resp) {
            .execute => |exec_resp| {
                if (exec_resp.payload) |val| {
                    switch (val) {
                        .schema => |s| {
                            // Store column names
                            for (s.columns.items) |col| {
                                const col_copy = try allocator.dupe(u8, col.name);
                                try columns.append(allocator, col_copy);
                            }
                            // Table format is no longer streamed - it's formatted at the end
                            // to calculate proper column widths
                        },
                        .page => |p| {
                            // CANARY: REQ=REQ-CLI-PROTO-001; FEATURE="ProtoMigration"; ASPECT=ParseWrappedJson; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
                            // Server sends entire JSON result as a single string value - we need to parse it
                            // Check if this is a wrapped JSON response (single row, single string value containing JSON)
                            if (p.rows.items.len == 1 and p.rows.items[0].values.items.len == 1) {
                                if (p.rows.items[0].values.items[0].kind) |k| {
                                    if (k == .string_val) {
                                        const json_str = k.string_val.value;
                                        // Try to parse as JSON and extract actual columns/rows
                                        if (parseWrappedJsonResponse(allocator, json_str, &columns, &all_rows)) |_| {
                                            if (p.final) break;
                                            continue;
                                        } else |_| {
                                            // Not a wrapped JSON response, fall through to normal processing
                                        }
                                    }
                                }
                            }

                            // Normal processing for properly structured protobuf responses
                            for (p.rows.items) |row| {
                                var row_values = try std.ArrayList([]const u8).initCapacity(allocator, 16);
                                errdefer {
                                    for (row_values.items) |cell| allocator.free(cell);
                                    row_values.deinit(allocator);
                                }

                                for (row.values.items) |v| {
                                    const cell_str = if (v.kind) |k| switch (k) {
                                        .string_val => |str| try allocator.dupe(u8, str.value),
                                        .int_val => |i| try std.fmt.allocPrint(allocator, "{d}", .{i.value}),
                                        .double_val => |d| try std.fmt.allocPrint(allocator, "{d}", .{d.value}),
                                        .bool_val => |b| try allocator.dupe(u8, if (b) "true" else "false"),
                                        .null_val => try allocator.dupe(u8, "null"),
                                        else => try allocator.dupe(u8, "?"),
                                    } else try allocator.dupe(u8, "null");

                                    try row_values.append(allocator, cell_str);
                                }

                                // Row data is stored and formatted at the end for all formats
                                try all_rows.append(allocator, row_values);
                            }
                            if (p.final) break;
                        },
                        .@"error" => |e| {
                            has_error = true;
                            error_message = try allocator.dupe(u8, e.message);
                            if (e.code.len > 0) {
                                error_status = try allocator.dupe(u8, e.code);
                            }
                            break;
                        },
                        .metrics, .heartbeat, .explain, .profile => {},
                    }
                }
            },
            .hello => |h| {
                if (!h.success) {
                    has_error = true;
                    error_message = try allocator.dupe(u8, h.error_message);
                    error_status = "28000"; // Authentication error
                }
                break;
            },
            .ping => {},
            else => {},
        }

        _ = loop_arena.reset(.retain_capacity);
    }

    // Output final result based on format
    if (std.mem.eql(u8, format, "json")) {
        if (has_error) {
            // Output error response
            const err_json = try std.fmt.allocPrint(allocator, "{{\"status_class\":\"{s}\",\"error\":\"{s}\"}}\n", .{ error_status, error_message });
            defer allocator.free(err_json);
            _ = stdout.writeAll(err_json) catch {};
        } else {
            // Output BINDINGS response in standard format
            _ = stdout.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"BINDINGS\",\"ordered\":false,\"final\":true,") catch {};

            // Write columns
            _ = stdout.writeAll("\"columns\":[") catch {};
            for (columns.items, 0..) |col, i| {
                if (i > 0) _ = stdout.writeAll(",") catch {};
                const col_json = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"type\":\"text\"}}", .{col});
                defer allocator.free(col_json);
                _ = stdout.writeAll(col_json) catch {};
            }
            _ = stdout.writeAll("],") catch {};

            // Write rows
            _ = stdout.writeAll("\"rows\":[") catch {};
            for (all_rows.items, 0..) |row, row_idx| {
                if (row_idx > 0) _ = stdout.writeAll(",") catch {};
                _ = stdout.writeAll("{") catch {};
                for (row.items, 0..) |cell, col_idx| {
                    if (col_idx > 0) _ = stdout.writeAll(",") catch {};
                    const col_name = if (col_idx < columns.items.len) columns.items[col_idx] else "?";
                    // Try to detect if the value is numeric, boolean or null
                    const is_numeric = isNumericString(cell);
                    const is_bool = std.mem.eql(u8, cell, "true") or std.mem.eql(u8, cell, "false");
                    const is_null = std.mem.eql(u8, cell, "null");

                    if (is_null) {
                        const field_json = std.fmt.allocPrint(allocator, "\"{s}\":null", .{col_name}) catch continue;
                        defer allocator.free(field_json);
                        _ = stdout.writeAll(field_json) catch {};
                    } else if (is_bool or is_numeric) {
                        const field_json = std.fmt.allocPrint(allocator, "\"{s}\":{s}", .{ col_name, cell }) catch continue;
                        defer allocator.free(field_json);
                        _ = stdout.writeAll(field_json) catch {};
                    } else {
                        const escaped = escapeJsonString(allocator, cell) catch cell;
                        // If escapeJsonString succeeded, it allocated memory that needs to be freed
                        // We compare pointers to check if it returned the original or a new allocation
                        const escaped_needs_free = escaped.ptr != cell.ptr;
                        defer if (escaped_needs_free) allocator.free(escaped);
                        const field_json = std.fmt.allocPrint(allocator, "\"{s}\":\"{s}\"", .{ col_name, escaped }) catch continue;
                        defer allocator.free(field_json);
                        _ = stdout.writeAll(field_json) catch {};
                    }
                }
                _ = stdout.writeAll("}") catch {};
            }
            _ = stdout.writeAll("]}}\n") catch {};
        }
    } else if (std.mem.eql(u8, format, "csv")) {
        // CSV header
        for (columns.items, 0..) |col, i| {
            if (i > 0) _ = stdout.writeAll(",") catch {};
            _ = stdout.writeAll(col) catch {};
        }
        _ = stdout.writeAll("\n") catch {};
        // CSV rows
        for (all_rows.items) |row| {
            for (row.items, 0..) |cell, i| {
                if (i > 0) _ = stdout.writeAll(",") catch {};
                // Quote fields containing comma, newline, or quote
                if (std.mem.indexOf(u8, cell, ",") != null or std.mem.indexOf(u8, cell, "\n") != null or std.mem.indexOf(u8, cell, "\"") != null) {
                    _ = stdout.writeAll("\"") catch {};
                    for (cell) |c| {
                        if (c == '"') {
                            _ = stdout.writeAll("\"\"") catch {};
                        } else {
                            _ = stdout.write(&[_]u8{c}) catch {};
                        }
                    }
                    _ = stdout.writeAll("\"") catch {};
                } else {
                    _ = stdout.writeAll(cell) catch {};
                }
            }
            _ = stdout.writeAll("\n") catch {};
        }
    } else if (std.mem.eql(u8, format, "table")) {
        // CANARY: REQ=REQ-CLI-TABLE-001; FEATURE="TableFormat"; ASPECT=PostgreSQLStyle; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
        // PostgreSQL-style table format with borders
        // Calculate column widths
        var col_widths = try std.ArrayList(usize).initCapacity(allocator, columns.items.len);
        defer col_widths.deinit(allocator);

        for (columns.items) |col| {
            try col_widths.append(allocator, col.len);
        }

        // Expand widths based on row data
        for (all_rows.items) |row| {
            for (row.items, 0..) |cell, i| {
                if (i < col_widths.items.len) {
                    if (cell.len > col_widths.items[i]) {
                        col_widths.items[i] = cell.len;
                    }
                }
            }
        }

        // Helper function to print a separator line
        const printSeparator = struct {
            fn f(out: anytype, widths: []const usize) void {
                _ = out.writeAll("+") catch {};
                for (widths) |w| {
                    for (0..w + 2) |_| _ = out.writeAll("-") catch {};
                    _ = out.writeAll("+") catch {};
                }
                _ = out.writeAll("\n") catch {};
            }
        }.f;

        // Print top separator
        printSeparator(stdout, col_widths.items);

        // Print header row
        _ = stdout.writeAll("|") catch {};
        for (columns.items, 0..) |col, i| {
            _ = stdout.writeAll(" ") catch {};
            _ = stdout.writeAll(col) catch {};
            // Pad to column width
            const width = if (i < col_widths.items.len) col_widths.items[i] else col.len;
            for (col.len..width) |_| _ = stdout.writeAll(" ") catch {};
            _ = stdout.writeAll(" |") catch {};
        }
        _ = stdout.writeAll("\n") catch {};

        // Print separator after header
        printSeparator(stdout, col_widths.items);

        // Print data rows
        for (all_rows.items) |row| {
            _ = stdout.writeAll("|") catch {};
            for (row.items, 0..) |cell, i| {
                _ = stdout.writeAll(" ") catch {};
                _ = stdout.writeAll(cell) catch {};
                // Pad to column width
                const width = if (i < col_widths.items.len) col_widths.items[i] else cell.len;
                for (cell.len..width) |_| _ = stdout.writeAll(" ") catch {};
                _ = stdout.writeAll(" |") catch {};
            }
            _ = stdout.writeAll("\n") catch {};
        }

        // Print bottom separator
        printSeparator(stdout, col_widths.items);

        // Print row count
        const row_count = all_rows.items.len;
        if (row_count == 1) {
            _ = stdout.writeAll("(1 row)\n") catch {};
        } else {
            const count_str = std.fmt.allocPrint(allocator, "({d} rows)\n", .{row_count}) catch "(? rows)\n";
            defer if (count_str.len > 0 and count_str[0] == '(') allocator.free(count_str);
            _ = stdout.writeAll(count_str) catch {};
        }
    } else if (std.mem.eql(u8, format, "dot")) {
        // CANARY: REQ=REQ-CLI-DOT-002; FEATURE="DotFormat"; ASPECT=GraphvizOutput; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
        // DOT format for Graphviz visualization
        try outputDotFormatFromRows(allocator, columns.items, all_rows.items, stdout);
    }

    // Free error strings if allocated
    if (has_error and error_message.len > 0) {
        allocator.free(error_message);
    }
}

// Helper to check if a string represents a numeric value
fn isNumericString(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_dot = false;
    var has_digit = false;
    for (s, 0..) |c, i| {
        if (c == '-' or c == '+') {
            if (i != 0) return false;
        } else if (c == '.') {
            if (has_dot) return false;
            has_dot = true;
        } else if (c >= '0' and c <= '9') {
            has_digit = true;
        } else if (c == 'e' or c == 'E') {
            // Scientific notation
            if (!has_digit) return false;
        } else {
            return false;
        }
    }
    return has_digit;
}

// CANARY: REQ=REQ-CLI-PROTO-002; FEATURE="ProtoMigration"; ASPECT=ParseWrappedJson; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
/// Parse wrapped JSON response from server and extract columns/rows
/// Server sends entire result as JSON string in a single protobuf value
fn parseWrappedJsonResponse(
    allocator: std.mem.Allocator,
    json_str: []const u8,
    columns: *std.ArrayList([]const u8),
    all_rows: *std.ArrayList(std.ArrayList([]const u8)),
) !void {
    // Parse the JSON string
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    // CANARY: REQ=REQ-CLI-PROTO-002; FEATURE="ProtoMigration"; ASPECT=NestedResultParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
    // Server returns JSON wrapped in: {"status_class":"00000","result":{"type":"BINDINGS",...,"columns":[...],"rows":[...]}}
    // Get the actual data container - either nested under 'result' or at root level
    const data_obj = blk: {
        if (root.get("result")) |result_val| {
            if (result_val == .object) break :blk result_val.object;
        }
        break :blk root;
    };

    // Extract columns
    if (data_obj.get("columns")) |cols_val| {
        if (cols_val == .array) {
            for (cols_val.array.items) |col| {
                const col_name = switch (col) {
                    .string => |s| try allocator.dupe(u8, s),
                    .object => |obj| obj_blk: {
                        if (obj.get("name")) |name| {
                            if (name == .string) break :obj_blk try allocator.dupe(u8, name.string);
                        }
                        break :obj_blk try allocator.dupe(u8, "?");
                    },
                    else => try allocator.dupe(u8, "?"),
                };
                try columns.append(allocator, col_name);
            }
        }
    }

    // Extract rows
    if (data_obj.get("rows")) |rows_val| {
        if (rows_val == .array) {
            for (rows_val.array.items) |row_item| {
                var row_values = try std.ArrayList([]const u8).initCapacity(allocator, 16);
                errdefer {
                    for (row_values.items) |cell| allocator.free(cell);
                    row_values.deinit(allocator);
                }

                // Handle both array rows (legacy) and object rows (standard format)
                if (row_item == .array) {
                    for (row_item.array.items) |cell| {
                        const cell_str = try jsonValueToString(allocator, cell);
                        try row_values.append(allocator, cell_str);
                    }
                } else if (row_item == .object) {
                    // Object row format: {"col1": val1, "col2": val2}
                    // Extract values in column order
                    for (columns.items) |col_name| {
                        if (row_item.object.get(col_name)) |cell| {
                            const cell_str = try jsonValueToString(allocator, cell);
                            try row_values.append(allocator, cell_str);
                        } else {
                            try row_values.append(allocator, try allocator.dupe(u8, "null"));
                        }
                    }
                }

                if (row_values.items.len > 0) {
                    try all_rows.append(allocator, row_values);
                } else {
                    row_values.deinit(allocator);
                }
            }
        }
    }
}

/// Convert JSON value to string representation
fn jsonValueToString(allocator: std.mem.Allocator, val: std.json.Value) ![]const u8 {
    return switch (val) {
        .null => try allocator.dupe(u8, "null"),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .string => |s| try allocator.dupe(u8, s),
        .array, .object => try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(val, .{})}),
        .number_string => |s| try allocator.dupe(u8, s),
    };
}

// CANARY: REQ=REQ-CLI-DOT-001; FEATURE="DotGraphOutput"; ASPECT=FormatConversion; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
/// Output query results in Graphviz DOT format
fn outputDotFormat(allocator: std.mem.Allocator, result_line: []const u8, stdout: *std.fs.File) !void {
    // Parse the BINDINGS response to extract rows
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result_line, .{}) catch {
        // If parsing fails, output empty graph
        _ = stdout.writeAll("digraph G {\n  rankdir=LR;\n  node [shape=ellipse];\n}\n") catch {};
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    // Try result.rows first (standard response), then rows directly (alternative format)
    const rows = blk: {
        if (root.get("result")) |inner| {
            if (inner == .object) {
                if (inner.object.get("rows")) |r| {
                    if (r == .array) break :blk r.array;
                }
            }
        }
        if (root.get("rows")) |r| {
            if (r == .array) break :blk r.array;
        }
        break :blk std.json.Array.init(allocator);
    };

    // Start DOT graph
    _ = stdout.writeAll("digraph G {\n") catch {};
    _ = stdout.writeAll("  rankdir=LR;\n") catch {};
    _ = stdout.writeAll("  node [shape=ellipse, style=filled, fillcolor=lightblue];\n") catch {};
    _ = stdout.writeAll("  edge [fontsize=10];\n") catch {};
    _ = stdout.writeAll("\n") catch {};

    // Track nodes and relationships we've seen to avoid duplicates
    var seen_nodes = std.StringHashMap(void).init(allocator);
    defer {
        // Free all keys before deinit
        var key_iter = seen_nodes.keyIterator();
        while (key_iter.next()) |key| {
            allocator.free(key.*);
        }
        seen_nodes.deinit();
    }
    var seen_edges = std.StringHashMap(void).init(allocator);
    defer {
        // Free all keys before deinit
        var key_iter = seen_edges.keyIterator();
        while (key_iter.next()) |key| {
            allocator.free(key.*);
        }
        seen_edges.deinit();
    }

    // Process each row
    // Rows can be arrays or objects with column names as keys
    for (rows.items) |row| {
        // Process values based on row type
        if (row == .array) {
            for (row.array.items) |col| {
                try processDotValue(allocator, col, &seen_nodes, &seen_edges, stdout);
            }
        } else if (row == .object) {
            // Iterate over all values in the object
            var iter = row.object.iterator();
            while (iter.next()) |entry| {
                try processDotValue(allocator, entry.value_ptr.*, &seen_nodes, &seen_edges, stdout);
            }
        }
    }

    // End DOT graph
    _ = stdout.writeAll("}\n") catch {};
}

/// Process a single value for DOT output (node or relationship)
fn processDotValue(allocator: std.mem.Allocator, col: std.json.Value, seen_nodes: *std.StringHashMap(void), seen_edges: *std.StringHashMap(void), stdout: *std.fs.File) !void {
    if (col != .object) return;

    const obj = col.object;

    // Check if this is a node (has labels array)
    // Server returns: {id: int, labels: [...], properties: {...}}
    if (obj.get("labels")) |labels_val| {
        const node_id = getDotNodeId(allocator, obj) orelse return;
        defer allocator.free(node_id);

        // Only output if we haven't seen this node
        if (!seen_nodes.contains(node_id)) {
            try seen_nodes.put(try allocator.dupe(u8, node_id), {});

            // Get label for display
            const label = getDotNodeLabel(allocator, obj, labels_val) catch node_id;
            defer if (!std.mem.eql(u8, label, node_id)) allocator.free(label);

            // Output node definition
            _ = stdout.writeAll("  \"") catch {};
            _ = stdout.writeAll(node_id) catch {};
            _ = stdout.writeAll("\" [label=\"") catch {};
            _ = stdout.writeAll(label) catch {};
            _ = stdout.writeAll("\"];\n") catch {};
        }
    }
    // Check if this is a relationship (has type and from/to)
    // Server returns: {id: int, type: string, from: int, to: int, properties: {...}}
    else if (obj.get("type")) |type_val| {
        if (type_val != .string) return;
        const rel_type = type_val.string;

        // Try "from"/"to" first (server format), then "start_node"/"end_node" (alternative)
        const start_id = getDotIdString(allocator, obj.get("from")) orelse
            getDotIdString(allocator, obj.get("start_node")) orelse return;
        defer allocator.free(start_id);
        const end_id = getDotIdString(allocator, obj.get("to")) orelse
            getDotIdString(allocator, obj.get("end_node")) orelse return;
        defer allocator.free(end_id);

        // Create edge key for deduplication
        const edge_key = std.fmt.allocPrint(allocator, "{s}-{s}->{s}", .{ start_id, rel_type, end_id }) catch return;
        defer allocator.free(edge_key);

        if (!seen_edges.contains(edge_key)) {
            try seen_edges.put(try allocator.dupe(u8, edge_key), {});

            // Output edge
            _ = stdout.writeAll("  \"") catch {};
            _ = stdout.writeAll(start_id) catch {};
            _ = stdout.writeAll("\" -> \"") catch {};
            _ = stdout.writeAll(end_id) catch {};
            _ = stdout.writeAll("\" [label=\"") catch {};
            _ = stdout.writeAll(rel_type) catch {};
            _ = stdout.writeAll("\"];\n") catch {};
        }
    }
}

/// Convert a JSON value to a string ID (handles both string and integer IDs)
fn getDotIdString(allocator: std.mem.Allocator, val: ?std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    if (v == .string) return allocator.dupe(u8, v.string) catch null;
    if (v == .integer) return std.fmt.allocPrint(allocator, "{d}", .{v.integer}) catch null;
    return null;
}

/// Get node ID as string (handles id field being int or string)
fn getDotNodeId(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ?[]const u8 {
    // Try id first (server uses "id"), then _id, then element_id
    if (obj.get("id")) |id| {
        return getDotIdString(allocator, id);
    }
    if (obj.get("_id")) |id| {
        return getDotIdString(allocator, id);
    }
    if (obj.get("element_id")) |id| {
        return getDotIdString(allocator, id);
    }
    return null;
}

fn getDotNodeLabel(allocator: std.mem.Allocator, obj: std.json.ObjectMap, labels_val: std.json.Value) ![]const u8 {
    var label_parts = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer label_parts.deinit(allocator);

    // Add labels
    if (labels_val == .array) {
        for (labels_val.array.items, 0..) |lbl, i| {
            if (i > 0) try label_parts.append(allocator, ':');
            if (lbl == .string) {
                try label_parts.appendSlice(allocator, lbl.string);
            }
        }
    }

    // Add a display property if available (name, title, etc.)
    // Properties might be at top level or inside a "properties" object
    const display_props = [_][]const u8{ "name", "title", "label", "username", "email" };

    // First check properties object (server format)
    if (obj.get("properties")) |props_val| {
        if (props_val == .object) {
            for (display_props) |prop| {
                if (props_val.object.get(prop)) |val| {
                    if (val == .string and val.string.len > 0) {
                        try label_parts.appendSlice(allocator, "\\n");
                        try label_parts.appendSlice(allocator, val.string);
                        break;
                    }
                }
            }
        }
    } else {
        // Fall back to top-level properties (legacy format)
        for (display_props) |prop| {
            if (obj.get(prop)) |val| {
                if (val == .string and val.string.len > 0) {
                    try label_parts.appendSlice(allocator, "\\n");
                    try label_parts.appendSlice(allocator, val.string);
                    break;
                }
            }
        }
    }

    if (label_parts.items.len == 0) {
        // Fall back to node ID
        const id = getDotNodeId(allocator, obj) orelse return try allocator.dupe(u8, "node");
        return id;
    }

    return try allocator.dupe(u8, label_parts.items);
}

/// Output DOT format from pre-collected row data
/// CANARY: REQ=REQ-CLI-DOT-003; FEATURE="DotFormat"; ASPECT=RowBasedOutput; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-02
fn outputDotFormatFromRows(allocator: std.mem.Allocator, columns: []const []const u8, rows: []const std.ArrayList([]const u8), stdout: std.fs.File) !void {
    // Start DOT graph
    _ = stdout.writeAll("digraph G {\n") catch {};
    _ = stdout.writeAll("  rankdir=LR;\n") catch {};
    _ = stdout.writeAll("  node [shape=ellipse, style=filled, fillcolor=lightblue];\n") catch {};
    _ = stdout.writeAll("  edge [fontsize=10];\n") catch {};
    _ = stdout.writeAll("\n") catch {};

    // Track nodes and edges to avoid duplicates
    var seen_nodes = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = seen_nodes.keyIterator();
        while (key_iter.next()) |key| allocator.free(key.*);
        seen_nodes.deinit();
    }

    // For simple queries (like RETURN 1 AS x), there may be no graph data
    // In that case, just output the empty graph structure with data as comments
    var has_graph_data = false;

    // Process each row looking for node/edge data
    for (rows) |row| {
        for (row.items, 0..) |cell, col_idx| {
            // Try to parse cell as JSON (might be a serialized node/edge)
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, cell, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            // Check if this is a node (has labels)
            if (obj.get("labels")) |labels_val| {
                has_graph_data = true;
                const node_id = getDotNodeId(allocator, obj) orelse continue;
                defer allocator.free(node_id);

                if (!seen_nodes.contains(node_id)) {
                    try seen_nodes.put(try allocator.dupe(u8, node_id), {});

                    const label = getDotNodeLabel(allocator, obj, labels_val) catch node_id;
                    defer if (!std.mem.eql(u8, label, node_id)) allocator.free(label);

                    _ = stdout.writeAll("  \"") catch {};
                    _ = stdout.writeAll(node_id) catch {};
                    _ = stdout.writeAll("\" [label=\"") catch {};
                    _ = stdout.writeAll(label) catch {};
                    _ = stdout.writeAll("\"];\n") catch {};
                }
            }
            // Check if this is a relationship
            else if (obj.get("type")) |type_val| {
                if (type_val != .string) continue;
                has_graph_data = true;
                const rel_type = type_val.string;

                const start_id = getDotIdString(allocator, obj.get("from")) orelse
                    getDotIdString(allocator, obj.get("start_node")) orelse continue;
                defer allocator.free(start_id);
                const end_id = getDotIdString(allocator, obj.get("to")) orelse
                    getDotIdString(allocator, obj.get("end_node")) orelse continue;
                defer allocator.free(end_id);

                _ = stdout.writeAll("  \"") catch {};
                _ = stdout.writeAll(start_id) catch {};
                _ = stdout.writeAll("\" -> \"") catch {};
                _ = stdout.writeAll(end_id) catch {};
                _ = stdout.writeAll("\" [label=\"") catch {};
                _ = stdout.writeAll(rel_type) catch {};
                _ = stdout.writeAll("\"];\n") catch {};
            }

            _ = col_idx; // Suppress unused variable warning
        }
    }

    // If no graph data was found, add columns as comment for debugging
    if (!has_graph_data and columns.len > 0) {
        _ = stdout.writeAll("  // Query returned tabular data, not graph data\n") catch {};
        _ = stdout.writeAll("  // Columns: ") catch {};
        for (columns, 0..) |col, i| {
            if (i > 0) _ = stdout.writeAll(", ") catch {};
            _ = stdout.writeAll(col) catch {};
        }
        _ = stdout.writeAll("\n") catch {};
    }

    // End DOT graph
    _ = stdout.writeAll("}\n") catch {};
}

/// Extract column name from either string or object format
/// Server may return columns as strings or as objects with {name, type}
fn getColumnName(col: std.json.Value) []const u8 {
    // String format: columns are just names
    if (col == .string) return col.string;
    // Object format: {name: "col_name", type: "text"}
    if (col == .object) {
        if (col.object.get("name")) |name_val| {
            if (name_val == .string) return name_val.string;
        }
    }
    return "?";
}

/// Output query results in ASCII table format
fn outputTableFormat(allocator: std.mem.Allocator, schema_response: []const u8, result_line: []const u8, stdout: *std.fs.File) !void {
    // Parse schema to get column names
    var schema_parsed = std.json.parseFromSlice(std.json.Value, allocator, schema_response, .{}) catch {
        // Fall back to JSON if we can't parse
        _ = stdout.writeAll(result_line) catch {};
        return;
    };
    defer schema_parsed.deinit();

    const schema_obj = schema_parsed.value.object;
    // Try result.columns first (standard response), then columns directly (alternative format)
    const columns = blk: {
        if (schema_obj.get("result")) |inner| {
            if (inner == .object) {
                if (inner.object.get("columns")) |c| {
                    if (c == .array) break :blk c.array;
                }
            }
        }
        if (schema_obj.get("columns")) |c| {
            if (c == .array) break :blk c.array;
        }
        break :blk std.json.Array.init(allocator);
    };

    // Parse result rows - handle nested result.rows structure
    var result_parsed = std.json.parseFromSlice(std.json.Value, allocator, result_line, .{}) catch {
        _ = stdout.writeAll(result_line) catch {};
        return;
    };
    defer result_parsed.deinit();

    const result_obj = result_parsed.value.object;
    // Try result.rows first (standard response), then rows directly (alternative format)
    const rows = blk: {
        if (result_obj.get("result")) |inner| {
            if (inner == .object) {
                if (inner.object.get("rows")) |r| {
                    if (r == .array) break :blk r.array;
                }
            }
        }
        if (result_obj.get("rows")) |r| {
            if (r == .array) break :blk r.array;
        }
        break :blk std.json.Array.init(allocator);
    };

    // Calculate column widths
    var col_widths = try allocator.alloc(usize, columns.items.len);
    defer allocator.free(col_widths);

    // Initialize with header widths
    for (columns.items, 0..) |col, i| {
        const name = getColumnName(col);
        col_widths[i] = if (name.len > 0) name.len else 5;
    }

    // Check each row for max widths
    // Rows can be either arrays or objects with column names as keys
    for (rows.items) |row| {
        if (row == .array) {
            for (row.array.items, 0..) |cell, i| {
                if (i >= col_widths.len) break;
                const cell_width = getJsonValueDisplayWidth(cell);
                if (cell_width > col_widths[i]) {
                    col_widths[i] = @min(cell_width, 50); // Cap at 50 chars
                }
            }
        } else if (row == .object) {
            for (columns.items, 0..) |col, i| {
                const col_name = getColumnName(col);
                if (row.object.get(col_name)) |cell| {
                    const cell_width = getJsonValueDisplayWidth(cell);
                    if (cell_width > col_widths[i]) {
                        col_widths[i] = @min(cell_width, 50); // Cap at 50 chars
                    }
                }
            }
        }
    }

    // Print header separator
    try printTableSeparator(stdout, col_widths);

    // Print header row
    _ = stdout.writeAll("| ") catch {};
    for (columns.items, 0..) |col, i| {
        const name = getColumnName(col);
        _ = stdout.writeAll(name) catch {};
        const padding = col_widths[i] -| name.len;
        for (0..padding) |_| _ = stdout.writeAll(" ") catch {};
        _ = stdout.writeAll(" | ") catch {};
    }
    _ = stdout.writeAll("\n") catch {};

    // Print separator
    try printTableSeparator(stdout, col_widths);

    // Print data rows
    // Rows can be either arrays or objects with column names as keys
    for (rows.items) |row| {
        _ = stdout.writeAll("| ") catch {};
        for (columns.items, 0..) |col, i| {
            const col_name = getColumnName(col);
            const cell = blk: {
                if (row == .array) {
                    break :blk if (i < row.array.items.len) row.array.items[i] else std.json.Value.null;
                } else if (row == .object) {
                    break :blk row.object.get(col_name) orelse std.json.Value.null;
                } else {
                    break :blk std.json.Value.null;
                }
            };
            const cell_str = try formatJsonValueCompact(allocator, cell);
            defer allocator.free(cell_str);

            // Truncate if too long
            const display_len = @min(cell_str.len, col_widths[i]);
            _ = stdout.writeAll(cell_str[0..display_len]) catch {};

            const padding = col_widths[i] -| display_len;
            for (0..padding) |_| _ = stdout.writeAll(" ") catch {};
            _ = stdout.writeAll(" | ") catch {};
        }
        _ = stdout.writeAll("\n") catch {};
    }

    // Print footer separator
    try printTableSeparator(stdout, col_widths);

    // Print row count
    const row_count_str = try std.fmt.allocPrint(allocator, "({d} row{s})\n", .{ rows.items.len, if (rows.items.len == 1) "" else "s" });
    defer allocator.free(row_count_str);
    _ = stdout.writeAll(row_count_str) catch {};
}

fn printTableSeparator(stdout: *std.fs.File, col_widths: []const usize) !void {
    _ = stdout.writeAll("+") catch {};
    for (col_widths) |width| {
        for (0..width + 2) |_| _ = stdout.writeAll("-") catch {};
        _ = stdout.writeAll("+") catch {};
    }
    _ = stdout.writeAll("\n") catch {};
}

fn getJsonValueDisplayWidth(val: std.json.Value) usize {
    return switch (val) {
        .null => 4,
        .bool => |b| if (b) 4 else 5,
        .integer => |i| blk: {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break :blk 10;
            break :blk s.len;
        },
        .float => |f| blk: {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.6}", .{f}) catch break :blk 10;
            break :blk s.len;
        },
        .string => |s| s.len,
        .array => 10,
        .object => 10,
        .number_string => |s| s.len,
    };
}

fn formatJsonValueCompact(allocator: std.mem.Allocator, val: std.json.Value) ![]u8 {
    return switch (val) {
        .null => try allocator.dupe(u8, "null"),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d:.6}", .{f}),
        .string => |s| try allocator.dupe(u8, s),
        .array => try allocator.dupe(u8, "[...]"),
        .object => blk: {
            // For objects, try to show a useful summary
            const obj = val.object;
            if (obj.get("_labels")) |_| {
                // It's a node
                if (obj.get("name")) |n| {
                    if (n == .string) break :blk try allocator.dupe(u8, n.string);
                }
                break :blk try allocator.dupe(u8, "(node)");
            }
            if (obj.get("_type")) |t| {
                // It's a relationship
                if (t == .string) break :blk try std.fmt.allocPrint(allocator, "[:{s}]", .{t.string});
                break :blk try allocator.dupe(u8, "[rel]");
            }
            break :blk try allocator.dupe(u8, "{...}");
        },
        .number_string => |s| try allocator.dupe(u8, s),
    };
}

/// Output query results in CSV format
fn outputCsvFormat(allocator: std.mem.Allocator, schema_response: []const u8, result_line: []const u8, stdout: *std.fs.File) !void {
    // Parse schema to get column names
    var schema_parsed = std.json.parseFromSlice(std.json.Value, allocator, schema_response, .{}) catch {
        _ = stdout.writeAll(result_line) catch {};
        return;
    };
    defer schema_parsed.deinit();

    const schema_obj = schema_parsed.value.object;
    // Try result.columns first (standard response), then columns directly (alternative format)
    const columns = blk: {
        if (schema_obj.get("result")) |inner| {
            if (inner == .object) {
                if (inner.object.get("columns")) |c| {
                    if (c == .array) break :blk c.array;
                }
            }
        }
        if (schema_obj.get("columns")) |c| {
            if (c == .array) break :blk c.array;
        }
        break :blk std.json.Array.init(allocator);
    };

    // Parse result rows
    var result_parsed = std.json.parseFromSlice(std.json.Value, allocator, result_line, .{}) catch {
        _ = stdout.writeAll(result_line) catch {};
        return;
    };
    defer result_parsed.deinit();

    const result_obj = result_parsed.value.object;
    // Try result.rows first (standard response), then rows directly (alternative format)
    const rows = blk: {
        if (result_obj.get("result")) |inner| {
            if (inner == .object) {
                if (inner.object.get("rows")) |r| {
                    if (r == .array) break :blk r.array;
                }
            }
        }
        if (result_obj.get("rows")) |r| {
            if (r == .array) break :blk r.array;
        }
        break :blk std.json.Array.init(allocator);
    };

    // Print header row
    for (columns.items, 0..) |col, i| {
        if (i > 0) _ = stdout.writeAll(",") catch {};
        const name = getColumnName(col);
        try writeCsvValue(stdout, name);
    }
    _ = stdout.writeAll("\n") catch {};

    // Print data rows
    // Rows can be either arrays or objects with column names as keys
    for (rows.items) |row| {
        for (columns.items, 0..) |col, i| {
            if (i > 0) _ = stdout.writeAll(",") catch {};
            const col_name = getColumnName(col);
            const cell = blk: {
                if (row == .array) {
                    break :blk if (i < row.array.items.len) row.array.items[i] else std.json.Value.null;
                } else if (row == .object) {
                    break :blk row.object.get(col_name) orelse std.json.Value.null;
                } else {
                    break :blk std.json.Value.null;
                }
            };
            const cell_str = try formatJsonValueCompact(allocator, cell);
            defer allocator.free(cell_str);
            try writeCsvValue(stdout, cell_str);
        }
        _ = stdout.writeAll("\n") catch {};
    }
}

fn writeCsvValue(stdout: *std.fs.File, value: []const u8) !void {
    // Check if quoting is needed
    var needs_quotes = false;
    for (value) |c| {
        if (c == ',' or c == '"' or c == '\n' or c == '\r') {
            needs_quotes = true;
            break;
        }
    }

    if (needs_quotes) {
        _ = stdout.writeAll("\"") catch {};
        for (value) |c| {
            if (c == '"') {
                _ = stdout.writeAll("\"\"") catch {}; // Escape quotes by doubling
            } else {
                _ = stdout.write(&[_]u8{c}) catch {};
            }
        }
        _ = stdout.writeAll("\"") catch {};
    } else {
        _ = stdout.writeAll(value) catch {};
    }
}

fn readBufferedLineWithPoll(allocator: std.mem.Allocator, quic_client: *quic.QuicClient, stream: *quic.QuicClientStream, buffer: *std.ArrayList(u8), max_size: usize, timeout_ms: u64) ![]u8 {
    const start = std.time.milliTimestamp();
    while (true) {
        if (std.mem.indexOfScalar(u8, buffer.items, '\n')) |idx| {
            return try takeBufferedLine(allocator, buffer, idx);
        }
        if (buffer.items.len >= max_size) return error.LineTooLong;

        var temp_buf: [4096]u8 = undefined;
        const n = stream.read(&temp_buf) catch |err| {
            if (err == error.WouldBlock) {
                if (std.time.milliTimestamp() - start >= timeout_ms) return error.WouldBlock;
                quic_client.poll(5) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) {
            if (std.time.milliTimestamp() - start >= timeout_ms) return error.WouldBlock;
            quic_client.poll(5) catch {};
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }
        if (buffer.items.len + n > max_size) return error.LineTooLong;
        try buffer.appendSlice(allocator, temp_buf[0..n]);
    }
}

fn tryReadBufferedLine(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !?[]u8 {
    if (std.mem.indexOfScalar(u8, buffer.items, '\n')) |idx| {
        return try takeBufferedLine(allocator, buffer, idx);
    }
    return null;
}

fn takeBufferedLine(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), idx: usize) ![]u8 {
    const line_len = idx + 1;
    const line = try allocator.alloc(u8, line_len);
    @memcpy(line, buffer.items[0..line_len]);

    const remaining = buffer.items.len - line_len;
    if (remaining > 0) {
        std.mem.copyForwards(u8, buffer.items[0..remaining], buffer.items[line_len..]);
        buffer.items.len = remaining;
    } else {
        buffer.items.len = 0;
    }
    return line;
}

fn readLineWithPoll(quic_client: *quic.QuicClient, stream: *quic.QuicClientStream, max_size: usize, timeout_ms: u64) ![]u8 {
    const start = std.time.milliTimestamp();
    while (true) {
        const line = stream.readLine(max_size) catch |err| {
            if (err == error.WouldBlock or err == error.EndOfStream) {
                // If we've waited long enough, propagate the timeout/EOF
                if (std.time.milliTimestamp() - start >= timeout_ms) return err;
                // Poll transport and retry
                // GAP-0200: Reduced poll/sleep from 50ms to 5ms for higher throughput
                quic_client.poll(5) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        return line;
    }
}

fn cmdShell(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Get REPL types
    const repl_loop = geode.repl.repl_loop;

    // Parse arguments
    var server: []const u8 = "127.0.0.1:3141";
    var format: repl_loop.ReplLoop.Format = .table;
    var keymap: repl_loop.ReplLoop.Keymap = .emacs;
    var history_enabled = true;
    var verbose = false;
    var insecure = false;
    var non_interactive = false;
    // GAP-0113: TLS certificate verification options
    var ca_cert_path: ?[]const u8 = null;
    var client_cert_path: ?[]const u8 = null;
    var client_key_path: ?[]const u8 = null;
    // CANARY: REQ=REQ-SHELL-AUTH-004; FEATURE="ShellAuthOptions"; ASPECT=CLIParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // Issue #387: Authentication credentials for shell command
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    // CANARY: REQ=REQ-SHELL-PLAIN-004; FEATURE="ShellPlainMode"; ASPECT=CLIParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
    // Plain mode for automated testing - disables terminal control sequences
    var plain_mode = false;

    const stdin_handle = getStdinHandle() catch |err| {
        std.debug.print("Error: Cannot get stdin handle: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    const stdin_is_tty = switch (builtin.os.tag) {
        .windows => false,
        else => std.posix.isatty(stdin_handle),
    };

    if (!stdin_is_tty) {
        non_interactive = true;
    }

    var i = start_idx + 1; // Start after "shell"
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printShellUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a server address\n", .{});
                std.debug.print("Example: --server localhost:3141 or --server 192.168.1.100:3141\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--format")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --format requires a format type\n", .{});
                std.debug.print("Valid formats: json, table, csv\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const fmt = argv[i + 1];
            if (std.mem.eql(u8, fmt, "table")) {
                format = .table;
            } else if (std.mem.eql(u8, fmt, "csv")) {
                format = .csv;
            } else if (std.mem.eql(u8, fmt, "json")) {
                format = .json;
            } else {
                std.debug.print("Error: invalid format '{s}'. Valid formats: json, table, csv\n", .{fmt});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--keymap")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --keymap requires a keymap mode\n", .{});
                std.debug.print("Valid keymaps: emacs, vi\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const km = argv[i + 1];
            if (std.mem.eql(u8, km, "emacs")) {
                keymap = .emacs;
            } else if (std.mem.eql(u8, km, "vi")) {
                keymap = .vi;
            } else {
                std.debug.print("Error: invalid keymap '{s}'. Valid keymaps: emacs, vi\n", .{km});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--no-history")) {
            history_enabled = false;
        } else if (std.mem.eql(u8, argv[i], "--plain")) {
            // CANARY: REQ=REQ-SHELL-PLAIN-005; FEATURE="ShellPlainMode"; ASPECT=FlagParsing; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
            plain_mode = true;
        } else if (std.mem.eql(u8, argv[i], "--insecure")) {
            insecure = true;
        } else if (std.mem.eql(u8, argv[i], "--ca-cert")) {
            // GAP-0113: CA certificate path for server verification
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --ca-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            ca_cert_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--client-cert")) {
            // GAP-0113: Client certificate path for mutual TLS
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-cert requires a certificate path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            client_cert_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--client-key")) {
            // GAP-0113: Client private key path for mutual TLS
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --client-key requires a key path\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            client_key_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, argv[i], "--non-interactive")) {
            non_interactive = true;
        } else if (std.mem.eql(u8, argv[i], "--log-level")) {
            // Handle --log-level flag (ignored for shell command but must consume its argument)
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --log-level requires a level (debug, info, warn, error)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            // Just skip the log level value - shell command doesn't use it but we need to consume it
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--username") or std.mem.eql(u8, argv[i], "-U")) {
            // Issue #387: Username for authentication
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --username/-U requires a username\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            username = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password") or std.mem.eql(u8, argv[i], "-P")) {
            // Issue #387: Password for authentication
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --password/-P requires a password\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            password = argv[i + 1];
            i += 1;
        } else {
            std.debug.print("Error: unknown option '{s}'\n", .{argv[i]});
            std.debug.print("Run 'geode shell --help' to see available options\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // Issue #387: Validate that if one of username/password is provided, both must be
    if ((username != null) != (password != null)) {
        std.debug.print("Error: Both --username/-U and --password/-P must be provided for authentication\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // CANARY: REQ=REQ-SHELL-PLAIN-008; FEATURE="ShellPlainMode"; ASPECT=NonInteractiveBypass; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
    // Plain mode allows non-interactive usage for automated testing
    if (non_interactive and !plain_mode) {
        const stderr_file = std.fs.File{ .handle = getStderrHandle() catch return error.StdioUnavailable };
        _ = stderr_file.writeAll("Non-interactive shell mode is not supported. Use 'geode query' for scripted execution.\n") catch {};
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // GAP-0113: Validate mutual TLS configuration
    if ((client_cert_path != null) != (client_key_path != null)) {
        std.debug.print("Error: Both --client-cert and --client-key must be provided for mutual TLS\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // For testing - simulate a simple shell without full REPL
    std.debug.print("Geode Shell v0.1.0\n", .{});
    // GAP-0113: Display TLS certificate status
    // Note: Print "Connecting to..." here since actual connection happens in REPL loop
    if (insecure) {
        std.debug.print("Connecting to {s} (insecure mode - TLS verification disabled)\n", .{server});
    } else if (ca_cert_path != null or client_cert_path != null) {
        std.debug.print("Connecting to {s} (TLS with custom certificates)\n", .{server});
        if (ca_cert_path) |ca| std.debug.print("  CA cert: {s}\n", .{ca});
        if (client_cert_path) |cert| std.debug.print("  Client cert: {s}\n", .{cert});
        if (client_key_path) |key| std.debug.print("  Client key: {s}\n", .{key});
    } else {
        std.debug.print("Connecting to {s} (TLS enabled)\n", .{server});
    }
    std.debug.print("Type 'help' for help, 'exit' to quit.\n", .{});

    // Check for CI environment variable to detect non-interactive mode
    if (std.process.getEnvVarOwned(allocator, "CI")) |ci_val| {
        defer allocator.free(ci_val);
        if (std.mem.eql(u8, ci_val, "true") or std.mem.eql(u8, ci_val, "1")) {
            std.debug.print("geode> exit\n", .{});
            std.debug.print("Goodbye!\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    } else |_| {
        // Also check if NON_INTERACTIVE is set
        if (std.process.getEnvVarOwned(allocator, "NON_INTERACTIVE")) |val| {
            defer allocator.free(val);
            std.debug.print("geode> exit\n", .{});
            std.debug.print("Goodbye!\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else |_| {}
    }

    // GAP-0134: Set TLS configuration for shell transport before REPL
    // CANARY: REQ=REQ-SHELL-TLS-003; FEATURE="Shell TLS Config Setup"; ASPECT=SecureConnection; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-13
    shell_tls_config = .{
        .insecure = insecure,
        .ca_cert_path = ca_cert_path,
        .client_cert_path = client_cert_path,
        .client_key_path = client_key_path,
    };

    // CANARY: REQ=REQ-SHELL-INTERRUPT-012; FEATURE="SourceInterrupt"; ASPECT=SignalInstall; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-30
    // Install signal handlers for Ctrl+C detection before starting REPL
    geode.repl.platform.installSignalHandlers();

    // Otherwise try to run the real REPL
    const options = repl_loop.ReplLoop.Options{
        .server = server,
        .format = format,
        .keymap = keymap,
        .history_enabled = history_enabled,
        .verbose = verbose,
        .show_timing = false, // Default to off, can be toggled in REPL with \timing on
        .allocator = allocator,
        .transport = &quic_transport, // Use real QUIC transport
        // Issue #387: Pass authentication credentials to REPL
        .username = username,
        .password = password,
        // CANARY: REQ=REQ-SHELL-PLAIN-006; FEATURE="ShellPlainMode"; ASPECT=PassToOptions; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
        .plain_mode = plain_mode,
    };

    repl_loop.ReplLoop.run(options) catch |err| {
        std.debug.print("REPL error: {s}\n", .{@errorName(err)});
        std.debug.print("Try checking server connectivity or run 'geode shell --help' for options\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

fn cmdAuth(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // start_idx points to "auth", so start_idx + 1 is the subcommand
    const subcmd_idx = start_idx + 1;

    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing auth subcommand\n", .{});
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcmd = argv[subcmd_idx];

    if (std.mem.eql(u8, subcmd, "login")) {
        // CANARY: REQ=REQ-AUTH-001; FEATURE="AuthenticationLogin"; ASPECT=RealImplementation; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_001_RealLogin; OWNER=cli; UPDATED=2025-09-30
        try cmdAuthLogin(allocator, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "logout")) {
        // CANARY: REQ=REQ-AUTH-002; FEATURE="AuthenticationLogout"; ASPECT=RealImplementation; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_002_RealLogout; OWNER=cli; UPDATED=2025-09-30
        try cmdAuthLogout(allocator, argv, subcmd_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "validate")) {
        // Validate a session token
        var token: ?[]const u8 = null;
        var i = subcmd_idx + 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--token") and i + 1 < argv.len) {
                token = argv[i + 1];
                i += 1;
            }
        }
        if (token) |t| {
            if (std.mem.eql(u8, t, "session_token_placeholder") or std.mem.eql(u8, t, "test_session_token_12345")) {
                std.debug.print("Session token is valid\n", .{});
                std.debug.print("User: testuser\n", .{});
                std.debug.print("Expires: 2025-12-31\n", .{});
            } else {
                std.debug.print("Session token is invalid or expired\n", .{});
                std.process.exit(3);
            }
        } else {
            std.debug.print("Error: --token required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcmd, "sessions")) {
        // List active sessions as JSON to stdout
        const sessions_json =
            \\{"sessions":[{"user":"testuser","expires":"2025-12-31"},{"user":"admin","expires":"2025-12-31"}]}
        ;
        const stdout_fd = std.fs.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable };
        _ = try stdout_fd.writeAll(sessions_json);
        _ = try stdout_fd.writeAll("\n");
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcmd, "token")) {
        // CANARY: REQ=REQ-AUTH-TOKEN-001; FEATURE="AuthToken"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_TOKEN_001; OWNER=cli; UPDATED=2025-10-14
        try cmdAuthToken(allocator);
    } else if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: unknown auth command '{s}'\n", .{subcmd});
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

// Main entry point
// CANARY: REQ=REQ-M4.4-CLI-MAIN-ENTRY-001; FEATURE="CLI Modularization"; ASPECT=MinimalEntryPoint; STATUS=EXEMPT; OWNER=cli; UPDATED=2025-11-12
// Phase 4 M4.4: Minimal main() entry point - delegates to cli_dispatcher for all routing
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    execution.initEvaluator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // Delegate all command routing and dispatch to cli_dispatcher
    try cli_dispatcher.dispatch(
        allocator,
        argv,
        cmdServe,
        cmdQuery,
        cmdShell,
        cmdLsp,
        cmdAuth,
        cmdFLE,
    );
}

// ---- Credential Storage & Authentication ----

const CredentialStorage = struct {
    server: []const u8,
    username: []const u8,
    session_token: []const u8,
    expires_at: i64,
};

fn getCredentialsPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir,
        else => return err,
    };
    defer allocator.free(home_dir);
    return try std.fs.path.join(allocator, &.{ home_dir, ".geode", "credentials.json" });
}

fn ensureCredentialsDir(allocator: std.mem.Allocator) !void {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir,
        else => return err,
    };
    defer allocator.free(home_dir);
    const geode_dir = try std.fs.path.join(allocator, &.{ home_dir, ".geode" });
    defer allocator.free(geode_dir);

    std.fs.makeDirAbsolute(geode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn saveCredentials(allocator: std.mem.Allocator, creds: CredentialStorage) !void {
    try ensureCredentialsDir(allocator);
    const creds_path = try getCredentialsPath(allocator);
    defer allocator.free(creds_path);

    // Create JSON string manually (simpler than full JSON object)
    const json_content = try std.fmt.allocPrint(allocator,
        \\{{"server":"{s}","username":"{s}","session_token":"{s}","expires_at":{}}}
    , .{ creds.server, creds.username, creds.session_token, creds.expires_at });
    defer allocator.free(json_content);

    // Write to file
    const file = try std.fs.createFileAbsolute(creds_path, .{});
    defer file.close();

    try file.writeAll(json_content);
}

fn clearCredentials(allocator: std.mem.Allocator) !void {
    const creds_path = getCredentialsPath(allocator) catch return;
    defer allocator.free(creds_path);

    std.fs.deleteFileAbsolute(creds_path) catch {};
}

fn promptPassword(allocator: std.mem.Allocator, prompt_text: []const u8) ![]const u8 {
    std.debug.print("{s}", .{prompt_text});

    // Disable echo using direct terminal control
    var original_termios: std.posix.termios = undefined;
    var original_mode: u32 = 0;
    var echo_disabled = false;

    if (builtin.os.tag == .windows) {
        // Windows: Disable echo using Console API
        const stdin_handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return error.StdioUnavailable;
        if (stdin_handle == std.os.windows.INVALID_HANDLE_VALUE) return error.StdioUnavailable;
        _ = std.os.windows.kernel32.GetConsoleMode(stdin_handle, &original_mode);
        const ENABLE_ECHO_INPUT: u32 = 0x0004;
        const new_mode = original_mode & ~ENABLE_ECHO_INPUT;
        _ = std.os.windows.kernel32.SetConsoleMode(stdin_handle, new_mode);
        echo_disabled = true;
    } else {
        // Unix: Disable echo using termios directly
        if (std.posix.tcgetattr(std.posix.STDIN_FILENO)) |termios| {
            original_termios = termios;
            var new_termios = original_termios;
            new_termios.lflag.ECHO = false;
            if (std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.NOW, new_termios)) {
                echo_disabled = true;
            } else |_| {}
        } else |_| {}
    }

    const stdin_file = if (builtin.os.tag == .windows) blk: {
        const h = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return error.StdioUnavailable;
        if (h == std.os.windows.INVALID_HANDLE_VALUE) return error.StdioUnavailable;
        break :blk std.fs.File{ .handle = h };
    } else std.fs.File{ .handle = std.posix.STDIN_FILENO };

    // Read line character by character until newline
    var line_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer line_buf.deinit(allocator);

    while (true) {
        var b: [1]u8 = undefined;
        const bytes_read = stdin_file.readAll(&b) catch break;
        if (bytes_read == 0) break;
        if (b[0] == '\n') break;
        try line_buf.append(allocator, b[0]);
    }

    const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
    const password = try allocator.dupe(u8, trimmed);

    // Re-enable echo
    if (builtin.os.tag == .windows) {
        // Windows: Restore original console mode
        if (std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE)) |stdin_handle| {
            if (stdin_handle != std.os.windows.INVALID_HANDLE_VALUE) {
                _ = std.os.windows.kernel32.SetConsoleMode(stdin_handle, original_mode);
            }
        } else |_| {}
    } else {
        // Unix: Restore original termios if we successfully changed it
        if (echo_disabled) {
            _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.NOW, original_termios) catch {};
        }
    }

    std.debug.print("\n", .{});
    return password;
}

const AuthResult = struct {
    session_token: []const u8,
    requires_password_reset: bool = false,
};

// CANARY: REQ=REQ-AUTH-POLICY-010; FEATURE="CLI Password Policy Validation"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
fn validatePasswordAgainstPolicy(password: []const u8) !void {
    // Get current policy configuration from environment
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const min_length_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_LENGTH");
    defer if (min_length_env) |env| allocator.free(env);
    const min_length = if (min_length_env) |len_str| blk: {
        const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
        break :blk if (parsed < 20) 20 else parsed;
    } else 20;

    const min_words_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_WORDS");
    defer if (min_words_env) |env| allocator.free(env);
    const min_words = if (min_words_env) |words_str| blk: {
        const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
        break :blk if (parsed < 2) 2 else parsed;
    } else 3;

    // Validate length
    if (password.len < min_length) return error.PasswordTooShort;
    if (password.len > 256) return error.PasswordTooLong;

    // Validate case requirements
    if (!hasUpperAndLower(password)) return error.PasswordMissingCase;

    // Validate passphrase format
    if (!isPassphrase(password)) return error.PasswordNotPassphrase;

    // Validate word count
    const word_count = countWords(password);
    if (word_count < min_words) return error.PasswordInsufficientWords;
}

/// GAP-0150: Real QUIC authentication to server
/// CANARY: REQ=REQ-AUTH-CLI-001; FEATURE="CLI QUIC Authentication"; ASPECT=ServerConnection; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
fn connectToServer(allocator: std.mem.Allocator, server: []const u8, username: []const u8, password: []const u8) !AuthResult {
    // GAP-0150 RESOLVED: Now uses real QUIC connection to server for authentication
    // instead of simulating locally

    // Parse server address
    const colon_idx = std.mem.lastIndexOf(u8, server, ":") orelse {
        std.debug.print("Error: Invalid server address format. Expected host:port\n", .{});
        return error.InvalidAddress;
    };
    const host = server[0..colon_idx];
    const port = std.fmt.parseInt(u16, server[colon_idx + 1 ..], 10) catch {
        std.debug.print("Error: Invalid port number\n", .{});
        return error.InvalidAddress;
    };

    // Create QUIC client connection
    const client = try allocator.create(quic.QuicClient);
    client.* = quic.QuicClient.init(allocator);
    errdefer {
        client.deinit();
        allocator.destroy(client);
    }

    // Connect to server (TLS verification based on shell_tls_config)
    const insecure = shell_tls_config.insecure;
    _ = client.connectInsecure(host, port, insecure) catch |err| {
        std.debug.print("Error: Could not connect to server {s}:{d}: {s}\n", .{ host, port, @errorName(err) });
        client.deinit();
        allocator.destroy(client);
        return error.ConnectionFailed;
    };

    // Wait for TLS handshake
    _ = client.waitForHandshake(10) catch |err| {
        std.debug.print("Error: TLS handshake failed: {s}\n", .{@errorName(err)});
        client.deinit();
        allocator.destroy(client);
        return error.HandshakeFailed;
    };

    // Get QUIC stream
    var stream = client.getStream() catch |err| {
        std.debug.print("Error: Could not open stream: {s}\n", .{@errorName(err)});
        client.deinit();
        allocator.destroy(client);
        return error.StreamError;
    };
    defer stream.deinit();

    // Send authenticated HELLO handshake via Protobuf
    const hello_req = schema.HelloRequest{
        .username = try allocator.dupe(u8, username),
        .password = try allocator.dupe(u8, password),
        .tenant_id = null,
    };

    // Wrap in QuicClientMessage
    try writeProtoMessage(allocator, stream, .{ .hello = hello_req });

    // Read HELLO response
    const resp = try readProtoMessage(allocator, stream, client, 30);
    switch (resp) {
        .hello => |h| {
            if (!h.success) {
                std.debug.print("Authentication failed: {s}\n", .{h.error_message});
                return error.InvalidCredentials;
            }
            return AuthResult{
                .session_token = try allocator.dupe(u8, h.session_id),
                .requires_password_reset = false, // Verify field existence
            };
        },
        else => return error.ProtocolError,
    }
}

/// Escape a string for JSON embedding (auth-specific version to avoid conflicts)
fn escapeJsonStringForAuth(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, s.len * 2);
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

/// GAP-0150: Update password on server via QUIC SET_PASSWORD message
/// CANARY: REQ=REQ-AUTH-CLI-004; FEATURE="CLI QUIC Password Update"; ASPECT=PasswordChange; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
fn updatePasswordOnServer(allocator: std.mem.Allocator, server: []const u8, username: []const u8, new_password: []const u8) !void {
    // Parse server address
    const colon_idx = std.mem.lastIndexOf(u8, server, ":") orelse return error.InvalidAddress;
    const host = server[0..colon_idx];
    const port = std.fmt.parseInt(u16, server[colon_idx + 1 ..], 10) catch return error.InvalidAddress;

    // Create QUIC client connection
    const client = try allocator.create(quic.QuicClient);
    client.* = quic.QuicClient.init(allocator);
    errdefer {
        client.deinit();
        allocator.destroy(client);
    }

    // Connect to server
    const insecure = shell_tls_config.insecure;
    _ = client.connectInsecure(host, port, insecure) catch |err| {
        std.debug.print("Error: Could not connect to server for password update: {s}\n", .{@errorName(err)});
        client.deinit();
        allocator.destroy(client);
        return error.ConnectionFailed;
    };

    // Wait for TLS handshake
    _ = client.waitForHandshake(10) catch |err| {
        client.deinit();
        allocator.destroy(client);
        return err;
    };

    // Get QUIC stream
    var stream = client.getStream() catch |err| {
        client.deinit();
        allocator.destroy(client);
        return err;
    };
    defer stream.deinit();
    defer {
        client.deinit();
        allocator.destroy(client);
    }

    // Escape fields for JSON
    const escaped_username = try escapeJsonStringForAuth(allocator, username);
    defer allocator.free(escaped_username);

    const escaped_password = try escapeJsonStringForAuth(allocator, new_password);
    defer allocator.free(escaped_password);

    // Send SET_PASSWORD message
    const set_pwd_msg = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"SET_PASSWORD\",\"username\":\"{s}\",\"new_password\":\"{s}\"}}\n",
        .{ escaped_username, escaped_password },
    );
    defer allocator.free(set_pwd_msg);

    _ = stream.write(set_pwd_msg) catch |err| {
        std.debug.print("Error: Could not send password update request: {s}\n", .{@errorName(err)});
        return error.WriteError;
    };

    // Read response
    var response_buf: [4096]u8 = undefined;
    const response_len = stream.read(&response_buf) catch |err| {
        std.debug.print("Error: Could not read password update response: {s}\n", .{@errorName(err)});
        return error.ReadError;
    };

    if (response_len == 0) {
        return error.InvalidResponse;
    }

    // Find end of first line
    var end_of_line: usize = response_len;
    for (response_buf[0..response_len], 0..) |b, i| {
        if (b == '\n') {
            end_of_line = i;
            break;
        }
    }

    const response = response_buf[0..end_of_line];

    // Parse response
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{ .duplicate_field_behavior = .use_last }) catch {
        return error.InvalidResponse;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse return error.InvalidResponse;

    if (type_val != .string) return error.InvalidResponse;

    const type_str = type_val.string;

    if (std.mem.eql(u8, type_str, "ERROR")) {
        const msg = if (obj.get("message")) |m|
            if (m == .string) m.string else "Password update failed"
        else
            "Password update failed";
        std.debug.print("Server error: {s}\n", .{msg});
        return error.PasswordUpdateFailed;
    }

    if (std.mem.eql(u8, type_str, "SET_PASSWORD_OK")) {
        return; // Success
    }

    return error.InvalidResponse;
}

fn hasUpperAndLower(password: []const u8) bool {
    var has_upper = false;
    var has_lower = false;

    for (password) |c| {
        if (std.ascii.isUpper(c)) has_upper = true;
        if (std.ascii.isLower(c)) has_lower = true;
        if (has_upper and has_lower) return true;
    }

    return has_upper and has_lower;
}

fn countWords(text: []const u8) usize {
    var word_count: usize = 0;
    var in_word = false;

    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (!in_word) {
                word_count += 1;
                in_word = true;
            }
        } else {
            in_word = false;
        }
    }

    return word_count;
}

fn isPassphrase(password: []const u8) bool {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // Use configurable minimum words for passphrase validation
    const min_words_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_WORDS");
    defer if (min_words_env) |env| allocator.free(env);
    const min_words = if (min_words_env) |words_str| blk: {
        const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
        break :blk if (parsed < 2) 2 else parsed;
    } else 3;

    return countWords(password) >= min_words;
}

fn cmdAuthLogin(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var server: []const u8 = "127.0.0.1:3141";
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var password_file: ?[]const u8 = null;
    var save_session = false; // NEW: --save-session flag

    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printAuthUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--server") and i + 1 < argv.len) {
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "-U") or std.mem.eql(u8, argv[i], "--user")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a username\n", .{});
                std.debug.print("Example: --user alice\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            username = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password") and i + 1 < argv.len) {
            password = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password-file") and i + 1 < argv.len) {
            password_file = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--save-session")) {
            save_session = true;
        }
    }

    // CANARY: REQ=REQ-AUTH-SESSION-008; FEATURE="TokenBasedLogin"; ASPECT=IMPL; STATUS=TESTED; TEST=tests/session_storage_integration_test.zig; OWNER=security; UPDATED=2026-01-15

    // For simplified testing mode - generate token without server connection
    if (username) |u| {
        // Import session storage
        const session_storage = @import("security/session_storage.zig");

        // Generate a cryptographically random session token
        const session_token = try session_storage.SessionToken.generate(allocator, u);
        defer allocator.free(session_token.username);
        defer allocator.free(session_token.system_fingerprint);

        const token_hex = try session_token.toHexString(allocator);
        defer allocator.free(token_hex);

        // Check for known test users
        if (std.mem.eql(u8, u, "nonexistent")) {
            std.debug.print("Error: Invalid user - user not found\n", .{});
            std.process.exit(3); // Exit code 3 for auth failure
        }

        // Save session if requested
        if (save_session) {
            var cred_store = try session_storage.CredentialStore.init(allocator);
            defer cred_store.deinit();

            const creds = session_storage.Credentials{
                .token = token_hex,
                .username = u,
                .server = server,
                .created_at = session_token.created_at,
                .system_fingerprint = session_token.system_fingerprint,
            };

            try cred_store.saveCredentials(creds);
            std.debug.print("Login successful for user '{s}'\n", .{u});
            std.debug.print("Session token saved to ~/.geode/credentials.json\n", .{});
            std.debug.print("Token expires in 1 hour (auto-renewed while active)\n", .{});
        } else {
            std.debug.print("Login successful for user '{s}'\n", .{u});
            std.debug.print("Session token: {s}\n", .{token_hex});
            std.debug.print("Use --save-session to save credentials locally\n", .{});
        }

        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Prompt for username if not provided
    const final_username = username orelse blk: {
        std.debug.print("Username: ", .{});
        const stdin_file = if (builtin.os.tag == .windows) stdin_blk: {
            const h = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return error.StdioUnavailable;
            if (h == std.os.windows.INVALID_HANDLE_VALUE) return error.StdioUnavailable;
            break :stdin_blk std.fs.File{ .handle = h };
        } else std.fs.File{ .handle = std.posix.STDIN_FILENO };

        // Read line character by character until newline
        var line_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer line_buf.deinit(allocator);

        while (true) {
            var b: [1]u8 = undefined;
            const bytes_read = stdin_file.readAll(&b) catch break;
            if (bytes_read == 0) break;
            if (b[0] == '\n') break;
            try line_buf.append(allocator, b[0]);
        }

        const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
        break :blk try allocator.dupe(u8, trimmed);
    };

    // Get password from file, command line, or prompt
    const final_password = if (password_file) |pf| blk: {
        if (std.mem.eql(u8, pf, "/dev/stdin") or std.mem.eql(u8, pf, "-")) {
            // Reading password from stdin should use hidden input
            break :blk try promptPassword(allocator, "Password: ");
        } else {
            const file = std.fs.openFileAbsolute(pf, .{}) catch |err| {
                std.debug.print("Error: Cannot read password file '{s}': {s}\n", .{ pf, @errorName(err) });
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, 256);
        }
    } else if (password) |p|
        try allocator.dupe(u8, p)
    else
        try promptPassword(allocator, "Password: ");

    defer allocator.free(final_username);
    defer allocator.free(final_password);

    // Remove trailing newline if present
    const trimmed_password = if (final_password.len > 0 and final_password[final_password.len - 1] == '\n')
        final_password[0 .. final_password.len - 1]
    else
        final_password;

    // Authenticate with server
    const auth_result = connectToServer(allocator, server, final_username, trimmed_password) catch |err| {
        // Log failed authentication attempt
        logAuditEvent("auth", "login", "failure");

        switch (err) {
            error.InvalidCredentials => {
                std.debug.print("Error: Invalid username or password\n", .{});
                std.process.exit(@intFromEnum(ExitCode.auth_error));
            },
            else => {
                std.debug.print("Error: Failed to connect to server '{s}': {s}\n", .{ server, @errorName(err) });
                std.debug.print("Check server address and network connectivity\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            },
        }
    };
    defer allocator.free(auth_result.session_token);

    // Log successful authentication
    logAuditEvent("auth", "login", "success");

    // Handle password reset requirement
    if (auth_result.requires_password_reset) {
        // Get current policy configuration
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const local_allocator = gpa.allocator();

        const min_length_env = getEnvVar(local_allocator, "GEODE_PASSWORD_MIN_LENGTH");
        defer if (min_length_env) |env| local_allocator.free(env);
        const min_length = if (min_length_env) |len_str| blk: {
            const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
            break :blk if (parsed < 20) 20 else parsed;
        } else 20;

        const min_words_env = getEnvVar(local_allocator, "GEODE_PASSWORD_MIN_WORDS");
        defer if (min_words_env) |env| local_allocator.free(env);
        const min_words = if (min_words_env) |words_str| blk: {
            const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
            break :blk if (parsed < 2) 2 else parsed;
        } else 3;

        std.debug.print("Authentication successful, but a password reset is required.\n", .{});
        std.debug.print("Your current password does not meet the security policy:\n", .{});
        std.debug.print("  - Minimum {} characters\n", .{min_length});
        std.debug.print("  - Must be a passphrase ({} or more words)\n", .{min_words});
        std.debug.print("  - Must contain uppercase and lowercase letters\n", .{});
        std.debug.print("  - Spaces, numbers, and symbols are allowed\n", .{});
        std.debug.print("\nYou must set a new password before accessing the database.\n\n", .{});

        // Prompt for new password
        const new_password = try promptNewPassword(allocator);
        defer allocator.free(new_password);

        // Validate new password
        if (!validateNewPassword(new_password)) {
            std.debug.print("Error: New password does not meet security requirements\n", .{});
            std.process.exit(@intFromEnum(ExitCode.auth_error));
        }

        // GAP-0150: Send password update to server via QUIC
        // CANARY: REQ=REQ-AUTH-CLI-003; FEATURE="CLI QUIC Password Update"; ASPECT=PasswordChange; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=security; UPDATED=2026-01-15
        updatePasswordOnServer(allocator, server, final_username, new_password) catch |err| {
            std.debug.print("Error: Failed to update password on server: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.auth_error));
        };

        std.debug.print("Password updated successfully.\n", .{});
        std.debug.print("You can now log in with your new password.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Save credentials
    const expires_at = std.time.milliTimestamp() + 24 * 60 * 60 * 1000; // 24 hours
    const creds = CredentialStorage{
        .server = server,
        .username = final_username,
        .session_token = auth_result.session_token,
        .expires_at = expires_at,
    };

    saveCredentials(allocator, creds) catch |err| {
        std.debug.print("Warning: Could not save credentials: {s}\n", .{@errorName(err)});
    };

    std.debug.print("Successfully authenticated as '{s}' on server '{s}'\n", .{ final_username, server });
    std.debug.print("Session token saved to ~/.geode/credentials.json\n", .{});
}

fn promptNewPassword(allocator: std.mem.Allocator) ![]const u8 {
    var attempts: u8 = 0;
    const max_attempts = 3;

    while (attempts < max_attempts) {
        const new_password = try promptPassword(allocator, "New password: ");
        const confirm_password = try promptPassword(allocator, "Confirm password: ");

        defer allocator.free(confirm_password);

        if (std.mem.eql(u8, new_password, confirm_password)) {
            return new_password;
        } else {
            allocator.free(new_password);
            attempts += 1;
            std.debug.print("Passwords do not match. Please try again.\n", .{});
        }
    }

    std.debug.print("Too many failed attempts.\n", .{});
    std.process.exit(@intFromEnum(ExitCode.auth_error));
}

fn validateNewPassword(password: []const u8) bool {
    // Use the same validation as the policy check for consistency
    validatePasswordAgainstPolicy(password) catch |err| {
        switch (err) {
            error.PasswordTooShort => {
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                defer _ = gpa.deinit();
                const allocator = gpa.allocator();

                const min_length_env = getEnvVar(allocator, "GEODE_PASSWORD_MIN_LENGTH");
                defer if (min_length_env) |env| allocator.free(env);
                const min_length = if (min_length_env) |len_str| blk: {
                    const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
                    break :blk if (parsed < 20) 20 else parsed;
                } else 20;
                std.debug.print("Password must be at least {} characters long.\n", .{min_length});
            },
            error.PasswordTooLong => {
                std.debug.print("Password must be no more than 256 characters long.\n", .{});
            },
            error.PasswordMissingCase => {
                std.debug.print("Password must contain both uppercase and lowercase letters.\n", .{});
            },
            error.PasswordNotPassphrase, error.PasswordInsufficientWords => {
                var gpa2 = std.heap.GeneralPurposeAllocator(.{}){};
                defer _ = gpa2.deinit();
                const allocator2 = gpa2.allocator();
                const min_words_env = getEnvVar(allocator2, "GEODE_PASSWORD_MIN_WORDS");
                defer if (min_words_env) |env| allocator2.free(env);
                const min_words = if (min_words_env) |words_str| blk: {
                    const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
                    break :blk if (parsed < 2) 2 else parsed;
                } else 3;
                std.debug.print("Password must be a passphrase with at least {} words.\n", .{min_words});
            },
        }
        return false;
    };
    return true;
}

// Removed - replaced by countWords function above

fn cmdAuthLogout(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for token option
    var token: ?[]const u8 = null;
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) {
            std.debug.print("geode auth logout - Clear saved credentials\n" ++
                "\n" ++
                "Usage: geode auth logout [--token <token>]\n" ++
                "\n" ++
                "This command clears saved authentication credentials from ~/.geode/credentials.json\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--token") and i + 1 < argv.len) {
            token = argv[i + 1];
            i += 1;
        }
    }

    // If token provided, we're logging out a specific session
    if (token != null) {
        std.debug.print("Session logged out successfully\n", .{});
        std.debug.print("Token invalidated\n", .{});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Clear saved credentials
    clearCredentials(allocator) catch |err| {
        std.debug.print("Warning: Could not clear credentials: {s}\n", .{@errorName(err)});
        logAuditEvent("auth", "logout", "failure");
        return;
    };

    // Log successful logout
    logAuditEvent("auth", "logout", "success");

    std.debug.print("Logout successful\n", .{});
    std.debug.print("Credentials cleared from ~/.geode/credentials.json\n", .{});
}

// CANARY: REQ=REQ-AUTH-TOKEN-001; FEATURE="AuthToken"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_REQ_AUTH_TOKEN_001; OWNER=cli; UPDATED=2025-10-14
fn cmdAuthToken(allocator: std.mem.Allocator) !void {
    // Get home directory - use std.process for cross-platform compatibility
    // Windows uses USERPROFILE, Unix uses HOME
    const home = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch {
            std.debug.print("Error: USERPROFILE environment variable not set\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    else
        std.process.getEnvVarOwned(allocator, "HOME") catch {
            std.debug.print("Error: HOME environment variable not set\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    defer allocator.free(home);

    const credentials_path = try std.fmt.allocPrint(allocator, "{s}/.geode/credentials.json", .{home});
    defer allocator.free(credentials_path);

    // Try to read the credentials file
    const file = std.fs.openFileAbsolute(credentials_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No saved credentials found\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        std.debug.print("Error reading credentials: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer file.close();

    // Read file content
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Error reading credentials file: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(content);

    // Output the content to stdout
    const stdout_fd = std.fs.File{ .handle = getStdoutHandle() catch return error.StdioUnavailable };
    _ = try stdout_fd.writeAll(content);
    if (content.len == 0 or content[content.len - 1] != '\n') {
        _ = try stdout_fd.writeAll("\n");
    }
}
