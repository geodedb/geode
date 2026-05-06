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

pub const Transport = struct {
    allocator: Allocator,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    io: std.Io,

    pub fn init(allocator: Allocator) TransportError!Transport {
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
        const self: *Transport = @ptrCast(@alignCast(ctx));
        const n = self.stdin.readStreaming(self.io, &.{dest}) catch {
            return framer_mod.FramerError.ReadFailed;
        };
        return n;
    }

    pub fn readMessage(self: *Transport) ![]const u8 {
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

    pub fn writeMessage(self: *Transport, message: []const u8) !void {
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

    pub fn logMessage(self: *Transport, level: []const u8, message: []const u8) void {
        const msg = std.fmt.allocPrint(self.allocator, "[{s}] {s}\n", .{ level, message }) catch return;
        defer self.allocator.free(msg);
        self.stderr.writeStreamingAll(self.io, msg) catch {};
    }
};
