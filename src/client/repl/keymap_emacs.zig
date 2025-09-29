const std = @import("std");
const repl_loop = @import("repl_loop.zig");

pub fn handleKey(state: anytype, key: repl_loop.KeyEvent) repl_loop.KeyAction {
    if (key.ctrl) {
        return switch (key.key) {
            'a' => .move_bol, // Ctrl+A: beginning of line
            'e' => .move_eol, // Ctrl+E: end of line
            'b' => .move_left, // Ctrl+B: backward char
            'f' => .move_right, // Ctrl+F: forward char
            'p' => .history_prev, // Ctrl+P: previous history
            'n' => .history_next, // Ctrl+N: next history
            'd' => blk: { // Ctrl+D: delete char or EOF
                if (state.buffer.items.len == 0) {
                    break :blk .quit;
                } else if (state.cursor < state.buffer.items.len) {
                    _ = state.buffer.orderedRemove(state.cursor);
                }
                break :blk .none;
            },
            'k' => .delete_to_eol, // Ctrl+K: kill to end of line
            'u' => .delete_to_bol, // Ctrl+U: kill to beginning of line
            'w' => blk: { // Ctrl+W: kill word backward
                const start = findWordStart(state.buffer.items, state.cursor);
                state.kill_ring.clearRetainingCapacity();
                state.kill_ring.appendSlice(state.buffer.items[start..state.cursor]) catch {};
                while (state.cursor > start) {
                    state.cursor -= 1;
                    _ = state.buffer.orderedRemove(state.cursor);
                }
                state.last_was_kill = true;
                break :blk .none;
            },
            'y' => .yank, // Ctrl+Y: yank from kill ring
            'l' => blk: { // Ctrl+L: clear screen
                const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
                stdout.writer().print("\x1b[2J\x1b[H", .{}) catch {};
                break :blk .none;
            },
            'r' => .search, // Ctrl+R: reverse search
            'c' => .cancel, // Ctrl+C: cancel
            'i', '\t' => .complete, // Tab: complete
            'j', 'm', '\r', '\n' => .execute, // Enter: execute
            else => .none,
        };
    }

    if (key.alt) {
        return switch (key.key) {
            'b' => .move_word_left, // Alt+B: backward word
            'f' => .move_word_right, // Alt+F: forward word
            'd' => .delete_word, // Alt+D: delete word forward
            else => .none,
        };
    }

    // Regular characters
    if (key.key >= 0x20 and key.key < 0x7f) {
        state.buffer.insert(state.cursor, key.key) catch return .none;
        state.cursor += 1;
        return .insert;
    }

    // Special keys
    return switch (key.key) {
        0x1b => .none, // ESC: do nothing in Emacs mode
        0x7f, 0x08 => blk: { // Backspace
            if (state.cursor > 0) {
                state.cursor -= 1;
                _ = state.buffer.orderedRemove(state.cursor);
            }
            break :blk .none;
        },
        else => .none,
    };
}

fn findWordStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos;

    // Skip backward over spaces
    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}

    // Skip backward over word characters
    while (i > 0 and !std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}

    return i;
}
