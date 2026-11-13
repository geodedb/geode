// SONNY-6436 item 1: the in-repo scripts and fixtures seed keys and admin
// passwords the server accepts.
//
// The server refuses to start with an auth-chain HMAC key
// (GEODE_AUTH_HMAC_KEY, GEODE_TDE_KEY) that is not 64 hex characters, and
// accepts an admin seed (GEODE_ADMIN_PASSWORD / GEODE_DEFAULT_PASSWORD) that
// breaks the password policy only with a forced reset at the first login,
// so every later query of the script fails. Found:
//
//   * tests/cluster/netns_cluster_replication_test.sh and
//     netns_cluster_membership_churn_test.sh: HMAC "netns-test-hmac-..."
//     (not hex) and the admin password "NetnsTestPw123!" (15 characters, one
//     word);
//   * scripts/*.sh, scripts/test/*.sh and the Python test runners: the
//     default "geode-test-password" (no capital, one word);
//   * scripts/perf-gate.sh: "GeodeTestPassword123!" in the loadtest DSN;
//   * scripts/repro/gap0894_merge_throughput.sh: "gap0894-probe-pw";
//   * Makefile otel-compose-up and scripts/otel-compose-verify.sh: a random
//     32-hex-digit password (one lowercase word).
//
// SONNY-6359 scanned the top-level tests/*.sh and scripts/cluster_spawn.sh
// for literal admin seeds; this scans every script and fixture (tests/**,
// scripts/**, deployment/**, docker-compose*, Makefile), follows a
// `NAME="$OTHER"` hand-off to the value `OTHER` is assigned in the same file,
// and checks generated values with the command output at its weakest.
//
// SONNY-6447 item 8: the scan also covers clients/ (the shipped client
// examples, including their Zig sources: a `password = "..."` field) and a
// Python runner's default for a non-admin user's password
// (`${secret:user_password}`, which the server checks against the same
// policy on CREATE USER). Found: scripts/test/extended_test_runner.py
// defaulted it to "UserPass123!" and clients/zig/example_minimal.zig set
// "GeodeTestPassword123!" (one word).
//
// SONNY-6451 item 5: both Python runners substituted any other
// `${secret:NAME}` with `secrets.get(match, f"default-{match}")`, a value
// nobody chose (and one the password policy refuses for a password-named
// secret). The scan refuses a computed-name secret lookup with a fallback;
// the runners now fail the test with UnknownSecretError instead.
//
// CANARY: REQ=REQ-SONNY-6451-UNKNOWN-SECRET; FEATURE="GQL Auth DDL"; ASPECT=UndeclaredSecretIsAnError; STATUS=TESTED; TEST=tests/test_sonny6436_fixture_secrets.zig; OWNER=security; UPDATED=2026-11-12
// CANARY: REQ=REQ-SONNY-6447-FIXTURE-SECRETS; FEATURE="GQL Auth DDL"; ASPECT=ClientsAndUserPasswords; STATUS=TESTED; TEST=tests/test_sonny6436_fixture_secrets.zig; OWNER=security; UPDATED=2026-11-12
// CANARY: REQ=REQ-SONNY-6436-FIXTURE-SECRETS; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6436_fixture_secrets.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const PasswordPolicy = @import("geode_auth").PasswordPolicy;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Variables whose value the server takes as the admin's password.
/// GEODE_OTEL_PASSWORD is the OTel compose stack's admin seed
/// (docker-compose.otel.yml hands it to GEODE_ADMIN_PASSWORD).
const password_keys = [_][]const u8{ "GEODE_ADMIN_PASSWORD", "GEODE_DEFAULT_PASSWORD", "GEODE_OTEL_PASSWORD" };
/// Variables the server takes as (or derives) the auth-chain HMAC key.
const hmac_keys = [_][]const u8{ "GEODE_AUTH_HMAC_KEY", "GEODE_TDE_KEY" };
/// The one generator accepted for an HMAC key: 32 random bytes, hex.
const hmac_generator = "$(openssl rand -hex 32)";
/// Python dictionary / environment keys naming the admin password or, for
/// `user_password`, a user's password (SONNY-6447: CREATE USER checks it
/// against the same policy).
const python_keys = [_][]const u8{ "admin_password", "GEODE_DEFAULT_PASSWORD", "GEODE_ADMIN_PASSWORD", "${secret:admin_password}", "user_password", "${secret:user_password}" };

