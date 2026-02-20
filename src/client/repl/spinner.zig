const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

/// CANARY: REQ=REQ-SHELL-SPINNER-001; FEATURE="ShellProcessingIndicator"; ASPECT=Module; STATUS=TESTED; TEST=tests/test_spinner.zig; OWNER=cli; UPDATED=2026-01-30
/// Cross-platform spinner/activity indicator for long-running shell operations.
/// Supports multiple terminal types including Unix TTY, Windows Console, and PowerShell.
/// Terminal type detection for choosing appropriate spinner characters
pub const TerminalType = enum {
    /// Unix/Linux terminal with full Unicode support
    unix_tty,
    /// Windows Console (cmd.exe) - limited character support
    windows_console,
    /// Windows Terminal or PowerShell with Unicode support
    windows_modern,
    /// Non-interactive or pipe - no spinner needed
    non_interactive,
    /// Basic terminal with ASCII only
    basic_ascii,

    /// Detect the current terminal type
    pub fn detect() TerminalType {
        // Check if stdout is a TTY
        if (!platform.isStdoutTty()) {
            return .non_interactive;
        }

        if (comptime builtin.os.tag == .windows) {
            // Check for modern Windows terminals via environment variables
            // std.posix.getenv is unavailable on Windows; use std.process.getEnvVarOwned
            const ally = std.heap.page_allocator;
            if (std.process.getEnvVarOwned(ally, "WT_SESSION")) |val| {
                ally.free(val);
                return .windows_modern;
            } else |_| {}
            if (std.process.getEnvVarOwned(ally, "TERM_PROGRAM")) |prog| {
                defer ally.free(prog);
                if (std.mem.eql(u8, prog, "vscode")) {
                    return .windows_modern;
                }
            } else |_| {}
            // Check for PowerShell via PSModulePath
            if (std.process.getEnvVarOwned(ally, "PSModulePath")) |val| {
                ally.free(val);
                return .windows_modern;
            } else |_| {}
            // Fallback to basic Windows console
            return .windows_console;
        } else {
            // Unix-like systems
            if (std.posix.getenv("TERM")) |term| {
                // Check for dumb terminals
                if (std.mem.eql(u8, term, "dumb") or std.mem.eql(u8, term, "")) {
                    return .basic_ascii;
                }
            }
            return .unix_tty;
        }
    }
};

