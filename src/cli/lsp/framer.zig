// LSP-SEC-001 + F-04: pure JSON-RPC frame parser.
//
// The Framer processes Content-Length-framed LSP traffic from a
// pull-based reader without burning a syscall per byte. It owns a
// 4 KiB read-ahead buffer and parses headers byte-by-byte from that
// buffer, refilling only when the buffer drains. Body reads are then
// served first from any leftover bytes already in the buffer, then
// from the underlying stream.
//
// CANARY: REQ=REQ-PERF-F-04; FEATURE="BufferedTransport"; ASPECT=Throughput; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06

const std = @import("std");

pub const FramerError = error{
    InvalidHeader,
    MissingContentLength,
    InvalidContentLength,
    EndOfStream,
    ReadFailed,
    OutOfMemory,
};

/// Caller-supplied reader. Returns the number of bytes written into
/// `dest`; 0 means EOF; an error means a transport-level failure.
pub const ReadFn = *const fn (ctx: *anyopaque, dest: []u8) FramerError!usize;

const BUF_SIZE: usize = 4096;

/// LSP-SEC-001 cap. Re-declared here for layering convenience; the
/// transport-level constant in transport.zig is the source of truth.
pub const MAX_LSP_MESSAGE: usize = 16 * 1024 * 1024;

pub const Framer = struct {
    read_fn: ReadFn,
    read_ctx: *anyopaque,
    /// Read counter — exposed for tests to assert syscall-amortization
    /// behavior. Production code may ignore it.
    read_calls: usize = 0,
    buf: [BUF_SIZE]u8 = undefined,
    buf_pos: usize = 0,
    buf_len: usize = 0,

    pub fn init(read_fn: ReadFn, read_ctx: *anyopaque) Framer {
        return .{ .read_fn = read_fn, .read_ctx = read_ctx };
    }

    fn refill(self: *Framer) FramerError!bool {
        if (self.buf_pos < self.buf_len) return true;
        self.buf_pos = 0;
        self.buf_len = 0;
        self.read_calls += 1;
        const n = try self.read_fn(self.read_ctx, &self.buf);
        if (n == 0) return false;
        self.buf_len = n;
        return true;
    }

    /// Read one Content-Length: header line into `out`, stopping at \r\n
    /// or \n. Returns the line slice (excluding terminator) on success,
    /// or null on EOF before any byte is consumed.
    fn readLine(self: *Framer, out: []u8) FramerError!?[]const u8 {
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            if (self.buf_pos >= self.buf_len) {
                const got = try self.refill();
                if (!got) {
                    if (i == 0) return null;
                    return out[0..i];
                }
            }
            const c = self.buf[self.buf_pos];
            self.buf_pos += 1;
            if (c == '\n') {
                const end = if (i > 0 and out[i - 1] == '\r') i - 1 else i;
                return out[0..end];
            }
            out[i] = c;
        }
        return out[0..i];
    }

    /// Read exactly `len` bytes into `dest`. Serves first from the
    /// internal buffer, then from the underlying reader. Returns
    /// EndOfStream if the source dries up before `len` bytes are
    /// gathered.
    fn readExact(self: *Framer, dest: []u8) FramerError!void {
        var written: usize = 0;
        // First, drain any leftover bytes from the buffered headers.
        const leftover = self.buf_len - self.buf_pos;
        if (leftover > 0) {
            const take = @min(leftover, dest.len);
            @memcpy(dest[0..take], self.buf[self.buf_pos .. self.buf_pos + take]);
            self.buf_pos += take;
            written = take;
        }
        // Then drain from the underlying reader.
        while (written < dest.len) {
            self.read_calls += 1;
            const n = try self.read_fn(self.read_ctx, dest[written..]);
            if (n == 0) return FramerError.EndOfStream;
            written += n;
        }
    }

    /// Parse one LSP message: read headers, validate Content-Length
    /// against the cap, and read the body. Returns an owned body slice
    /// allocated from `body_alloc`; caller frees on success.
    pub fn readMessage(
        self: *Framer,
        max_msg: usize,
        body_alloc: std.mem.Allocator,
    ) FramerError![]u8 {
        var hdr: [256]u8 = undefined;
        var content_length: ?usize = null;
        var first = true;
        while (true) {
            const maybe_line = try self.readLine(&hdr);
            if (maybe_line == null) {
                if (first) return FramerError.EndOfStream;
                break;
            }
            first = false;
            const line = maybe_line.?;
            if (line.len == 0) break;
            const prefix = "Content-Length: ";
            if (std.mem.startsWith(u8, line, prefix)) {
                const v = std.fmt.parseInt(usize, line[prefix.len..], 10) catch {
                    return FramerError.InvalidContentLength;
                };
                if (v > max_msg) return FramerError.InvalidContentLength;
                content_length = v;
            }
        }
        const len = content_length orelse return FramerError.MissingContentLength;
        const body = body_alloc.alloc(u8, len) catch return FramerError.OutOfMemory;
        errdefer body_alloc.free(body);
        try self.readExact(body);
        return body;
    }
};