fn readFileAlloc(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer f.close(io());
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try f.readPositionalAll(io(), &buf, off);
        if (n == 0) break;
        try out.appendSlice(aa, buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    return out.items;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The shell word starting at `text[start]`: a double- or single-quoted
/// string (without its quotes) or a bare word, ending at whitespace, `;` or
/// a quote outside `$(...)` / `${...}`.
fn shellWord(text: []const u8, start: usize) []const u8 {
    if (start >= text.len) return "";
    const q = text[start];
    if (q == '\'') {
        const end = std.mem.indexOfScalarPos(u8, text, start + 1, '\'') orelse text.len;
        return text[start + 1 .. end];
    }
    var depth: usize = 0;
    var i: usize = if (q == '"') start + 1 else start;
    const body = i;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '$' and i + 1 < text.len and (text[i + 1] == '(' or text[i + 1] == '{')) {
            depth += 1;
            i += 1;
            continue;
        }
        if ((c == ')' or c == '}') and depth > 0) {
            depth -= 1;
            continue;
        }
        if (depth > 0) continue;
        if (q == '"') {
            if (c == '"') break;
        } else if (std.mem.indexOfScalar(u8, " \t\n;\"'", c) != null) break;
    }
    return text[body..@min(i, text.len)];
}

/// The value of a YAML `KEY: value` entry starting at `text[start]`.
fn yamlValue(text: []const u8, start: usize) []const u8 {
    const eol = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    var v = std.mem.trim(u8, text[start..eol], " \t\r");
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
    return v;
}

/// The literal values `value` can take in `text` (one file): a literal is
/// itself; `$NAME` / `${NAME}` is every value NAME is assigned in the file;
/// `${NAME:-default}` is `default` and those; `${NAME:?...}` (the caller
/// must set it) is none.
fn evalValue(aa: std.mem.Allocator, text: []const u8, value: []const u8, depth: usize, out: *std.ArrayList([]const u8)) !void {
    if (depth > 8) return;
    var name: []const u8 = "";
    var default: ?[]const u8 = null;
    if (std.mem.startsWith(u8, value, "${") and std.mem.endsWith(u8, value, "}")) {
        const inner = value[2 .. value.len - 1];
        var n: usize = 0;
        while (n < inner.len and isIdentChar(inner[n])) n += 1;
        if (n == 0) return;
        name = inner[0..n];
        const rest = inner[n..];
        if (rest.len == 0) {} else if (std.mem.startsWith(u8, rest, ":-")) {
            default = rest[2..];
        } else if (std.mem.startsWith(u8, rest, ":?") or std.mem.startsWith(u8, rest, "?")) {
            return; // required from the caller
        } else return;
    } else if (value.len > 1 and value[0] == '$' and isIdentChar(value[1])) {
        var n: usize = 1;
        while (n < value.len and isIdentChar(value[n])) n += 1;
        if (n != value.len) return; // a word built from more than the variable
        name = value[1..];
    } else {
        // Once each (a self-referencing `X="${X:-...}"` is met again).
        for (out.items) |seen| if (std.mem.eql(u8, seen, value)) return;
        try out.append(aa, value);
        return;
    }
    if (default) |d| try evalValue(aa, text, d, depth + 1, out);
    // Every assignment `NAME=...` in the file.
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, name)) |i| {
        pos = i + name.len;
        if (i > 0 and isIdentChar(text[i - 1])) continue;
        if (pos >= text.len or text[pos] != '=') continue;
        try evalValue(aa, text, shellWord(text, pos + 1), depth + 1, out);
    }
}

