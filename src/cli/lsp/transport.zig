// Module implementation
// LSP transport layer using Content-Length headers over stdio
// Spec: specs/lsp/language-server-protocol/_specifications/base/0.9/specification.md

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const framer_mod = @import("framer.zig");

// Import Windows-specific types when needed
const windows = if (builtin.os.tag == .windows) std.os.windows else struct {};

pub const TransportError = error{
    InvalidHeader,
    MissingContentLength,
    InvalidContentLength,
    ReadFailed,
    WriteFailed,
    EndOfStream,
    StdioUnavailable,
};

// CANARY: REQ=REQ-LSP-SEC-001; FEATURE="ContentLengthCap"; ASPECT=DoSGuard; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06
// LSP-SEC-001: Maximum LSP message size. The JSON-RPC framing layer rejects
// any Content-Length header above this value before allocating the body
// buffer. This bounds the worst-case memory request from a malicious or
// misbehaving client to 16 MiB (well above any realistic LSP payload).
pub const MAX_LSP_MESSAGE: usize = 16 * 1024 * 1024;

/// Parse a Content-Length header value, applying the LSP-SEC-001 cap.
/// Returns `TransportError.InvalidContentLength` for non-numeric input or
/// values strictly greater than `MAX_LSP_MESSAGE`.
pub fn parseContentLength(value: []const u8) TransportError!usize {
    const parsed = std.fmt.parseInt(usize, value, 10) catch {
        return TransportError.InvalidContentLength;
    };
    if (parsed > MAX_LSP_MESSAGE) {
        return TransportError.InvalidContentLength;
    }
    return parsed;
}

// CANARY: REQ=REQ-QUALITY-GAP-406-003; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
// Cross-platform file handle helpers with proper error handling
fn getStdinHandle() TransportError!std.Io.File.Handle {
    if (builtin.os.tag == .windows) {
        const handle = windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch return error.StdioUnavailable;
        if (handle == windows.INVALID_HANDLE_VALUE) return error.StdioUnavailable;
        return handle;
    } else {
        return std.posix.STDIN_FILENO;
    }
}

fn getStdoutHandle() TransportError!std.Io.File.Handle {
    if (builtin.os.tag == .windows) {
        const handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch return error.StdioUnavailable;
        if (handle == windows.INVALID_HANDLE_VALUE) return error.StdioUnavailable;
        return handle;
    } else {
        return std.posix.STDOUT_FILENO;
    }
}

fn getStderrHandle() TransportError!std.Io.File.Handle {
    if (builtin.os.tag == .windows) {
        const handle = windows.GetStdHandle(windows.STD_ERROR_HANDLE) catch return error.StdioUnavailable;
        if (handle == windows.INVALID_HANDLE_VALUE) return error.StdioUnavailable;
        return handle;
    } else {
        return 2;
    }
}

/// Task 25: `Transport` is now a tagged union so Task 26 can plug in a
/// TCP variant for the embedded `geode serve` LSP listener. The stdio
/// behavior is byte-for-byte identical to the previous concrete-struct
/// implementation — every field and method just lives on
/// `StdioTransport` now.
pub const Transport = union(enum) {
    stdio: StdioTransport,
    tcp: TcpTransport,
    noop: NoopTransport,

    pub fn initStdio(allocator: Allocator) TransportError!Transport {
        return .{ .stdio = try StdioTransport.init(allocator) };
    }

    /// Task 26: wrap an already-connected `std.Io.net.Stream` in the
    /// Transport union. The caller owns the socket lifecycle until
    /// `deinit` runs (we close on deinit). `io` is the same Io vtable
    /// the listener / connector used so reads/writes use the same
    /// scheduler. `framing` is byte-for-byte identical to the stdio
    /// path — Content-Length headers honoring the
    /// `MAX_LSP_MESSAGE` cap.
    pub fn initTcp(allocator: Allocator, io: std.Io, stream: std.Io.net.Stream) TransportError!Transport {
        return .{ .tcp = try TcpTransport.init(allocator, io, stream) };
    }

    /// Test-only: a transport that discards every write and returns
    /// `EndOfStream` on every read. Lets unit tests drive
    /// `Server.handleMessage` without polluting real stdout — which
    /// matters specifically under `zig build test --listen=-`, where
    /// the binary's stdout IS the test runner protocol pipe and any
    /// stray byte corrupts the framing and deadlocks the runner. See
    /// `server_auth_test.zig` for the call site.
    pub fn initNoop(allocator: Allocator) Transport {
        return .{ .noop = NoopTransport.init(allocator) };
    }

    pub fn deinit(self: *Transport) void {
        switch (self.*) {
            .stdio => |*s| if (@hasDecl(StdioTransport, "deinit")) s.deinit(),
            .tcp => |*t| t.deinit(),
            .noop => |*n| n.deinit(),
        }
    }

    pub fn readMessage(self: *Transport) ![]const u8 {
        return switch (self.*) {
            .stdio => |*s| s.readMessage(),
            .tcp => |*t| t.readMessage(),
            .noop => |*n| n.readMessage(),
        };
    }

    pub fn writeMessage(self: *Transport, msg: []const u8) !void {
        return switch (self.*) {
            .stdio => |*s| s.writeMessage(msg),
            .tcp => |*t| t.writeMessage(msg),
            .noop => |*n| n.writeMessage(msg),
        };
    }

    pub fn logMessage(self: *Transport, level: []const u8, msg: []const u8) void {
        switch (self.*) {
            .stdio => |*s| s.logMessage(level, msg),
            .tcp => |*t| t.logMessage(level, msg),
            .noop => |*n| n.logMessage(level, msg),
        }
    }
};

