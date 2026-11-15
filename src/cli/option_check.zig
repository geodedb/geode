//! SONNY-6560: the options each geode command reads, so an option it does
//! not know, or a value option given without its value, is refused (exit 2)
//! before the command runs.
//!
//! These commands' argument loops skipped an argument they did not
//! recognise, and most read a value option only `and i + 1 < argv.len`, so
//! `geode user list --data-dri /srv/geode` or a trailing `--user` ran the
//! command on the defaults. `geode serve` refuses such an argument since
//! SONNY-6442; `geode shell`, `lsp`, `storage`, `backup create`,
//! `backup cleanup` and `restore` refuse one in their own loops and are not
//! listed here, nor is `geode query`, whose loop refuses one itself, nor
//! `geode mtls`, which refuses every subcommand as unsupported (SONNY-6458)
//! whatever its options.
//!
//! Each entry lists exactly the options its handler reads (a handler that
//! scans argv for an option, such as --data-dir, reads it wherever it is).
//! `-h`/`--help` is accepted everywhere. A positional argument is left to
//! the handler.

const std = @import("std");

// CANARY: REQ=REQ-SONNY-6560-UNKNOWN-OPTION; FEATURE="CliOptions"; ASPECT=UnknownOptionRefused; STATUS=TESTED; TEST=tests/test_sonny6560_cli_unsupported_options.zig; OWNER=cli; UPDATED=2026-11-14

pub const Arity = enum {
    /// No value.
    flag,
    /// Exactly one value: the next argument, whatever it holds.
    value,
    /// A value when the next argument does not start with '-'.
    optional_value,
};

pub const Option = struct {
    name: []const u8,
    arity: Arity = .flag,
};

pub const Sub = struct {
    names: []const []const u8,
    options: []const Option = &.{},
};

pub const Command = struct {
    names: []const []const u8,
    /// Read with every subcommand (or by a command without subcommands).
    options: []const Option = &.{},
    /// When not empty, the first positional argument names the subcommand;
    /// a subcommand not listed here is left to the handler (which reports
    /// it), and its options are not checked.
    subs: []const Sub = &.{},
};

pub const Verdict = union(enum) {
    ok,
    unknown_option: []const u8,
    missing_value: []const u8,
};

fn v(name: []const u8) Option {
    return .{ .name = name, .arity = .value };
}

fn f(name: []const u8) Option {
    return .{ .name = name };
}

const data_dir = v("--data-dir");
const force = f("--force");

/// `geode tenant` hands these to `geode query` (tenant_cli.passthroughFlagWidth).
const tenant_passthrough = [_]Option{
    f("--insecure-tls-skip-verify"), f("--insecure"),                   f("--grpc"),    f("--batch"),       f("--no-saved-session"),
    v("--dsn"),                      v("--server"),                     v("--user"),    v("--username"),    v("-U"),
    v("--password"),                 v("--pass"),                       v("-P"),        v("--token"),       v("--format"),
    v("--graph"),                    v("-g"),                           v("--ca-cert"), v("--client-cert"), v("--client-key"),
    v("--timeout"),                  v("--page-size"),                  v("--retry"),   v("--log-level"),   v("--role"),
    v("--forward-principal"),        v("--forward-principal-envelope"),
};

const login_options = [_]Option{
    v("--server"),        v("-U"),             v("--user"),    v("--username"), v("--password"),                 v("--pass"), v("-P"),
    v("--password-file"), f("--save-session"), v("--ca-cert"), f("--insecure"), f("--insecure-tls-skip-verify"),
};