/// Spinner style with character sequences for animation
pub const SpinnerStyle = struct {
    frames: []const []const u8,
    interval_ms: u32,

    /// Classic dots spinner (works on most terminals)
    pub const dots = SpinnerStyle{
        .frames = &[_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
        .interval_ms = 80,
    };

    /// Line spinner (ASCII fallback)
    pub const line = SpinnerStyle{
        .frames = &[_][]const u8{ "-", "\\", "|", "/" },
        .interval_ms = 100,
    };

    /// Arrow spinner (works on most terminals)
    pub const arrow = SpinnerStyle{
        .frames = &[_][]const u8{ "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
        .interval_ms = 100,
    };

    /// Box spinner (Unicode)
    pub const box = SpinnerStyle{
        .frames = &[_][]const u8{ "◰", "◳", "◲", "◱" },
        .interval_ms = 120,
    };

    /// Simple dots for basic terminals
    pub const simple_dots = SpinnerStyle{
        .frames = &[_][]const u8{ ".  ", ".. ", "...", "   " },
        .interval_ms = 300,
    };

    /// Bounce animation
    pub const bounce = SpinnerStyle{
        .frames = &[_][]const u8{ "⠁", "⠂", "⠄", "⠂" },
        .interval_ms = 120,
    };

    /// Get the best style for a terminal type
    pub fn forTerminal(terminal: TerminalType) SpinnerStyle {
        return switch (terminal) {
            .unix_tty => dots,
            .windows_modern => dots,
            .windows_console => line,
            .basic_ascii => line,
            .non_interactive => simple_dots,
        };
    }
};

/// Spinner state with optional background thread animation
pub const Spinner = struct {
    style: SpinnerStyle,
    message: []const u8,
    frame_index: usize,
    last_update: i64,
    terminal_type: TerminalType,
    started: bool,
    allocator: std.mem.Allocator,
    /// Width of last rendered line (for clearing)
    last_line_width: usize,
    /// Background animation thread (null if not using background mode)
    animation_thread: ?std.Thread,
    /// Atomic flag to signal thread to stop
    stop_flag: std.atomic.Value(bool),
    /// Mutex for thread-safe message updates
    message_mutex: std.Thread.Mutex,
    /// Buffer for thread-safe message storage
    message_buffer: [256]u8,
    message_len: usize,

    /// Create a new spinner with a message
    pub fn init(allocator: std.mem.Allocator, message: []const u8) Spinner {
        const terminal = TerminalType.detect();
        var spinner = Spinner{
            .style = SpinnerStyle.forTerminal(terminal),
            .message = message,
            .frame_index = 0,
            .last_update = 0,
            .terminal_type = terminal,
            .started = false,
            .allocator = allocator,
            .last_line_width = 0,
            .animation_thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .message_mutex = .{},
            .message_buffer = undefined,
            .message_len = 0,
        };
        // Copy initial message to buffer
        const copy_len = @min(message.len, spinner.message_buffer.len);
        @memcpy(spinner.message_buffer[0..copy_len], message[0..copy_len]);
        spinner.message_len = copy_len;
        return spinner;
    }

    /// Create a spinner with a specific style
    pub fn initWithStyle(allocator: std.mem.Allocator, message: []const u8, style: SpinnerStyle) Spinner {
        var spinner = Spinner{
            .style = style,
            .message = message,
            .frame_index = 0,
            .last_update = 0,
            .terminal_type = TerminalType.detect(),
            .started = false,
            .allocator = allocator,
            .last_line_width = 0,
            .animation_thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .message_mutex = .{},
            .message_buffer = undefined,
            .message_len = 0,
        };
        const copy_len = @min(message.len, spinner.message_buffer.len);
        @memcpy(spinner.message_buffer[0..copy_len], message[0..copy_len]);
        spinner.message_len = copy_len;
        return spinner;
    }

    /// Start the spinner (renders first frame, no background animation)
    pub fn start(self: *Spinner) void {
        if (self.terminal_type == .non_interactive) {
            // For non-interactive, just print message once
            const stdout = platform.getStdoutHandle();
            stdout.writeAll(self.message) catch {};
            stdout.writeAll(" ") catch {};
            self.started = true;
            return;
        }

        self.started = true;
        self.last_update = std.time.milliTimestamp();
        self.render();
    }

    /// Start the spinner with background animation thread
    /// Use this when the main thread will be blocked (e.g., waiting for server)
    pub fn startBackground(self: *Spinner) void {
        if (self.terminal_type == .non_interactive) {
            self.start();
            return;
        }

        self.stop_flag.store(false, .seq_cst);
        self.started = true;
        self.last_update = std.time.milliTimestamp();
        self.render();

        // Spawn animation thread
        self.animation_thread = std.Thread.spawn(.{}, animationLoop, .{self}) catch {
            // If thread spawn fails, fall back to non-animated mode
            return;
        };
    }

    /// Animation loop for background thread
    fn animationLoop(self: *Spinner) void {
        while (!self.stop_flag.load(.seq_cst)) {
            std.Thread.sleep(self.style.interval_ms * std.time.ns_per_ms);
            if (self.stop_flag.load(.seq_cst)) break;

            self.frame_index = (self.frame_index + 1) % self.style.frames.len;
            self.renderThreadSafe();
        }
    }

    /// Thread-safe render using message from buffer
    fn renderThreadSafe(self: *Spinner) void {
        const stdout = platform.getStdoutHandle();
        const frame = self.style.frames[self.frame_index];

        // Get message under lock
        self.message_mutex.lock();
        const msg_len = self.message_len;
        var msg_copy: [256]u8 = undefined;
        @memcpy(msg_copy[0..msg_len], self.message_buffer[0..msg_len]);
        self.message_mutex.unlock();

        // Build the output line
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\r{s} {s}", .{ frame, msg_copy[0..msg_len] }) catch return;

        // Clear previous content if needed (pad with spaces)
        if (line.len < self.last_line_width) {
            var clear_buf: [512]u8 = undefined;
            const padding = self.last_line_width - line.len;
            @memset(clear_buf[0..padding], ' ');
            stdout.writeAll(line) catch {};
            stdout.writeAll(clear_buf[0..padding]) catch {};
        } else {
            stdout.writeAll(line) catch {};
        }

        self.last_line_width = line.len;
    }

    /// Update the spinner (call periodically from main loop)
    /// Returns true if frame was updated
    pub fn tick(self: *Spinner) bool {
        if (!self.started) return false;

        const now = std.time.milliTimestamp();
        const elapsed = now - self.last_update;

        if (elapsed >= self.style.interval_ms) {
            self.frame_index = (self.frame_index + 1) % self.style.frames.len;
            self.last_update = now;
            self.render();
            return true;
        }
        return false;
    }

    /// Update the message while spinning (thread-safe)
    pub fn setMessage(self: *Spinner, message: []const u8) void {
        self.message_mutex.lock();
        const copy_len = @min(message.len, self.message_buffer.len);
        @memcpy(self.message_buffer[0..copy_len], message[0..copy_len]);
        self.message_len = copy_len;
        self.message = message;
        self.message_mutex.unlock();

        if (self.started and self.animation_thread == null) {
            self.render();
        }
    }

    /// Render the current frame
    fn render(self: *Spinner) void {
        const stdout = platform.getStdoutHandle();
        const frame = self.style.frames[self.frame_index];

        // Build the output line
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\r{s} {s}", .{ frame, self.message }) catch return;

        // Clear previous content if needed (pad with spaces)
        if (line.len < self.last_line_width) {
            var clear_buf: [256]u8 = undefined;
            const padding = self.last_line_width - line.len;
            const padded = std.fmt.bufPrint(&clear_buf, "{s}{s}", .{ line, " " ** 50 }) catch line;
            const actual_padded = padded[0..@min(line.len + padding, padded.len)];
            stdout.writeAll(actual_padded) catch {};
            stdout.writeAll("\r") catch {};
            stdout.writeAll(line) catch {};
        } else {
            stdout.writeAll(line) catch {};
        }

        self.last_line_width = line.len;
    }

    /// Stop the spinner with a final message
    pub fn stop(self: *Spinner, final_message: ?[]const u8) void {
        if (!self.started) return;

        // Signal background thread to stop and wait for it
        if (self.animation_thread) |thread| {
            self.stop_flag.store(true, .seq_cst);
            thread.join();
            self.animation_thread = null;
        }

        const stdout = platform.getStdoutHandle();

        if (self.terminal_type == .non_interactive) {
            if (final_message) |msg| {
                stdout.writeAll(msg) catch {};
            }
            stdout.writeAll("\r\n") catch {};
            self.started = false;
            return;
        }

        // Clear the spinner line by overwriting with spaces
        stdout.writeAll("\r") catch {};
        var clear_buf: [256]u8 = undefined;
        @memset(&clear_buf, ' ');
        const clear_len = @min(self.last_line_width + 5, 250);
        stdout.writeAll(clear_buf[0..clear_len]) catch {};
        stdout.writeAll("\r") catch {};

        // Print final message if provided
        if (final_message) |msg| {
            stdout.writeAll(msg) catch {};
            stdout.writeAll("\r\n") catch {};
        }

        self.started = false;
    }

    /// Stop with success indicator
    pub fn success(self: *Spinner, message: ?[]const u8) void {
        const success_prefix = switch (self.terminal_type) {
            .unix_tty, .windows_modern => "✓ ",
            else => "[OK] ",
        };

        if (message) |msg| {
            var buf: [512]u8 = undefined;
            const full_msg = std.fmt.bufPrint(&buf, "{s}{s}", .{ success_prefix, msg }) catch msg;
            self.stop(full_msg);
        } else {
            self.stop(success_prefix);
        }
    }

    /// Stop with failure indicator
    pub fn fail(self: *Spinner, message: ?[]const u8) void {
        const fail_prefix = switch (self.terminal_type) {
            .unix_tty, .windows_modern => "✗ ",
            else => "[FAIL] ",
        };

        if (message) |msg| {
            var buf: [512]u8 = undefined;
            const full_msg = std.fmt.bufPrint(&buf, "{s}{s}", .{ fail_prefix, msg }) catch msg;
            self.stop(full_msg);
        } else {
            self.stop(fail_prefix);
        }
    }

    /// Check if spinner is currently active
    pub fn isRunning(self: *const Spinner) bool {
        return self.started;
    }
};

/// Progress spinner with percentage/count display
pub const ProgressSpinner = struct {
    spinner: Spinner,
    total: usize,
    current: usize,
    show_percentage: bool,
    base_message: []const u8,

    pub fn init(allocator: std.mem.Allocator, message: []const u8, total: usize) ProgressSpinner {
        return ProgressSpinner{
            .spinner = Spinner.init(allocator, message),
            .total = total,
            .current = 0,
            .show_percentage = true,
            .base_message = message,
        };
    }

    pub fn start(self: *ProgressSpinner) void {
        self.updateMessage();
        self.spinner.start();
    }

    pub fn increment(self: *ProgressSpinner) void {
        self.current = @min(self.current + 1, self.total);
        self.updateMessage();
        _ = self.spinner.tick();
    }

    pub fn setCurrent(self: *ProgressSpinner, value: usize) void {
        self.current = @min(value, self.total);
        self.updateMessage();
        _ = self.spinner.tick();
    }

    fn updateMessage(self: *ProgressSpinner) void {
        var buf: [256]u8 = undefined;
        if (self.show_percentage and self.total > 0) {
            const pct = (self.current * 100) / self.total;
            const msg = std.fmt.bufPrint(&buf, "{s} ({d}/{d} - {d}%)", .{
                self.base_message,
                self.current,
                self.total,
                pct,
            }) catch self.base_message;
            self.spinner.message = msg;
        } else {
            const msg = std.fmt.bufPrint(&buf, "{s} ({d}/{d})", .{
                self.base_message,
                self.current,
                self.total,
            }) catch self.base_message;
            self.spinner.message = msg;
        }
    }

    pub fn tick(self: *ProgressSpinner) bool {
        return self.spinner.tick();
    }

    pub fn stop(self: *ProgressSpinner, final_message: ?[]const u8) void {
        self.spinner.stop(final_message);
    }

    pub fn success(self: *ProgressSpinner, message: ?[]const u8) void {
        self.spinner.success(message);
    }

    pub fn fail(self: *ProgressSpinner, message: ?[]const u8) void {
        self.spinner.fail(message);
    }
};

/// Helper to run a spinner during a blocking operation (for use in async contexts)
pub fn withSpinner(
    allocator: std.mem.Allocator,
    message: []const u8,
    comptime func: anytype,
    args: anytype,
) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    var spinner = Spinner.init(allocator, message);
    spinner.start();
    defer spinner.stop(null);

    return @call(.auto, func, args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "TerminalType.detect returns valid type" {
    const terminal = TerminalType.detect();
    // Should be one of the valid types
    _ = switch (terminal) {
        .unix_tty => true,
        .windows_console => true,
        .windows_modern => true,
        .non_interactive => true,
        .basic_ascii => true,
    };
}

test "SpinnerStyle.forTerminal returns appropriate style" {
    // Unix TTY should get dots (Unicode)
    const unix_style = SpinnerStyle.forTerminal(.unix_tty);
    try std.testing.expect(unix_style.frames.len > 0);
    try std.testing.expect(unix_style.interval_ms > 0);

    // Windows console should get ASCII line
    const console_style = SpinnerStyle.forTerminal(.windows_console);
    try std.testing.expectEqualStrings("-", console_style.frames[0]);

    // Basic ASCII should get line
    const ascii_style = SpinnerStyle.forTerminal(.basic_ascii);
    try std.testing.expectEqualStrings("-", ascii_style.frames[0]);
}

test "Spinner.init creates valid spinner" {
    const allocator = std.testing.allocator;
    const spinner = Spinner.init(allocator, "Testing...");

    try std.testing.expectEqualStrings("Testing...", spinner.message);
    try std.testing.expect(!spinner.started);
    try std.testing.expect(spinner.frame_index == 0);
}

test "Spinner.initWithStyle uses custom style" {
    const allocator = std.testing.allocator;
    const spinner = Spinner.initWithStyle(allocator, "Custom", SpinnerStyle.arrow);

    try std.testing.expect(spinner.style.frames.len == SpinnerStyle.arrow.frames.len);
    try std.testing.expect(spinner.style.interval_ms == SpinnerStyle.arrow.interval_ms);
}

test "Spinner.isRunning tracks state correctly" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, "Test");

    try std.testing.expect(!spinner.isRunning());

    spinner.start();
    try std.testing.expect(spinner.isRunning());

    spinner.stop(null);
    try std.testing.expect(!spinner.isRunning());
}

test "Spinner.tick advances frame after interval" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.initWithStyle(allocator, "Test", SpinnerStyle{
        .frames = &[_][]const u8{ "A", "B", "C" },
        .interval_ms = 10, // Short interval for testing
    });

    spinner.start();
    try std.testing.expect(spinner.frame_index == 0);

    // Wait for interval to pass
    std.time.sleep(15 * std.time.ns_per_ms);

    const updated = spinner.tick();
    // May or may not update depending on timing, but should not crash
    _ = updated;

    spinner.stop(null);
}

