// Shared helpers for the statement atomicity regressions (SONNY-2725,
// SONNY-3380, SONNY-3243, SONNY-3381): run a request through the real gRPC
// handlers in process (the SONNY-738 round 12 fixture), on a thread of its
// own with a large stack, and report its SQLSTATE or its row count.

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
pub const fx = @import("sonny738_r12_grpc_fixture.zig");

pub const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    code: ?[]const u8 = null,
    message: []const u8 = "",
    rows: usize = 0,
    err: ?anyerror = null,

    fn go(self: *Run) void {
        self.run() catch |e| {
            self.err = e;
        };
    }

    fn run(self: *Run) !void {
        const resp = try fx.execute(self.ga, self.session, self.query);
        switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| {
                self.code = e.code;
                self.message = e.message;
                return;
            },
            .schema => {},
            else => return,
        }
        const req = try fx.encodeProto(self.ga, schema.PullRequest{ .session_id = self.session, .page_size = 64 });
        const pull = try fx.decodeProto(schema.PullResponse, self.ga, try grpc.handlePull(req, self.ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| self.rows = p.rows.items.len,
            .@"error" => |e| {
                self.code = e.code;
                self.message = e.message;
            },
            else => return error.UnexpectedPayload,
        }
    }

    pub fn failed(self: Run) bool {
        return self.code != null or self.err != null;
    }
};

pub fn runOn(ga: std.mem.Allocator, session: []const u8, query: []const u8) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query };
    const t = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Run.go, .{&r});
    t.join();
    return r;
}

/// The rows `query` answers; it must run.
pub fn rowsOf(ga: std.mem.Allocator, session: []const u8, query: []const u8) !usize {
    const r = try runOn(ga, session, query);
    if (r.err) |e| return e;
    if (r.code) |c| {
        std.debug.print("{s}: refused {s} {s}\n", .{ query, c, r.message });
        return error.QueryFailed;
    }
    return r.rows;
}

/// `query` must run.
pub fn runs(ga: std.mem.Allocator, session: []const u8, query: []const u8) !void {
    _ = try rowsOf(ga, session, query);
}

/// `query` is refused with `code` (null: any refusal), and afterwards every
/// `(check, rows)` pair answers its row count: the statement left nothing.
pub fn expectAtomic(
    ga: std.mem.Allocator,
    session: []const u8,
    name: []const u8,
    query: []const u8,
    code: ?[]const u8,
    checks: []const Check,
) !void {
    const r = try runOn(ga, session, query);
    const code_ok = if (code) |c| (r.code != null and std.mem.eql(u8, c, r.code.?)) else r.failed();
    var clean = true;
    for (checks) |c| {
        const left = try rowsOf(ga, session, c.query);
        if (left != c.rows) {
            clean = false;
            std.debug.print("{s}: '{s}' answers {d} rows; expected {d}\n", .{ name, c.query, left, c.rows });
        }
    }
    if (!r.failed() or !code_ok or !clean) {
        std.debug.print("{s}: code={s} err={s} message={s}\n   q: {s}\n", .{
            name, r.code orelse "ran", if (r.err) |e| @errorName(e) else "-", r.message, query,
        });
    }
    try testing.expect(r.failed());
    try testing.expect(code_ok);
    try testing.expect(clean);
}

pub const Check = struct {
    query: []const u8,
    rows: usize,
};
