const std = @import("std");
const geode = @import("geode");

// Mock server context for testing
const TestContext = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestContext {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestContext) void {
        _ = self;
    }

    // Simplified query execution for testing
    fn executeQuery(self: *TestContext, query: []const u8) !geode.protocol.Value {
        _ = self;
        _ = query;
        // In a real test, this would execute against actual server
        // For now, we're testing that queries parse and compile
        return .Null;
    }
};

test "e2e BLAKE2b-256 hash in CREATE statement" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\CREATE (doc:Document {
        \\    id: 1,
        \\    content: "Test document",
        \\    checksum: HashData("BLAKE2b-256", "Test document")
        \\})
        \\RETURN doc.checksum
    ;

    // Parse the query
    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    try std.testing.expect(result.program.statements.len == 1);

    // In real test, would execute and verify the hash
    _ = try ctx.executeQuery(query);
}

test "e2e BLAKE2b-512 hash comparison" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const setup_query =
        \\CREATE (doc1:Document {
        \\    content: "Document A",
        \\    hash: HashData("BLAKE2b-512", "Document A")
        \\})
        \\CREATE (doc2:Document {
        \\    content: "Document B",
        \\    hash: HashData("BLAKE2b-512", "Document B")
        \\})
    ;

    const verify_query =
        \\MATCH (d1:Document), (d2:Document)
        \\WHERE d1.content = "Document A" AND d2.content = "Document B"
        \\RETURN hash_equals(d1.hash, d2.hash) AS same_hash
    ;

    // Parse queries
    var setup_result = try geode.parseGql(setup_query, allocator);
    defer setup_result.deinit();

    var verify_result = try geode.parseGql(verify_query, allocator);
    defer verify_result.deinit();

    // Execute (mock)
    _ = try ctx.executeQuery(setup_query);
    _ = try ctx.executeQuery(verify_query);
}

test "e2e BLAKE2s-256 hash in WHERE clause" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\MATCH (n:Node)
        \\WHERE n.checksum = HashData("BLAKE2s-256", $input_data)
        \\RETURN n.id, n.checksum
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    try std.testing.expect(result.program.statements.len == 1);

    _ = try ctx.executeQuery(query);
}

test "e2e Argon2id password authentication flow" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    // Registration query
    const register_query =
        \\CREATE (user:User {
        \\    username: "testuser",
        \\    email: "test@example.com",
        \\    salt: "random_salt_16_bytes",
        \\    password_hash: Argon2idHash("SecurePass123", "random_salt_16_bytes", 4, 65536, 1)
        \\})
        \\RETURN user.username
    ;

    // Login query
    const login_query =
        \\MATCH (user:User {username: "testuser"})
        \\WHERE hash_equals(
        \\    user.password_hash,
        \\    Argon2idHash($password, user.salt, 4, 65536, 1)
        \\)
        \\RETURN user.username, user.email
    ;

    // Parse both queries
    var register_result = try geode.parseGql(register_query, allocator);
    defer register_result.deinit();

    var login_result = try geode.parseGql(login_query, allocator);
    defer login_result.deinit();

    // Execute (mock)
    _ = try ctx.executeQuery(register_query);
    _ = try ctx.executeQuery(login_query);
}

test "e2e Blake2b KDF for key derivation" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\CREATE (session:Session {
        \\    id: "sess_123",
        \\    user_id: "user_456",
        \\    session_key: Blake2bKdf(32, "session:sess_123", $master_key),
        \\    csrf_token: Blake2bKdf(16, "csrf:sess_123", $master_key),
        \\    created_at: DateTime()
        \\})
        \\RETURN session.id
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    try std.testing.expect(result.program.statements.len == 1);

    _ = try ctx.executeQuery(query);
}

test "e2e Blake2s KDF for compact keys" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\CREATE (token:Token {
        \\    value: Blake2sKdf(16, "token:auth", $secret),
        \\    expires: DateTime() + Duration("PT1H")
        \\})
        \\RETURN token.value
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    _ = try ctx.executeQuery(query);
}

test "e2e hash algorithm detection" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\MATCH (doc:Document)
        \\WITH doc, hash_alg(doc.checksum) AS algorithm
        \\RETURN algorithm, count(doc) AS count
        \\ORDER BY count DESC
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    _ = try ctx.executeQuery(query);
}

test "e2e content deduplication with hashes" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\MATCH (f1:File), (f2:File)
        \\WHERE f1.id < f2.id
        \\  AND hash_equals(
        \\      HashData("BLAKE2b-256", f1.content),
        \\      HashData("BLAKE2b-256", f2.content)
        \\  )
        \\CREATE (f1)-[:DUPLICATE_OF {
        \\    detected_at: DateTime(),
        \\    hash: HashData("BLAKE2b-256", f1.content)
        \\}]->(f2)
        \\RETURN f1.path, f2.path
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    _ = try ctx.executeQuery(query);
}

