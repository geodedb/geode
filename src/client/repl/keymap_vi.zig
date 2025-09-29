const std = @import("std");
const repl_loop = @import("repl_loop.zig");

pub const ViMode = enum { normal, insert, visual };

pub fn handleKey(state: anytype, key: repl_loop.KeyEvent) repl_loop.KeyAction {
    switch (state.vi_mode) {
        .normal => return handleNormalMode(state, key),
        .insert => return handleInsertMode(state, key),
        .visual => return handleNormalMode(state, key), // Simplified: treat as normal
    }
}

fn handleNormalMode(state: anytype, key: repl_loop.KeyEvent) repl_loop.KeyAction {
    if (key.ctrl) {
        return switch (key.key) {
            'c' => .cancel,
            'd' => if (state.buffer.items.len == 0) .quit else .none,
            else => .none,
        };
    }

    // Vi normal mode commands
    switch (key.key) {
        // Mode changes
        'i' => {
            state.vi_mode = .insert;
            return .vi_insert_mode;
        },
        'a' => {
            state.vi_mode = .insert;
            if (state.cursor < state.buffer.items.len) state.cursor += 1;
            return .vi_insert_mode;
        },
        'A' => {
            state.vi_mode = .insert;
            state.cursor = state.buffer.items.len;
            return .vi_insert_mode;
        },
        'o' => {
            state.vi_mode = .insert;
            state.cursor = state.buffer.items.len;
            state.buffer.append(state.allocator, '\n') catch {};
            state.cursor += 1;
            return .vi_insert_mode;
        },
        'O' => {
            state.vi_mode = .insert;
            state.buffer.insert(state.allocator, 0, '\n') catch {};
            state.cursor = 0;
            return .vi_insert_mode;
        },

        // Movement
        'h' => return .move_left,
        'l' => return .move_right,
        'j' => return .history_next,
        'k' => return .history_prev,
        '0' => return .move_bol,
        '$' => return .move_eol,
        'w' => return .move_word_right,
        'b' => return .move_word_left,
        'e' => {
            // Move to end of word
            var i = state.cursor;
            if (i < state.buffer.items.len and !std.ascii.isWhitespace(state.buffer.items[i])) {
                while (i < state.buffer.items.len - 1 and !std.ascii.isWhitespace(state.buffer.items[i + 1])) : (i += 1) {}
            }
            state.cursor = i;
            return .none;
        },

        // Deletion
        'x' => {
            if (state.cursor < state.buffer.items.len) {
                _ = state.buffer.orderedRemove(state.cursor);
            }
            return .none;
        },
        'd' => {
            // Wait for motion (simplified: dd deletes line)
            state.pending_operator = 'd';
            return .none;
        },
        'D' => return .delete_to_eol,

        // Other
        'u' => return .undo,
        '/' => {
            // Start search
            state.vi_mode = .insert;
            return .search;
        },
        'G' => {
            // Go to end
            state.cursor = state.buffer.items.len;
            return .none;
        },
        'g' => {
            // gg goes to beginning (simplified)
            state.cursor = 0;
            return .none;
        },

        else => {},
    }

    // Handle pending operators
    if (state.pending_operator) |op| {
        if (op == 'd') {
            switch (key.key) {
                'd' => {
                    // dd: delete line
                    state.kill_ring.clearRetainingCapacity();
                    state.kill_ring.appendSlice(state.allocator, state.buffer.items) catch {};
                    state.buffer.clearRetainingCapacity();
                    state.cursor = 0;
                    state.last_was_kill = true;
                    state.pending_operator = null;
                    return .none;
                },
                'w' => {
                    // dw: delete word
                    const end = findWordEnd(state.buffer.items, state.cursor);
                    state.kill_ring.clearRetainingCapacity();
                    state.kill_ring.appendSlice(state.allocator, state.buffer.items[state.cursor..end]) catch {};
                    while (state.cursor < end) {
                        _ = state.buffer.orderedRemove(state.cursor);
                    }
                    state.last_was_kill = true;
                    state.pending_operator = null;
                    return .none;
                },
                'b' => {
                    // db: delete word backward
                    const start = findWordStart(state.buffer.items, state.cursor);
                    state.kill_ring.clearRetainingCapacity();
                    state.kill_ring.appendSlice(state.allocator, state.buffer.items[start..state.cursor]) catch {};
                    while (state.cursor > start) {
                        state.cursor -= 1;
                        _ = state.buffer.orderedRemove(state.cursor);
                    }
                    state.last_was_kill = true;
                    state.pending_operator = null;
                    return .none;
                },
                'e' => {
                    // de: delete to end of word
                    var end = state.cursor;
                    if (end < state.buffer.items.len and !std.ascii.isWhitespace(state.buffer.items[end])) {
                        while (end < state.buffer.items.len - 1 and !std.ascii.isWhitespace(state.buffer.items[end + 1])) : (end += 1) {}
                        end += 1;
                    }
                    state.kill_ring.clearRetainingCapacity();
                    state.kill_ring.appendSlice(state.allocator, state.buffer.items[state.cursor..end]) catch {};
                    while (state.cursor < end) {
                        _ = state.buffer.orderedRemove(state.cursor);
                    }
                    state.last_was_kill = true;
                    state.pending_operator = null;
                    return .none;
                },
                else => {
                    state.pending_operator = null;
                },
            }
        }
    }

    return .none;
}

fn handleInsertMode(state: anytype, key: repl_loop.KeyEvent) repl_loop.KeyAction {
    // ESC returns to normal mode
    if (key.key == 0x1b) {
        state.vi_mode = .normal;
        if (state.cursor > 0) state.cursor -= 1;
        return .vi_normal_mode;
    }

    // Ctrl keys work in insert mode
    if (key.ctrl) {
        return switch (key.key) {
            'c' => .cancel,
            'd' => if (state.buffer.items.len == 0) .quit else .none,
            'w' => blk: {
                // Delete word backward
                const start = findWordStart(state.buffer.items, state.cursor);
                while (state.cursor > start) {
                    state.cursor -= 1;
                    _ = state.buffer.orderedRemove(state.cursor);
                }
                break :blk .none;
            },
            'u' => blk: {
                // Delete to beginning of line
                while (state.cursor > 0) {
                    state.cursor -= 1;
                    _ = state.buffer.orderedRemove(state.cursor);
                }
                break :blk .none;
            },
            'i', '\t' => .complete,
            'j', 'm', '\r', '\n' => .execute,
            else => .none,
        };
    }

    // Regular characters
    if (key.key >= 0x20 and key.key < 0x7f) {
        state.buffer.insert(state.allocator, state.cursor, key.key) catch return .none;
        state.cursor += 1;
        return .insert;
    }

    // Backspace
    if (key.key == 0x7f or key.key == 0x08) {
        if (state.cursor > 0) {
            state.cursor -= 1;
            _ = state.buffer.orderedRemove(state.cursor);
        }
        return .none;
    }

    return .none;
}

fn findWordStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos;

    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}
    while (i > 0 and !std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}

    return i;
}

fn findWordEnd(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var i = pos;

    while (i < text.len and !std.ascii.isWhitespace(text[i])) : (i += 1) {}
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}

    return i;
}