/// `value` with each `$(...)` replaced by "x", the weakest output a
/// generator can give (one short lowercase word).
fn weakestExpansion(aa: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '$' and i + 1 < value.len and value[i + 1] == '(') {
            var depth: usize = 1;
            var j = i + 2;
            while (j < value.len and depth > 0) : (j += 1) {
                if (value[j] == '(') depth += 1;
                if (value[j] == ')') depth -= 1;
            }
            try out.append(aa, 'x');
            i = j;
            continue;
        }
        try out.append(aa, value[i]);
        i += 1;
    }
    return out.items;
}

const Scan = struct {
    aa: std.mem.Allocator,
    policy: PasswordPolicy,
    bad: usize = 0,
    passwords_checked: usize = 0,
    hmac_checked: usize = 0,
    secret_lookups_checked: usize = 0,
    files: usize = 0,

    fn lineOf(text: []const u8, pos: usize) usize {
        return std.mem.count(u8, text[0..pos], "\n") + 1;
    }

    fn isComment(text: []const u8, pos: usize) bool {
        const sol = if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |p| p + 1 else 0;
        const lead = std.mem.trimStart(u8, text[sol..pos], " \t");
        return lead.len > 0 and lead[0] == '#';
    }

    fn checkPassword(self: *Scan, path: []const u8, text: []const u8, pos: usize, value: []const u8) !void {
        if (std.mem.indexOfScalar(u8, value, '$') != null and std.mem.indexOf(u8, value, "$(") == null) return; // a variable, checked where it is set
        self.passwords_checked += 1;
        const weakest = try weakestExpansion(self.aa, value);
        if (self.policy.check(weakest)) |v| {
            std.debug.print("{s}:{d}: seeds admin password \"{s}\": {s}\n", .{ path, lineOf(text, pos), value, self.policy.message(v) });
            self.bad += 1;
        }
    }

    fn checkHmac(self: *Scan, path: []const u8, text: []const u8, pos: usize, value: []const u8) void {
        if (std.mem.indexOfScalar(u8, value, '$') != null and !std.mem.eql(u8, value, hmac_generator)) {
            if (std.mem.indexOf(u8, value, "$(") == null) return; // a variable, checked where it is set
        }
        self.hmac_checked += 1;
        if (std.mem.eql(u8, value, hmac_generator) or isHex64(value)) return;
        std.debug.print("{s}:{d}: auth-chain key \"{s}\" is not 64 hex characters (the server refuses to start)\n", .{ path, lineOf(text, pos), value });
        self.bad += 1;
    }

    /// Every value assigned to one of `keys` (`KEY=word`, YAML `KEY: value`).
    fn assignedValues(self: *Scan, text: []const u8, keys: []const []const u8, comptime on: fn (*Scan, []const u8, []const u8, usize, []const u8) anyerror!void, path: []const u8) !void {
        for (keys) |key| {
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, text, pos, key)) |i| {
                pos = i + key.len;
                if (i > 0 and isIdentChar(text[i - 1])) continue;
                if (i > 0 and text[i - 1] == '{') continue; // an expansion, see expansionDefaults
                if (isComment(text, i)) continue;
                if (pos >= text.len) continue;
                const raw: []const u8 = if (text[pos] == '=')
                    shellWord(text, pos + 1)
                else if (pos + 1 < text.len and text[pos] == ':' and text[pos + 1] == ' ')
                    yamlValue(text, pos + 2)
                else
                    continue;
                var values: std.ArrayList([]const u8) = .empty;
                try evalValue(self.aa, text, raw, 0, &values);
                for (values.items) |v| try on(self, path, text, i, v);
            }
        }
    }

    fn onPassword(self: *Scan, path: []const u8, text: []const u8, pos: usize, value: []const u8) anyerror!void {
        try self.checkPassword(path, text, pos, value);
    }

    fn onHmac(self: *Scan, path: []const u8, text: []const u8, pos: usize, value: []const u8) anyerror!void {
        self.checkHmac(path, text, pos, value);
    }

    /// `${GEODE_ADMIN_PASSWORD:-default}` anywhere: the default seeds the
    /// admin when the caller sets nothing.
    fn expansionDefaults(self: *Scan, path: []const u8, text: []const u8) !void {
        for (password_keys) |key| {
            const marker = try std.fmt.allocPrint(self.aa, "${{{s}:-", .{key});
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, text, pos, marker)) |i| {
                pos = i + marker.len;
                if (isComment(text, i)) continue;
                const word = shellWord(text, i);
                if (!std.mem.startsWith(u8, word, "${")) continue;
                var values: std.ArrayList([]const u8) = .empty;
                try evalValue(self.aa, text, word, 0, &values);
                for (values.items) |v| try self.checkPassword(path, text, i, v);
            }
        }
    }

    /// A Go-client DSN's `pass=` (URL-encoded).
    fn dsnPasswords(self: *Scan, path: []const u8, text: []const u8) !void {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, "pass=")) |i| {
            pos = i + 5;
            if (i == 0 or (text[i - 1] != '&' and text[i - 1] != '?')) continue;
            if (isComment(text, i)) continue;
            var end = pos;
            while (end < text.len and std.mem.indexOfScalar(u8, "&\"'} \t\n", text[end]) == null) end += 1;
            const enc = text[pos..end];
            if (std.mem.indexOfScalar(u8, enc, '$') != null) continue;
            var dec: std.ArrayList(u8) = .empty;
            var k: usize = 0;
            while (k < enc.len) : (k += 1) {
                if (enc[k] == '+') {
                    try dec.append(self.aa, ' ');
                } else if (enc[k] == '%' and k + 2 < enc.len) {
                    try dec.append(self.aa, std.fmt.parseInt(u8, enc[k + 1 .. k + 3], 16) catch '%');
                    k += 2;
                } else try dec.append(self.aa, enc[k]);
            }
            try self.checkPassword(path, text, i, dec.items);
        }
    }

    /// Python: `.get("admin_password", "lit")`, `getenv("KEY", "lit")`,
    /// `.replace("${secret:admin_password}", "lit")`, `["KEY"] = "lit"`.
    fn pythonDefaults(self: *Scan, path: []const u8, text: []const u8) !void {
        for (python_keys) |key| {
            const quoted = try std.fmt.allocPrint(self.aa, "\"{s}\"", .{key});
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, text, pos, quoted)) |i| {
                pos = i + quoted.len;
                if (isComment(text, i)) continue;
                var j = pos;
                while (j < text.len and text[j] == ' ') j += 1;
                if (j < text.len and text[j] == ',') {
                    j += 1;
                } else if (j < text.len and text[j] == ']') {
                    j += 1;
                    while (j < text.len and text[j] == ' ') j += 1;
                    if (j >= text.len or text[j] != '=') continue;
                    j += 1;
                } else continue;
                while (j < text.len and text[j] == ' ') j += 1;
                if (j >= text.len or text[j] != '"') continue;
                const end = std.mem.indexOfScalarPos(u8, text, j + 1, '"') orelse continue;
                try self.checkPassword(path, text, i, text[j + 1 .. end]);
            }
        }
    }

    /// SONNY-6451 item 5: `secrets.get(name, fallback)` with a computed name
    /// invents a value for a secret the spec never declared (the runners
    /// used `f"default-{match}"`, which fails the password policy for a
    /// password-named secret and is a value nobody chose for any other).
    /// An unknown secret must be an error, so a computed-name lookup may
    /// not carry a fallback.
    fn pythonSecretFallbacks(self: *Scan, path: []const u8, text: []const u8) void {
        const marker = "secrets.get(";
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, marker)) |i| {
            pos = i + marker.len;
            if (isComment(text, i)) continue;
            if (pos >= text.len or text[pos] == '"' or text[pos] == '\'') continue; // a literal name, see pythonDefaults
            var depth: usize = 0;
            var j = pos;
            const fallback = while (j < text.len) : (j += 1) {
                switch (text[j]) {
                    '(', '[', '{' => depth += 1,
                    ')', ']', '}' => {
                        if (depth == 0) break false;
                        depth -= 1;
                    },
                    ',' => if (depth == 0) break true,
                    '\n' => break false,
                    else => {},
                }
            } else false;
            self.secret_lookups_checked += 1;
            if (!fallback) continue;
            std.debug.print("{s}:{d}: invents a fallback for an undeclared secret: an unknown secret must be an error\n", .{ path, lineOf(text, i) });
            self.bad += 1;
        }
    }

    /// SONNY-6447: a Zig client example's `password = "literal"` field.
    fn zigPasswords(self: *Scan, path: []const u8, text: []const u8) !void {
        const marker = "password = \"";
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, marker)) |i| {
            pos = i + marker.len;
            if (i > 0 and isIdentChar(text[i - 1])) continue;
            const sol = if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |p| p + 1 else 0;
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, text[sol..i], " \t"), "//")) continue;
            const end = std.mem.indexOfScalarPos(u8, text, pos, '"') orelse continue;
            try self.checkPassword(path, text, i, text[pos..end]);
        }
    }

    fn file(self: *Scan, path: []const u8) !void {
        const raw = readFileAlloc(self.aa, path) catch return;
        const base = std.fs.path.basename(path);
        // make: `$$` is a shell `$`.
        const text = if (std.mem.eql(u8, base, "Makefile") or std.mem.endsWith(u8, base, ".mk"))
            try std.mem.replaceOwned(u8, self.aa, raw, "$$", "$")
        else
            raw;
        self.files += 1;
        if (std.mem.endsWith(u8, base, ".zig")) {
            try self.zigPasswords(path, text);
            return;
        }
        if (std.mem.endsWith(u8, base, ".py")) {
            try self.pythonDefaults(path, text);
            self.pythonSecretFallbacks(path, text);
        } else {
            try self.assignedValues(text, &password_keys, onPassword, path);
            try self.assignedValues(text, &hmac_keys, onHmac, path);
            try self.expansionDefaults(path, text);
        }
        try self.dsnPasswords(path, text);
    }

    fn wanted(path: []const u8) bool {
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "Makefile") or std.mem.startsWith(u8, base, "docker-compose")) return true;
        for ([_][]const u8{ ".sh", ".bash", ".py", ".yml", ".yaml", ".mk", ".env", ".example" }) |ext| {
            if (std.mem.endsWith(u8, base, ext)) return true;
        }
        return false;
    }

    /// `tree`, plus Zig sources (SONNY-6447: only for clients/, whose examples
    /// users copy; tests/ deliberately holds passwords the policy refuses).
    fn treeWithZig(self: *Scan, root: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch return;
        defer dir.close(io());
        var walker = try dir.walk(self.aa);
        defer walker.deinit();
        while (try walker.next(io())) |entry| {
            if (entry.kind != .file) continue;
            if (!wanted(entry.path) and !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            try self.file(try std.fs.path.join(self.aa, &.{ root, entry.path }));
        }
    }

    fn tree(self: *Scan, root: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch return;
        defer dir.close(io());
        var walker = try dir.walk(self.aa);
        defer walker.deinit();
        while (try walker.next(io())) |entry| {
            if (entry.kind != .file) continue;
            if (!wanted(entry.path)) continue;
            try self.file(try std.fs.path.join(self.aa, &.{ root, entry.path }));
        }
    }

    fn top(self: *Scan) !void {
        var dir = try std.Io.Dir.cwd().openDir(io(), ".", .{ .iterate = true });
        defer dir.close(io());
        var it = dir.iterate();
        while (try it.next(io())) |entry| {
            if (entry.kind != .file) continue;
            if (!wanted(entry.name)) continue;
            try self.file(try self.aa.dupe(u8, entry.name));
        }
    }
};

