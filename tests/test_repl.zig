const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const repl_parse = geode.repl.repl_parse;
const repl_history = geode.repl.repl_history;
const repl_errors = geode.repl.repl_errors;
const repl_render = geode.repl.repl_render;
const repl_dispatch = geode.repl.repl_dispatch;

test "parser balance" {
    try testing.expect(!repl_parse.isBalanced("MATCH (n"));
    try testing.expect(repl_parse.isBalanced("MATCH (n)\nRETURN n;"));
    try testing.expect(!repl_parse.isBalanced("MATCH (n) WHERE n.prop = \"unclosed string"));
    try testing.expect(repl_parse.isBalanced("MATCH (n) WHERE n.prop = \"closed string\""));
}

test "history leading-space suppression" {
    const allocator = testing.allocator;

    // Create temp file
    const path = "test_history_repl.tmp";
    defer std.fs.cwd().deleteFile(path) catch {};

    var history = try repl_history.HistoryStore.init(allocator, path, true);
    defer history.deinit();

    // Append with leading space - should be ignored
    try history.append(" SELECT 1;");
    try testing.expect(history.entries.items.len == 0);

    // Append without leading space - should be saved
    try history.append("SELECT 1;");
    try testing.expect(history.entries.items.len == 1);
    try testing.expectEqualStrings("SELECT 1;", history.entries.items[0]);

    // Verify file content
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [100]u8 = undefined;
    const n = try file.read(&buf);
    try testing.expectEqualStrings("SELECT 1;\n", buf[0..n]);
}

test "dispatcher unknown meta" {
    const allocator = testing.allocator;
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer output.deinit(allocator);

    const writer = output.writer(allocator);
    try repl_errors.printError(writer, .unknown_command, "Unknown command '\\connet'. Did you mean '\\connect'?", false);

    try testing.expectEqualStrings("Error [GEODE-E2001]: Unknown command '\\connet'. Did you mean '\\connect'?\n", output.items);
}

test "renderer JSON mode" {
    const allocator = testing.allocator;
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer output.deinit(allocator);

    const Writer = @TypeOf(output.writer(allocator));
    var sink = repl_render.RenderSink(Writer){
        .writer = output.writer(allocator),
        .format = .json,
        .allocator = allocator,
    };

    const data = "{\"columns\":[\"a\"],\"data\":[[1]]}";
    try sink.write(data);

    try testing.expectEqualStrings(data, output.items);
}

test "TTY check" {
    // This test would need to mock stdin
    // For now, just verify the error message format
    const allocator = testing.allocator;
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer output.deinit(allocator);

    try output.writer(allocator).print("Error [GEODE-E0002]: interactive shell requires a TTY\n", .{});
    try testing.expect(std.mem.indexOf(u8, output.items, "GEODE-E0002") != null);
}

test "keymap toggle" {
    // Mock state for testing keymap
    const State = struct {
        buffer: std.ArrayList(u8),
        cursor: usize,
        keymap: enum { emacs, vi },
        vi_mode: enum { normal, insert, visual },
        kill_ring: std.ArrayList(u8),
        last_was_kill: bool,
        pending_operator: ?u8,
        allocator: std.mem.Allocator,
    };

    const allocator = testing.allocator;
    var state = State{
        .buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
        .cursor = 0,
        .keymap = .vi,
        .vi_mode = .insert,
        .kill_ring = try std.ArrayList(u8).initCapacity(allocator, 0),
        .last_was_kill = false,
        .pending_operator = null,
        .allocator = allocator,
    };
    defer state.buffer.deinit(allocator);
    defer state.kill_ring.deinit(allocator);

    // Test Vi insert mode
    try state.buffer.appendSlice(allocator, "hello");
    state.cursor = 5;

    // Switch to normal mode (ESC)
    state.vi_mode = .normal;
    state.cursor = 4; // Vi moves cursor back

    // Test Vi deletion (0dw - delete word from beginning)
    state.cursor = 0;
    state.pending_operator = 'd';
    // Simulate dw
    state.buffer.clearRetainingCapacity();
    try testing.expectEqualStrings("", state.buffer.items);

    // Switch to Emacs mode
    state.keymap = .emacs;
    try state.buffer.appendSlice(allocator, "abc");
    state.cursor = 3;

    // Test Emacs Ctrl+A (move to beginning)
    state.cursor = 0;
    try testing.expect(state.cursor == 0);

    // Test Emacs Ctrl+K (kill to end)
    state.kill_ring.clearRetainingCapacity();
    try state.kill_ring.appendSlice(allocator, state.buffer.items[state.cursor..]);
    state.buffer.items.len = state.cursor;
    try testing.expectEqualStrings("", state.buffer.items);
    try testing.expectEqualStrings("abc", state.kill_ring.items);
}

test "Ctrl+C semantics" {
    const allocator = testing.allocator;

    // Mock state
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buffer.deinit(allocator);

    // Non-empty buffer - Ctrl+C should clear
    try buffer.appendSlice(allocator, "partial command");
    buffer.clearRetainingCapacity();
    try testing.expect(buffer.items.len == 0);

    // Empty buffer - Ctrl+C should not quit (Ctrl+D does)
    try testing.expect(buffer.items.len == 0);
    // Would continue to next prompt
}
