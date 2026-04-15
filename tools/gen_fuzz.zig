const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    var canary: ?[]const u8 = null;
    var module: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--canary")) {
            if (i + 1 >= args.len) return usage(2);
            canary = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--module")) {
            if (i + 1 >= args.len) return usage(2);
            module = args[i + 1];
            i += 1;
        } else {
            return usage(2);
        }
    }
    if (canary == null) return usage(2);
    const id = canary.?;

    const derived = mapCanary(id, module);
    const target_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_fuzz.zig", .{derived});
    defer std.heap.page_allocator.free(target_name);
    const target_path = try std.fs.path.join(std.heap.page_allocator, &.{ "fuzz", "targets", target_name });
    defer std.heap.page_allocator.free(target_path);

    try std.Io.Dir.cwd().makePath("fuzz/targets");
    const corp_dir = try std.fs.path.join(std.heap.page_allocator, &.{ "fuzz", "corpora", derived });
    defer std.heap.page_allocator.free(corp_dir);
    try std.Io.Dir.cwd().makePath(corp_dir);

    if (!exists(target_path)) {
        var f = try std.Io.Dir.cwd().createFile(target_path, .{});
        defer f.close();
        const tmpl = try scaffold(derived);
        defer std.heap.page_allocator.free(tmpl);
        _ = try f.write(tmpl);
    }

    const out = try std.fmt.allocPrint(std.heap.page_allocator, "Created fuzz target: fuzz/targets/{s}_fuzz.zig (canary={s})\n", .{ derived, id });
    defer std.heap.page_allocator.free(out);
    const stdout = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    stdout.writeAll(out) catch {};
}

fn usage(code: u8) noreturn {
    const stderr = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };
    stderr.writeAll("USAGE: zig build gen-fuzz -- --canary <ID|TestName> [--module <path>]\n") catch {};
    std.process.exit(code);
}

fn exists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(path) catch return false;
    return true;
}

fn mapCanary(id: []const u8, module: ?[]const u8) []const u8 {
    _ = module;
    if (std.mem.eql(u8, id, "REQ-GQL-068")) return "lfu_cache";
    if (std.mem.eql(u8, id, "REQ-GQL-030")) return "txn_sequence";
    if (std.mem.eql(u8, id, "REQ-GQL-005")) return "protocol_hello";
    return "parser";
}

fn scaffold(name: []const u8) ![]u8 {
    const s = if (std.mem.eql(u8, name, "lfu_cache"))
        "const std = @import(\"std\");\nconst lfu = @import(\"../../src/graph/containers/lfu.zig\");\nfn fuzz(_: void, data: []const u8) !void { if (data.len == 0) return; var c = lfu.LfuU32U32.init(std.testing.allocator, (data[0]%16)); defer c.deinit(); }\ntest \"fuzz lfu cache\" { try std.testing.fuzz(.{ .max_input_len = 8192 }, fuzz, .{}); std.debug.print(\"fuzzing: completed\\n\", .{}); }\n"
    else if (std.mem.eql(u8, name, "txn_sequence"))
        "const std = @import(\"std\");\nconst txn = @import(\"txn\");\nfn fuzz(_: void, data: []const u8) !void { var m: txn.Manager = undefined; m.init(std.testing.allocator); defer m.deinit(); var i:usize=0; while(i<data.len): (i+=1){ switch(data[i]%3){0=>{_ = m.begin();},1=>{},2=>{},else=>{}} }}\ntest \"fuzz txn sequence\" { try std.testing.fuzz(.{ .max_input_len = 4096 }, fuzz, .{}); std.debug.print(\"fuzzing: completed\\n\", .{}); }\n"
    else if (std.mem.eql(u8, name, "protocol_hello"))
        "const std = @import(\"std\");\nconst protocol = @import(\"../../src/protocol.zig\");\nfn fuzz(_: void, data: []const u8) !void { const ally=std.testing.allocator; _ = protocol.parseClientMessage(ally, data[0..@min(data.len,4096)]) catch return; }\ntest \"fuzz protocol hello\" { try std.testing.fuzz(.{ .max_input_len = 4096 }, fuzz, .{}); std.debug.print(\"fuzzing: completed\\n\", .{}); }\n"
    else
        "const std = @import(\"std\");\nconst geode = @import(\"geode\");\nfn fuzz(_: void, data: []const u8) !void { const opts: geode.ParseOptions = .{ .ident_order_only = true, .forbid_orderby_calls = true }; _ = geode.parseGqlOutcome(data[0..@min(data.len, 65536)], std.testing.allocator, opts) catch return; }\ntest \"fuzz parser\" { try std.testing.fuzz(.{ .max_input_len = 65536 }, fuzz, .{}); std.debug.print(\"fuzzing: completed\\n\", .{}); }\n";
    return std.heap.page_allocator.dupe(u8, s);
}