test "SONNY-6436: every admin password and auth-chain key the in-repo scripts and fixtures seed is one the server accepts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scan: Scan = .{ .aa = arena.allocator(), .policy = PasswordPolicy.geodeSecure() };
    try scan.tree("tests");
    try scan.tree("scripts");
    try scan.tree("deployment");
    try scan.treeWithZig("clients");
    try scan.top();
    // Not vacuous: the netns cluster scripts' seeds were found and checked.
    try testing.expect(scan.files > 0);
    try testing.expect(scan.hmac_checked >= 2);
    try testing.expect(scan.passwords_checked > 10);
    try testing.expectEqual(@as(usize, 0), scan.bad);
}

test "SONNY-6447: the scan reads a Zig client's password field and a Python user-password default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var scan: Scan = .{ .aa = aa, .policy = PasswordPolicy.geodeSecure() };
    try scan.zigPasswords("fixture.zig",
        \\    cfg.password = "GeodeTestPassword123!";
        \\    // cfg.password = "short";
        \\    .password = "Geode Example Client Passphrase",
        \\    const old_password = "x";
        \\
    );
    try scan.pythonDefaults("fixture.py",
        \\secrets.get("user_password", "UserPass123!")
        \\secrets.get("admin_password", "Geode Test Admin Passphrase")
        \\
    );
    // The two fields and the two Python defaults are checked; the one-word
    // field and "UserPass123!" are refused.
    try testing.expectEqual(@as(usize, 4), scan.passwords_checked);
    try testing.expectEqual(@as(usize, 2), scan.bad);
}