pub const StdioTransport = struct {
    allocator: Allocator,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    io: std.Io,

    pub fn init(allocator: Allocator) TransportError!StdioTransport {
        return .{
            .allocator = allocator,
            .stdin = std.Io.File{ .handle = try getStdinHandle(), .flags = .{ .nonblocking = false } },
            .stdout = std.Io.File{ .handle = try getStdoutHandle(), .flags = .{ .nonblocking = false } },
            .stderr = std.Io.File{ .handle = try getStderrHandle(), .flags = .{ .nonblocking = false } },
            .io = std.Io.Threaded.global_single_threaded.io(),
        };
    }

    /// F-04: ReadFn adapter — bridges the framer's single-buffer
    /// callback signature to std.Io.File.readStreaming's multi-buffer
    /// signature. The framer hands us a destination slice; we forward
    /// it as a single-element [][]u8 vector.
    fn readStreamingAdapter(ctx: *anyopaque, dest: []u8) framer_mod.FramerError!usize {
        const self: *StdioTransport = @ptrCast(@alignCast(ctx));
        const n = self.stdin.readStreaming(self.io, &.{dest}) catch {
            return framer_mod.FramerError.ReadFailed;
        };
        return n;
    }

    pub fn readMessage(self: *StdioTransport) ![]const u8 {
        // F-04: delegate to the buffered framer. The framer owns a 4 KiB
        // read-ahead buffer and uses parseContentLength's cap (16 MiB)
        // implicitly via MAX_LSP_MESSAGE.
        var f = framer_mod.Framer.init(readStreamingAdapter, self);
        const body = f.readMessage(MAX_LSP_MESSAGE, self.allocator) catch |err| switch (err) {
            framer_mod.FramerError.EndOfStream => return TransportError.EndOfStream,
            framer_mod.FramerError.MissingContentLength => return TransportError.MissingContentLength,
            framer_mod.FramerError.InvalidContentLength => return TransportError.InvalidContentLength,
            framer_mod.FramerError.InvalidHeader => return TransportError.InvalidHeader,
            framer_mod.FramerError.ReadFailed => return TransportError.ReadFailed,
            framer_mod.FramerError.OutOfMemory => return error.OutOfMemory,
        };
        return body;
    }

    pub fn writeMessage(self: *StdioTransport, message: []const u8) !void {
        // Write headers
        const header = try std.fmt.allocPrint(
            self.allocator,
            "Content-Length: {d}\r\n\r\n",
            .{message.len},
        );
        defer self.allocator.free(header);

        try self.stdout.writeStreamingAll(self.io, header);
        try self.stdout.writeStreamingAll(self.io, message);
    }

    pub fn logMessage(self: *StdioTransport, level: []const u8, message: []const u8) void {
        const msg = std.fmt.allocPrint(self.allocator, "[{s}] {s}\n", .{ level, message }) catch return;
        defer self.allocator.free(msg);
        self.stderr.writeStreamingAll(self.io, msg) catch {};
    }
};