pub const commands = [_]Command{
    .{
        .names = &.{"user"},
        .options = &.{data_dir},
        .subs = &.{
            .{ .names = &.{"create"}, .options = &.{ force, v("--password"), f("--generate-password"), v("--role") } },
            .{ .names = &.{"import"}, .options = &.{ force, v("--hash"), v("--email"), v("--role"), v("--algorithm") } },
            .{ .names = &.{ "list", "show", "info", "permissions" } },
            .{ .names = &.{"delete"}, .options = &.{ force, f("--yes") } },
            .{ .names = &.{"update"}, .options = &.{ force, v("--email"), v("--password"), v("--role") } },
            .{ .names = &.{ "assign-role", "disable", "enable" }, .options = &.{force} },
            .{ .names = &.{"mfa-setup"}, .options = &.{ force, f("--show-uri"), f("--show-recovery"), f("--regenerate") } },
            .{ .names = &.{"mfa-verify"}, .options = &.{v("--token")} },
            .{ .names = &.{"mfa"}, .options = &.{ force, v("--code") } },
            .{ .names = &.{"change-password"}, .options = &.{ force, v("--old-password"), v("--new-password"), f("--generate-password") } },
            .{ .names = &.{"reset-password"}, .options = &.{ force, v("--new-password"), f("--generate-password") } },
        },
    },
    .{
        .names = &.{"role"},
        .options = &.{data_dir},
        .subs = &.{.{ .names = &.{ "create", "list", "delete", "show" } }},
    },
    .{
        .names = &.{"policy"},
        .options = &.{data_dir},
        .subs = &.{
            .{ .names = &.{"create"}, .options = &.{ v("--table"), v("--condition") } },
            .{ .names = &.{ "list", "show", "delete" } },
        },
    },
    .{ .names = &.{"grant"}, .options = &.{ data_dir, v("--to"), v("--resource") } },
    .{ .names = &.{"revoke"}, .options = &.{ data_dir, v("--from"), v("--resource") } },
    .{
        .names = &.{"auth"},
        .subs = &.{
            .{ .names = &.{"login"}, .options = &login_options },
            // SONNY-6554: the handler refuses --token with the reason.
            .{ .names = &.{"logout"}, .options = &.{v("--token")} },
            .{ .names = &.{"token"} },
            .{ .names = &.{"validate"}, .options = &.{v("--token")} },
            .{ .names = &.{ "init", "verify" }, .options = &.{data_dir} },
            .{ .names = &.{"reseal"}, .options = &.{ data_dir, v("--accept-legacy-policy"), v("--drop-legacy-policy") } },
        },
    },
    .{ .names = &.{"login"}, .options = &login_options },
    .{ .names = &.{"logout"}, .options = &.{v("--token")} },
    .{
        .names = &.{"fle"},
        .subs = &.{.{ .names = &.{ "rotate-key", "show-rotation", "show-policy", "grant-plaintext", "migrate-encrypt" } }},
    },
    .{
        .names = &.{"apikey"},
        .options = &.{data_dir},
        .subs = &.{
            .{ .names = &.{"validate"} },
            .{ .names = &.{"create"}, .options = &.{ v("--user"), v("--name"), v("--scope"), v("--expires-in") } },
            .{ .names = &.{"list"}, .options = &.{v("--user")} },
            .{ .names = &.{"revoke"}, .options = &.{ v("--user"), v("--name") } },
            .{ .names = &.{"revoke-all"}, .options = &.{ v("--user"), f("--yes"), f("-y") } },
            .{ .names = &.{"check-scope"}, .options = &.{ v("--user"), v("--name"), v("--scope") } },
        },
    },
    .{
        .names = &.{"session"},
        .subs = &.{
            .{ .names = &.{"validate"}, .options = &.{v("--token")} },
            .{ .names = &.{ "info", "rotate", "check-idle" } },
            .{ .names = &.{"invalidate-all"}, .options = &.{v("--user")} },
        },
    },
    .{
        .names = &.{"authn"},
        .subs = &.{
            .{ .names = &.{"config"}, .options = &.{ v("--allow-anonymous-path"), v("--require-mfa-path") } },
            .{ .names = &.{"test-access"}, .options = &.{ v("--path"), f("--session-only"), f("--mfa-verified") } },
            .{ .names = &.{"stepup-check"}, .options = &.{v("--action")} },
            .{ .names = &.{"stepup-mark"} },
        },
    },
    .{
        .names = &.{"tenant"},
        .options = &tenant_passthrough,
        .subs = &.{
            .{ .names = &.{ "list", "show", "drop" } },
            .{ .names = &.{"create"}, .options = &.{v("--parent")} },
            .{ .names = &.{ "set-quota", "set_quota" }, .options = &.{ v("--max-connections"), v("--max-concurrent-queries"), v("--max-graphs"), v("--max-nodes-per-graph") } },
        },
    },
    .{
        .names = &.{"backup"},
        .subs = &.{
            .{ .names = &.{"list"}, .options = &.{v("--dir")} },
            .{ .names = &.{"info"} },
        },
    },
    .{
        .names = &.{"migrate"},
        .subs = &.{
            .{ .names = &.{"status"}, .options = &.{ v("--dir"), f("--allow-unauthenticated") } },
            .{ .names = &.{ "run", "up" }, .options = &.{
                v("--dir"),      f("--dry-run"),     f("--allow-unsigned"), f("--insecure-tls-skip-verify"), f("--insecure"),
                v("--ca-cert"),  v("--client-cert"), v("--client-key"),     v("--server"),                   v("--user"),
                v("--password"),
            } },
            .{ .names = &.{"create"}, .options = &.{ v("--dir"), f("--no-sign") } },
            .{ .names = &.{"sign"}, .options = &.{ v("--dir"), f("--all") } },
        },
    },
};