test "SONNY-6451: the scan refuses a fallback value for an undeclared secret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scan: Scan = .{ .aa = arena.allocator(), .policy = PasswordPolicy.geodeSecure() };
    scan.pythonSecretFallbacks("fixture.py",
        \\    text = text.replace(f"${{secret:{match}}}", secrets.get(match, f"default-{match}"))
        \\    v = _secrets.get(name_of(match, 1), "x")
        \\    v = secrets.get(match)
        \\    # secrets.get(match, "commented")
        \\    v = secrets.get("admin_password", "Geode Test Admin Passphrase")
        \\
    );
    // The two computed-name lookups with a fallback are refused; the one
    // without, the comment and the literal name (pythonDefaults checks it)
    // are not.
    try testing.expectEqual(@as(usize, 3), scan.secret_lookups_checked);
    try testing.expectEqual(@as(usize, 2), scan.bad);
}

test "SONNY-6436: the scan resolves hand-offs and generated values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const text =
        \\HMAC="netns-test-hmac-0123"; PW="Short1!"
        \\GOOD="$(openssl rand -hex 32)"
        \\GEODE_AUTH_HMAC_KEY="$HMAC" GEODE_ADMIN_PASSWORD="$PW" x
        \\GEODE_TDE_KEY="$GOOD"
        \\GEODE_OTEL_PASSWORD="${GEODE_OTEL_PASSWORD:-$(od -An -tx1 -N16 /dev/urandom)}"
        \\A="${GEODE_DEFAULT_PASSWORD:-Otel Compose $(od -An) Passphrase}"
        \\
    ;
    var values: std.ArrayList([]const u8) = .empty;
    try evalValue(aa, text, "$HMAC", 0, &values);
    try testing.expectEqual(@as(usize, 1), values.items.len);
    try testing.expectEqualStrings("netns-test-hmac-0123", values.items[0]);
    values.clearRetainingCapacity();
    try evalValue(aa, text, "$GOOD", 0, &values);
    try testing.expectEqualStrings(hmac_generator, values.items[0]);
    try testing.expectEqualStrings("Otel Compose x Passphrase", try weakestExpansion(aa, "Otel Compose $(od -An) Passphrase"));

    var scan: Scan = .{ .aa = aa, .policy = PasswordPolicy.geodeSecure() };
    try scan.assignedValues(text, &password_keys, Scan.onPassword, "fixture");
    try scan.assignedValues(text, &hmac_keys, Scan.onHmac, "fixture");
    try scan.expansionDefaults("fixture", text);
    // "netns-test-hmac-0123", "Short1!" and the bare od output (seen as an
    // assignment and as an expansion default) are refused; the openssl key
    // and the passphrase around od are accepted.
    try testing.expectEqual(@as(usize, 2), scan.hmac_checked);
    try testing.expectEqual(@as(usize, 4), scan.bad);
}
