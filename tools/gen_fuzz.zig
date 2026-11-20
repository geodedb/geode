const std = @import("std");

pub const Options = struct {
    canary: []const u8,
    module: ?[]const u8 = null,
};

/// Parses the arguments after the program name. Returns null when they are
/// not a valid invocation (missing --canary, a flag without its value, or an
/// unknown argument), so the caller prints the usage line.
pub fn parseArgs(args: []const [:0]const u8) ?Options {
    var canary: ?[]const u8 = null;
    var module: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--canary")) {
            if (i + 1 >= args.len) return null;
            canary = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--module")) {
            if (i + 1 >= args.len) return null;
            module = args[i + 1];
            i += 1;
        } else {
            return null;
        }
    }
    return .{ .canary = canary orelse return null, .module = module };
}

pub const Outcome = enum { created, exists };

/// Creates `fuzz/targets/<name>_fuzz.zig` and `fuzz/corpora/<name>/` under
/// `root`. An existing target is never overwritten.
pub fn generate(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, name: []const u8) !Outcome {
    try root.createDirPath(io, "fuzz/targets");
    const corp_dir = try std.fs.path.join(allocator, &.{ "fuzz", "corpora", name });
    defer allocator.free(corp_dir);
    try root.createDirPath(io, corp_dir);

    const target_name = try std.fmt.allocPrint(allocator, "{s}_fuzz.zig", .{name});
    defer allocator.free(target_name);
    const target_path = try std.fs.path.join(allocator, &.{ "fuzz", "targets", target_name });
    defer allocator.free(target_path);

    var f = root.createFile(io, target_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return .exists,
        else => |e| return e,
    };
    defer f.close(io);
    try f.writeStreamingAll(io, scaffold(name));
    return .created;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = parseArgs(if (argv.len > 0) argv[1..] else argv) orelse usage(io, 2);

    const name = mapCanary(opts.canary, opts.module);
    const outcome = try generate(allocator, io, std.Io.Dir.cwd(), name);

    const verb = switch (outcome) {
        .created => "Created",
        .exists => "Already exists, left unchanged",
    };
    const out = try std.fmt.allocPrint(allocator, "{s}: fuzz/targets/{s}_fuzz.zig (canary={s})\n", .{ verb, name, opts.canary });
    defer allocator.free(out);
    std.Io.File.stdout().writeStreamingAll(io, out) catch {};
}

fn usage(io: std.Io, code: u8) noreturn {
    std.Io.File.stderr().writeStreamingAll(io, "USAGE: zig build gen-fuzz -- --canary <ID|TestName> [--module <path>]\n") catch {};
    std.process.exit(code);
}

pub fn mapCanary(id: []const u8, module: ?[]const u8) []const u8 {
    _ = module;
    if (std.mem.eql(u8, id, "REQ-GQL-068")) return "lfu_cache";
    if (std.mem.eql(u8, id, "REQ-GQL-030")) return "txn_sequence";
    if (std.mem.eql(u8, id, "REQ-GQL-005")) return "protocol_hello";
    return "parser";
}

pub fn scaffold(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "lfu_cache"))
        "const std = @import(\"std\");\nconst lfu = @import(\"../../src/graph/containers/lfu.zig\");\nfn fuzz(_: void, data: []const u8) !void { if (data.len == 0) return; var c = lfu.LfuU32U32.init(std.testing.allocator, (data[0]%16)); defer c.deinit(); }\ntest \"fuzz lfu cache\" { try std.testing.fuzz(.{ .max_input_len = 8192 }, fuzz, .{}); std.debug.print(\"fuzzing: completed\\n\", .{}); }\n"
    else if (std.mem.eql(u8, name, "txn_sequence"))
        "const std = @import(\"std\");\nconst txn = @import(\"txn\");\nfn fuzz(_: void, data: []const u8) !void { var m: txn.Manager = undefined; m.init(std.testing.allocator); defer m.deinit(); var i:usize=0; while(i<data.len): (i+=1){ switch(data[i]%3){0=>{_ = m.begin();},1=>{},2=>{},else=>{}} }}\ntest \"fuzz txn sequence\" { try std.testing.fuzz(.{ .max_input_len = 4096 }, fuzz, .{}); std.debug.print(\"fuzzing: completed\\n\", .{}); }\n"
    else if (std.mem.eql(u8, name, "protocol_hello"))
        "const std = @import(\"std\");\nconst protocol = @import(\"../../src/protocol.zig\");\nfn fuzz(_: void, data: []const u8) !void { const ally=std.testing.allocator; _ = protocol.parseClientMessage(ally, data[0..@min(data.len,4096)]) catch return; }\ntest \"fuzz protocol hello\" { try std.testing.fuzz(.{ .max_input_len = 4096 }, fuzz, .{}); std.debug.print(\"fuzzing: completed\\n\", .{}); }\n"
    else
        "const std = @import(\"std\");\nconst geode = @import(\"geode\");\nfn fuzz(_: void, data: []const u8) !void { const opts: geode.ParseOptions = .{ .ident_order_only = true, .forbid_orderby_calls = true }; _ = geode.parseGqlOutcome(data[0..@min(data.len, 65536)], std.testing.allocator, opts) catch return; }\ntest \"fuzz parser\" { try std.testing.fuzz(.{ .max_input_len = 65536 }, fuzz, .{}); std.debug.print(\"fuzzing: completed\\n\", .{}); }\n";
}