/// Task 26: TCP-backed LSP transport. Same Content-Length framing as the
/// stdio path; only the underlying byte source changes from a stdio
/// FD pair to a single full-duplex `std.Io.net.Stream`. Used by the
/// `geode lsp --listen tcp://…` entry point (Task 27) and the embedded
/// LSP listener inside `geode serve` (Task 28). The `MAX_LSP_MESSAGE`
/// cap is honored exactly as in stdio — the framer rejects oversize
/// Content-Length headers before allocating a body buffer.
pub const TcpTransport = struct {
    allocator: Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,

    pub fn init(allocator: Allocator, io: std.Io, stream: std.Io.net.Stream) TransportError!TcpTransport {
        return .{ .allocator = allocator, .io = io, .stream = stream };
    }

    pub fn deinit(self: *TcpTransport) void {
        self.stream.close(self.io);
    }

    /// Framer adapter — Zig 0.16 has no `std.net.Stream.read(dest)`;
    /// the canonical socket-read path goes through
    /// `io.vtable.netRead(..., handle, [][]u8)`. We pass the framer's
    /// single-buffer destination as a one-element iovec so the framer's
    /// 4 KiB read-ahead semantics are identical to the stdio path
    /// (which uses `std.Io.File.readStreaming`'s identically-shaped
    /// multi-buffer signature).
    fn readAdapter(ctx: *anyopaque, dest: []u8) framer_mod.FramerError!usize {
        const self: *TcpTransport = @ptrCast(@alignCast(ctx));
        var data: [1][]u8 = .{dest};
        const n = self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &data) catch {
            return framer_mod.FramerError.ReadFailed;
        };
        return n;
    }

    pub fn readMessage(self: *TcpTransport) ![]const u8 {
        var f = framer_mod.Framer.init(readAdapter, self);
        return f.readMessage(MAX_LSP_MESSAGE, self.allocator) catch |e| switch (e) {
            framer_mod.FramerError.EndOfStream => return TransportError.EndOfStream,
            framer_mod.FramerError.MissingContentLength => return TransportError.MissingContentLength,
            framer_mod.FramerError.InvalidContentLength => return TransportError.InvalidContentLength,
            framer_mod.FramerError.InvalidHeader => return TransportError.InvalidHeader,
            framer_mod.FramerError.ReadFailed => return TransportError.ReadFailed,
            framer_mod.FramerError.OutOfMemory => return error.OutOfMemory,
        };
    }

    pub fn writeMessage(self: *TcpTransport, message: []const u8) !void {
        const header = try std.fmt.allocPrint(
            self.allocator,
            "Content-Length: {d}\r\n\r\n",
            .{message.len},
        );
        defer self.allocator.free(header);

        // std.Io.net.Stream has no `writeAll` convenience method — the
        // canonical full-write path is the buffered `Writer` interface.
        // We use a stack buffer just large enough to hold the LSP header
        // plus a small body; the buffer is flushed inside `writeAll`
        // when the framer demands progress, so the 1 KiB cap does not
        // bound message size.
        var write_buf: [1024]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        try w.interface.writeAll(header);
        try w.interface.writeAll(message);
        try w.interface.flush();
    }

    pub fn logMessage(_: *TcpTransport, _: []const u8, _: []const u8) void {
        // TCP transport: no separate stderr channel. LSP clients
        // already receive structured diagnostics over the JSON-RPC
        // channel; silently dropping plain log lines is the
        // spec-compliant choice (vs. polluting the protocol stream).
    }
};

/// Test-only transport that discards every write and returns
/// `EndOfStream` on every read. Used by tests that exercise
/// `Server.handleMessage` end-to-end without touching the process's
/// real stdout. Under `zig build test --listen=-` the test binary's
/// stdout is the test-runner protocol pipe; an LSP test writing a
/// Content-Length response there corrupts the framing and deadlocks
/// the runner (zig polls for protocol messages it will never see,
/// child blocks on stdin for instructions it can no longer parse).
pub const NoopTransport = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) NoopTransport {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *NoopTransport) void {}

    pub fn readMessage(_: *NoopTransport) TransportError![]const u8 {
        return TransportError.EndOfStream;
    }

    pub fn writeMessage(_: *NoopTransport, _: []const u8) TransportError!void {
        // Drop the message on the floor. Tests that need to inspect
        // the response should reach into Server state directly
        // (see `server_auth_test.zig`'s post-condition asserts).
    }

    pub fn logMessage(_: *NoopTransport, _: []const u8, _: []const u8) void {
        // Drop log lines on the floor.
    }
};
