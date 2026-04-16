// Module implementation
// LSP transport layer using Content-Length headers over stdio
// Spec: specs/lsp/language-server-protocol/_specifications/base/0.9/specification.md

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

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

    pub fn readMessage(self: *Transport) ![]const u8 {
        var content_length: ?usize = null;
        var buf: [1024]u8 = undefined;
        var first_read = true;

        // Read headers
        while (true) {
            const maybe_line = try self.readLine(&buf);
            if (maybe_line == null) {
                // EOF on first read means client disconnected
                if (first_read) return TransportError.EndOfStream;
                break;
            }
            first_read = false;

            const line = maybe_line.?;
            if (line.len == 0) break; // Empty line separates headers from content

            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                const length_str = line["Content-Length: ".len..];
                content_length = std.fmt.parseInt(usize, length_str, 10) catch {
                    return TransportError.InvalidContentLength;
                };
            }
            // Ignore Content-Type and other headers
        }

        if (content_length == null) {
            return TransportError.MissingContentLength;
        }

        // Read content
        const content = try self.allocator.alloc(u8, content_length.?);
        errdefer self.allocator.free(content);

        var total_read: usize = 0;
        while (total_read < content_length.?) {
            const n = try self.stdin.readStreaming(self.io, &.{content[total_read..]});
            if (n == 0) {
                self.allocator.free(content);
                return TransportError.EndOfStream;
            }
            total_read += n;
        }

        return content;
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

    fn readLine(self: *Transport, buf: []u8) !?[]const u8 {
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            const n = try self.stdin.readStreaming(self.io, &.{buf[i .. i + 1]});
            if (n == 0) {
                // EOF - return null if no data read, otherwise return what we have
                if (i == 0) return null;
                return buf[0..i];
            }
            if (buf[i] == '\n') {
                // Remove \r\n or \n
                const end = if (i > 0 and buf[i - 1] == '\r') i - 1 else i;
                return buf[0..end];
            }
        }
        return buf[0..i];
    }
};