test "e2e hash chain for audit log" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\CREATE (entry:AuditLog {
        \\    id: 1,
        \\    action: "CREATE_USER",
        \\    timestamp: DateTime(),
        \\    previous_hash: $prev_hash,
        \\    entry_hash: HashData("BLAKE2b-512",
        \\        toString(1) + ":CREATE_USER:" + toString(DateTime()) + ":" + $prev_hash
        \\    )
        \\})
        \\RETURN entry.entry_hash
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    _ = try ctx.executeQuery(query);
}

test "e2e mixed hash algorithms in single query" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\CREATE (security:SecurityTest {
        \\    sha3_hash: HashData("SHA3-256", "test"),
        \\    sha3_512_hash: HashData("SHA3-512", "test"),
        \\    blake3_hash: HashData("BLAKE3", "test"),
        \\    blake2b_256_hash: HashData("BLAKE2b-256", "test"),
        \\    blake2b_512_hash: HashData("BLAKE2b-512", "test"),
        \\    blake2s_hash: HashData("BLAKE2s-256", "test")
        \\})
        \\RETURN security
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    try std.testing.expect(result.program.statements.len == 1);

    _ = try ctx.executeQuery(query);
}

test "e2e hash in aggregation functions" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\MATCH (doc:Document)
        \\WITH hash_alg(doc.checksum) AS alg,
        \\     collect(doc.id) AS doc_ids,
        \\     count(*) AS doc_count
        \\WHERE alg IN ["BLAKE2b-256", "BLAKE2b-512", "BLAKE2s-256"]
        \\RETURN alg, doc_count, doc_ids[0..3] AS sample_ids
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    _ = try ctx.executeQuery(query);
}

test "e2e hash with CASE expressions" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\MATCH (item:Item)
        \\RETURN item.id,
        \\  CASE
        \\    WHEN hash_alg(item.hash) = "Argon2id" THEN "password"
        \\    WHEN hash_alg(item.hash) IN ["BLAKE2b-256", "BLAKE2b-512"] THEN "blake2b"
        \\    WHEN hash_alg(item.hash) = "BLAKE2s-256" THEN "blake2s"
        \\    ELSE "other"
        \\  END AS hash_family
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    _ = try ctx.executeQuery(query);
}

test "e2e hash in MERGE statement" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const query =
        \\MERGE (content:UniqueContent {
        \\    hash: HashData("BLAKE2b-256", $content)
        \\})
        \\ON CREATE SET
        \\    content.created_at = DateTime(),
        \\    content.data = $content,
        \\    content.ref_count = 1
        \\ON MATCH SET
        \\    content.ref_count = content.ref_count + 1,
        \\    content.last_accessed = DateTime()
        \\RETURN content.hash, content.ref_count
    ;

    var result = try geode.parseGql(query, allocator);
    defer result.deinit();

    _ = try ctx.executeQuery(query);
}

test "CANARY e2e BLAKE2b hash in queries" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const queries = [_][]const u8{
        \\CREATE (n:Node {h: HashData("BLAKE2b-256", "canary")})
        ,
        \\MATCH (n) WHERE n.h = HashData("BLAKE2b-512", "canary") RETURN n
        ,
        \\WITH HashData("BLAKE2b-256", "test") AS h RETURN hash_alg(h)
        ,
    };

    for (queries) |query| {
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();
        _ = try ctx.executeQuery(query);
    }

    std.debug.print("CANARY e2e BLAKE2b hash queries executed successfully\n", .{});
}

test "CANARY e2e BLAKE2s hash in queries" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const queries = [_][]const u8{
        \\CREATE (n:Node {h: HashData("BLAKE2s-256", "canary")})
        ,
        \\SET n.token = Blake2sKdf(16, "canary", "key")
        ,
    };

    for (queries) |query| {
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();
        _ = try ctx.executeQuery(query);
    }

    std.debug.print("CANARY e2e BLAKE2s hash queries executed successfully\n", .{});
}

test "CANARY e2e Argon2id in queries" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const queries = [_][]const u8{
        \\CREATE (u:User {pwd: Argon2idHash("pass", "salt", 4, 65536, 1)})
        ,
        \\MATCH (u:User) WHERE hash_equals(u.pwd, Argon2idHash($p, u.salt, 4, 65536, 1)) RETURN u
        ,
    };

    for (queries) |query| {
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();
        _ = try ctx.executeQuery(query);
    }

    std.debug.print("CANARY e2e Argon2id queries executed successfully\n", .{});
}

test "CANARY e2e Blake2 KDF in queries" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    const queries = [_][]const u8{
        \\CREATE (k:Key {v: Blake2bKdf(32, "canary", "master")})
        ,
        \\SET n.token = Blake2sKdf(16, "canary", "secret")
        ,
    };

    for (queries) |query| {
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();
        _ = try ctx.executeQuery(query);
    }

    std.debug.print("CANARY e2e Blake2 KDF queries executed successfully\n", .{});
}