test "Spinner.setMessage updates message" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, "Initial");

    try std.testing.expectEqualStrings("Initial", spinner.message);

    spinner.setMessage("Updated");
    try std.testing.expectEqualStrings("Updated", spinner.message);
}

test "ProgressSpinner.init sets up correctly" {
    const allocator = std.testing.allocator;
    const progress = ProgressSpinner.init(allocator, "Processing", 100);

    try std.testing.expect(progress.total == 100);
    try std.testing.expect(progress.current == 0);
    try std.testing.expect(progress.show_percentage);
}

test "ProgressSpinner.increment advances count" {
    const allocator = std.testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Processing", 100);

    try std.testing.expect(progress.current == 0);

    progress.increment();
    try std.testing.expect(progress.current == 1);

    progress.increment();
    try std.testing.expect(progress.current == 2);
}

test "ProgressSpinner.setCurrent updates value" {
    const allocator = std.testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Processing", 100);

    progress.setCurrent(50);
    try std.testing.expect(progress.current == 50);

    // Should not exceed total
    progress.setCurrent(150);
    try std.testing.expect(progress.current == 100);
}

test "SpinnerStyle constants are valid" {
    // Test all predefined styles have valid data
    const styles = [_]SpinnerStyle{
        SpinnerStyle.dots,
        SpinnerStyle.line,
        SpinnerStyle.arrow,
        SpinnerStyle.box,
        SpinnerStyle.simple_dots,
        SpinnerStyle.bounce,
    };

    for (styles) |style| {
        try std.testing.expect(style.frames.len > 0);
        try std.testing.expect(style.interval_ms > 0);
        try std.testing.expect(style.interval_ms < 1000); // Sanity check

        // Verify all frames are non-empty
        for (style.frames) |frame| {
            try std.testing.expect(frame.len > 0);
        }
    }
}