pub fn find(name: []const u8) ?*const Command {
    for (&commands) |*cmd| {
        for (cmd.names) |n| {
            if (std.mem.eql(u8, n, name)) return cmd;
        }
    }
    return null;
}

/// True when some subcommand of `cmd` (or `cmd` itself) reads `name`.
pub fn knows(cmd: *const Command, name: []const u8) bool {
    if (lookup(&.{cmd.options}, name) != null) return true;
    for (cmd.subs) |sub| {
        if (lookup(&.{sub.options}, name) != null) return true;
    }
    return false;
}

fn lookup(lists: []const []const Option, arg: []const u8) ?Option {
    for (lists) |list| {
        for (list) |opt| {
            if (std.mem.eql(u8, opt.name, arg)) return opt;
        }
    }
    return null;
}

fn isOption(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// The subcommand `args` (the arguments after the command name) select, if
/// `cmd` has subcommands and the first positional argument names one.
pub fn selectSub(cmd: *const Command, args: []const []const u8) ?*const Sub {
    if (cmd.subs.len == 0) return null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isOption(arg)) {
            if (lookup(&.{cmd.options}, arg)) |opt| {
                if (opt.arity == .value) i += 1;
            }
            continue;
        }
        for (cmd.subs) |*sub| {
            for (sub.names) |n| {
                if (std.mem.eql(u8, n, arg)) return sub;
            }
        }
        return null;
    }
    return null;
}

/// Check `args` (the arguments after the command name) against `cmd`.
pub fn check(cmd: *const Command, args: []const []const u8) Verdict {
    var sub_options: []const Option = &.{};
    if (cmd.subs.len > 0) {
        const sub = selectSub(cmd, args) orelse return .ok;
        sub_options = sub.options;
    }
    const lists = [_][]const Option{ cmd.options, sub_options };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!isOption(arg) or isHelp(arg)) continue;
        const opt = lookup(&lists, arg) orelse return .{ .unknown_option = arg };
        switch (opt.arity) {
            .flag => {},
            .value => {
                if (i + 1 >= args.len) return .{ .missing_value = arg };
                i += 1;
            },
            .optional_value => {
                if (i + 1 < args.len and !isOption(args[i + 1])) i += 1;
            },
        }
    }
    return .ok;
}

/// Refuse (exit 2) what `check` refuses, naming the option. `command` is the
/// name the user typed; `args` the arguments after it.
pub fn enforce(command: []const u8, args: []const []const u8) void {
    const cmd = find(command) orelse return;
    const sub_name: []const u8 = if (selectSub(cmd, args)) |_| blk: {
        // The positional that selected the subcommand, for the message.
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (isOption(args[i])) {
                if (lookup(&.{cmd.options}, args[i])) |opt| {
                    if (opt.arity == .value) i += 1;
                }
                continue;
            }
            break :blk args[i];
        }
        break :blk "";
    } else "";
    const sep: []const u8 = if (sub_name.len > 0) " " else "";
    switch (check(cmd, args)) {
        .ok => return,
        .unknown_option => |opt| std.debug.print("Error: geode {s}{s}{s}: unknown option '{s}' (see geode {s}{s}{s} --help)\n", .{ command, sep, sub_name, opt, command, sep, sub_name }),
        .missing_value => |opt| std.debug.print("Error: geode {s}{s}{s}: option '{s}' requires a value (see geode {s}{s}{s} --help)\n", .{ command, sep, sub_name, opt, command, sep, sub_name }),
    }
    std.process.exit(2);
}

test "an unknown option and a value option without its value are refused" {
    const user = find("user").?;
    try std.testing.expectEqual(Verdict.ok, check(user, &.{ "create", "alice", "a@b", "--password", "-x" }));
    try std.testing.expectEqualStrings("--bogus", check(user, &.{ "list", "--bogus" }).unknown_option);
    try std.testing.expectEqualStrings("--password", check(user, &.{ "create", "a", "b", "--password" }).missing_value);
    // An option of another subcommand is not this one's.
    try std.testing.expectEqualStrings("--password", check(user, &.{ "list", "--password", "x" }).unknown_option);
    // A command-level option before the subcommand.
    try std.testing.expectEqual(Verdict.ok, check(user, &.{ "--data-dir", "/d", "list" }));
    // An unknown subcommand is the handler's to report.
    try std.testing.expectEqual(Verdict.ok, check(user, &.{ "frobnicate", "--bogus" }));
    try std.testing.expectEqual(Verdict.ok, check(user, &.{ "list", "--help" }));
    try std.testing.expectEqual(Verdict.ok, check(find("tenant").?, &.{ "create", "t", "--parent", "p", "--server", "h:1", "-P", "pw" }));
}
