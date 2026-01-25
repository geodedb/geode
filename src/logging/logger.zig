const std = @import("std");
const slog = @import("slog");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-002; FEATURE="Centralized Structured Logging"; ASPECT=Infrastructure; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// Centralized logging infrastructure using external slog library
// Provides global logger instance, scoped loggers, and runtime configuration

pub const Attr = slog.Attr;
pub const Level = slog.Level;
pub const Logger = slog.Logger;
pub const Handler = slog.Handler;
pub const Clock = slog.Clock;

/// Get stderr writer as AnyWriter compatible with Zig 0.15.1+
fn getStderrWriter() std.io.AnyWriter {
    return std.fs.File.stderr().deprecatedWriter().any();
}

/// Output format for log messages
pub const Format = enum {
    text,
    json,
};

/// Global logger state
var g_logger: ?Logger = null;
var g_text_ctx: ?slog.text.Context = null;
var g_json_ctx: ?slog.json.Context = null;
var g_initialized: bool = false;
var g_mutex: std.Thread.Mutex = .{};

/// Union to hold either text or json handler context (unused, kept for reference)
const HandlerContext = union {
    text: slog.text.Context,
    json: slog.json.Context,
};

/// Initialize the global logger with the specified configuration.
/// Must be called before any logging calls.
/// Thread-safe: can be called multiple times, only first call takes effect.
pub fn init(config: Config) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    if (g_initialized) return;

    const writer = if (config.writer) |w| w else getStderrWriter();
    const clock = Clock.system();

    const handler = switch (config.format) {
        .text => blk: {
            g_text_ctx = slog.text.Context.init(writer, config.level, clock);
            break :blk slog.text.init(&g_text_ctx.?);
        },
        .json => blk: {
            g_json_ctx = slog.json.Context.init(writer, config.level, clock);
            break :blk slog.json.init(&g_json_ctx.?);
        },
    };

    g_logger = Logger.init(handler, config.level, clock).named("geode");
    g_initialized = true;
}

/// Configuration for logger initialization
pub const Config = struct {
    level: Level = .info,
    format: Format = .text,
    writer: ?std.io.AnyWriter = null,
};

/// Get the global logger instance.
/// If not initialized, returns a default logger writing to stderr.
pub fn getLogger() *const Logger {
    if (!g_initialized) {
        init(.{});
    }
    return &g_logger.?;
}

/// Get a scoped logger with the given name.
/// Creates a child logger with hierarchical naming (e.g., "geode.storage").
pub fn scoped(comptime scope: []const u8) ScopedLogger {
    return ScopedLogger{ .scope = scope };
}

/// Set the global log level at runtime.
/// Thread-safe.
pub fn setLevel(level: Level) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    if (g_logger) |*logger| {
        logger.setLevel(level);
    }
}

/// Get the current log level.
pub fn getLevel() Level {
    if (g_logger) |logger| {
        return logger.level;
    }
    return .info;
}

/// Parse a log level from a string (case-insensitive).
/// Returns null if the string is not a valid level.
pub fn parseLevel(s: []const u8) ?Level {
    return Level.fromString(s);
}

/// Flush pending log messages.
pub fn flush() void {
    if (g_logger) |logger| {
        logger.flush(5000) catch {};
    }
}

/// Reset the logger (primarily for testing).
pub fn reset() void {
    g_mutex.lock();
    defer g_mutex.unlock();

    g_logger = null;
    g_initialized = false;
}

/// Scoped logger wrapper that provides convenience methods.
/// Use scoped("subsystem") to get a logger for a specific component.
pub const ScopedLogger = struct {
    scope: []const u8,

    pub fn trace(self: ScopedLogger, msg: []const u8, attrs: []const Attr) void {
        self.log(.trace, msg, attrs);
    }

    pub fn debug(self: ScopedLogger, msg: []const u8, attrs: []const Attr) void {
        self.log(.debug, msg, attrs);
    }

    pub fn info(self: ScopedLogger, msg: []const u8, attrs: []const Attr) void {
        self.log(.info, msg, attrs);
    }

    pub fn warn(self: ScopedLogger, msg: []const u8, attrs: []const Attr) void {
        self.log(.warn, msg, attrs);
    }

    pub fn err(self: ScopedLogger, msg: []const u8, attrs: []const Attr) void {
        self.log(.@"error", msg, attrs);
    }

    pub fn fatal(self: ScopedLogger, msg: []const u8, attrs: []const Attr) void {
        self.log(.fatal, msg, attrs);
    }

    fn log(self: ScopedLogger, level: Level, msg: []const u8, attrs: []const Attr) void {
        const logger = getLogger();
        const scoped_logger = logger.named(self.scope);
        scoped_logger.log(level, msg, attrs) catch {};
    }
};

// Convenience attribute constructors re-exported from slog
pub const attr = struct {
    pub fn string(key: []const u8, val: []const u8) Attr {
        return Attr.string(key, val);
    }

    pub fn int(key: []const u8, val: i64) Attr {
        return Attr.int(key, val);
    }

    pub fn uint(key: []const u8, val: u64) Attr {
        return Attr.uint(key, val);
    }

    pub fn float(key: []const u8, val: f64) Attr {
        return Attr.float(key, val);
    }

    pub fn boolean(key: []const u8, val: bool) Attr {
        return Attr.boolean(key, val);
    }

    pub fn err(key: []const u8, val: anyerror) Attr {
        return Attr.err(key, val);
    }

    pub fn secret(key: []const u8, val: []const u8) Attr {
        return Attr.secret(key, val);
    }

    pub fn duration(key: []const u8, nanos: i64) Attr {
        return Attr.duration(key, nanos);
    }

    pub fn bytes(key: []const u8, val: []const u8) Attr {
        return Attr.bytes(key, val);
    }
};

// Tests
test "logger initialization" {
    reset();
    defer reset();

    init(.{ .level = .debug, .format = .text });
    const logger = getLogger();
    try std.testing.expect(logger.level == .debug);
}

test "scoped logger" {
    reset();
    defer reset();

    init(.{ .level = .info, .format = .text });
    const log = scoped("test");
    log.info("test message", &.{
        attr.string("key", "value"),
        attr.int("count", 42),
    });
}

test "level parsing" {
    try std.testing.expect(parseLevel("info").? == .info);
    try std.testing.expect(parseLevel("DEBUG").? == .debug);
    try std.testing.expect(parseLevel("ERROR").? == .@"error");
    try std.testing.expect(parseLevel("invalid") == null);
}

test "runtime level change" {
    reset();
    defer reset();

    init(.{ .level = .info });
    try std.testing.expect(getLevel() == .info);

    setLevel(.debug);
    try std.testing.expect(getLevel() == .debug);
}
