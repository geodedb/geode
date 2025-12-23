const std = @import("std");
const execution = @import("execution.zig");

/// Transaction session persistence for CLI mode
/// Stores transaction state in a file to persist across CLI invocations
/// Get session file path based on GEODE_DATA_DIR environment variable
fn getSessionFilePath(allocator: std.mem.Allocator) ![]const u8 {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    if (env_map.get("GEODE_DATA_DIR")) |data_dir| {
        // Use data-dir specific transaction session file
        return try std.fmt.allocPrint(allocator, "{s}/geode_transaction_session.txt", .{data_dir});
    }

    // Fall back to global tmp file
    return try allocator.dupe(u8, "/tmp/geode_transaction_session.txt");
}

pub const TransactionSession = struct {
    state: execution.TransactionState,
    session_id: []const u8,

    pub fn init(allocator: std.mem.Allocator) !TransactionSession {
        // Generate a simple session ID from timestamp
        const timestamp = std.time.timestamp();
        const session_id = try std.fmt.allocPrint(allocator, "txn_{d}", .{timestamp});

        return TransactionSession{
            .state = .None,
            .session_id = session_id,
        };
    }

    pub fn deinit(self: *TransactionSession, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
    }
};

/// Load active transaction session from disk
pub fn loadSession(allocator: std.mem.Allocator) !?TransactionSession {
    const session_file = try getSessionFilePath(allocator);
    defer allocator.free(session_file);

    // Use cwd().openFile to support both relative and absolute paths
    const file = std.fs.cwd().openFile(session_file, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    // Parse the session file: "state|session_id"
    const separator_pos = std.mem.indexOf(u8, content, "|") orelse return null;
    const state_str = content[0..separator_pos];
    const session_id = content[separator_pos + 1 ..];

    const state: execution.TransactionState = if (std.mem.eql(u8, state_str, "Active"))
        .Active
    else if (std.mem.eql(u8, state_str, "Committed"))
        .Committed
    else if (std.mem.eql(u8, state_str, "RolledBack"))
        .RolledBack
    else
        .None;

    return TransactionSession{
        .state = state,
        .session_id = try allocator.dupe(u8, session_id),
    };
}

/// Save transaction session to disk
pub fn saveSession(allocator: std.mem.Allocator, session: TransactionSession) !void {
    const session_file = try getSessionFilePath(allocator);
    defer allocator.free(session_file);

    // Use cwd().createFile to support both relative and absolute paths
    const file = try std.fs.cwd().createFile(session_file, .{});
    defer file.close();

    const state_str = switch (session.state) {
        .None => "None",
        .Active => "Active",
        .Committed => "Committed",
        .RolledBack => "RolledBack",
    };

    // Write state
    _ = try file.write(state_str);
    _ = try file.write("|");
    _ = try file.write(session.session_id);
}

/// Clear transaction session from disk
pub fn clearSession(allocator: std.mem.Allocator) !void {
    const session_file = try getSessionFilePath(allocator);
    defer allocator.free(session_file);

    // Use cwd().deleteFile to support both relative and absolute paths
    std.fs.cwd().deleteFile(session_file) catch |err| {
        if (err == error.FileNotFound) {
            return;
        }
        return err;
    };
}

/// Check if there's an active transaction session
pub fn hasActiveSession(allocator: std.mem.Allocator) bool {
    const session_file = getSessionFilePath(allocator) catch return false;
    defer allocator.free(session_file);

    // Use cwd().openFile to support both relative and absolute paths
    const file = std.fs.cwd().openFile(session_file, .{}) catch {
        return false;
    };
    defer file.close();
    return true;
}