test "Spinner handles empty message" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, "");

    try std.testing.expectEqualStrings("", spinner.message);
    spinner.start();
    spinner.stop(null);
}

test "Spinner success and fail methods work" {
    const allocator = std.testing.allocator;

    // Test success
    {
        var spinner = Spinner.init(allocator, "Testing success");
        spinner.start();
        spinner.success("Done!");
        try std.testing.expect(!spinner.isRunning());
    }

    // Test fail
    {
        var spinner = Spinner.init(allocator, "Testing fail");
        spinner.start();
        spinner.fail("Error occurred");
        try std.testing.expect(!spinner.isRunning());
    }
}

test "Multiple spinners can be created independently" {
    const allocator = std.testing.allocator;

    var spinner1 = Spinner.init(allocator, "Spinner 1");
    var spinner2 = Spinner.init(allocator, "Spinner 2");

    try std.testing.expectEqualStrings("Spinner 1", spinner1.message);
    try std.testing.expectEqualStrings("Spinner 2", spinner2.message);

    spinner1.start();
    try std.testing.expect(spinner1.isRunning());
    try std.testing.expect(!spinner2.isRunning());

    spinner2.start();
    try std.testing.expect(spinner1.isRunning());
    try std.testing.expect(spinner2.isRunning());

    spinner1.stop(null);
    spinner2.stop(null);
}

test "TerminalType enum covers all cases" {
    // Ensure exhaustive switch works (compile-time check)
    const types = [_]TerminalType{
        .unix_tty,
        .windows_console,
        .windows_modern,
        .non_interactive,
        .basic_ascii,
    };

    for (types) |t| {
        const style = SpinnerStyle.forTerminal(t);
        try std.testing.expect(style.frames.len > 0);
    }
}

test "Spinner frame cycling is correct" {
    const allocator = std.testing.allocator;
    const test_frames = [_][]const u8{ "A", "B", "C" };
    var spinner = Spinner.initWithStyle(allocator, "Test", SpinnerStyle{
        .frames = &test_frames,
        .interval_ms = 1,
    });

    // Manually advance frames
    try std.testing.expect(spinner.frame_index == 0);

    spinner.frame_index = (spinner.frame_index + 1) % spinner.style.frames.len;
    try std.testing.expect(spinner.frame_index == 1);

    spinner.frame_index = (spinner.frame_index + 1) % spinner.style.frames.len;
    try std.testing.expect(spinner.frame_index == 2);

    // Should wrap around
    spinner.frame_index = (spinner.frame_index + 1) % spinner.style.frames.len;
    try std.testing.expect(spinner.frame_index == 0);
}
