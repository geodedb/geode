const std = @import("std");
const geode = @import("geode");

test "parse Hash constructor with new algorithms" {
    const allocator = std.testing.allocator;

    // Test BLAKE2b-256
    {
        const query =
            \\CREATE (n:Node {
            \\  hash: Hash("BLAKE2b-256", "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
            \\})
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
        const stmt = result.program.statements[0];
        try std.testing.expect(stmt == .Create);
    }

    // Test BLAKE2b-512
    {
        const query =
            \\RETURN Hash("BLAKE2b-512", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test BLAKE2s-256
    {
        const query =
            \\MATCH (n:Node)
            \\WHERE n.hash = Hash("BLAKE2s-256", "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
            \\RETURN n
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test Argon2id
    {
        const query =
            \\SET n.password = Hash("Argon2id", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "parse HashData function calls" {
    const allocator = std.testing.allocator;

    // Test HashData with BLAKE2b-256
    {
        const query =
            \\CREATE (doc:Document {
            \\  checksum: HashData("BLAKE2b-256", "document content here")
            \\})
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
        const create = result.program.statements[0].Create;
        try std.testing.expect(create.pattern.len == 1);
    }

    // Test HashData with BLAKE2b-512
    {
        const query =
            \\RETURN HashData("BLAKE2b-512", doc.content) AS content_hash
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
        const ret = result.program.statements[0].Return;
        try std.testing.expect(ret.items.len == 1);
    }

    // Test HashData with BLAKE2s-256
    {
        const query =
            \\MATCH (n:Node)
            \\WHERE hash_equals(n.hash, HashData("BLAKE2s-256", $data))
            \\RETURN n
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test HashData in complex expression
    {
        const query =
            \\WITH HashData("BLAKE3", "data1") AS h1,
            \\     HashData("BLAKE2b-256", "data2") AS h2
            \\RETURN hash_equals(h1, h2) AS same
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "parse Argon2idHash function with parameters" {
    const allocator = std.testing.allocator;

    // Test basic Argon2idHash
    {
        const query =
            \\CREATE (user:User {
            \\  password_hash: Argon2idHash("password", "salt1234567890ab", 4, 65536, 1)
            \\})
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test Argon2idHash with variables
    {
        const query =
            \\MATCH (u:User {username: $username})
            \\WHERE hash_equals(u.password_hash, Argon2idHash($password, u.salt, 4, 65536, 1))
            \\RETURN u
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
        const match = result.program.statements[0].Match;
        try std.testing.expect(match.where != null);
    }

    // Test Argon2idHash with different parameter values
    {
        const query =
            \\SET user.secure_hash = Argon2idHash($password, $salt, 8, 1048576, 2)
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test Argon2idHash in RETURN clause
    {
        const query =
            \\RETURN Argon2idHash("test", "saltsalt", 3, 4096, 1) AS pwd_hash
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "parse Blake2 KDF functions" {
    const allocator = std.testing.allocator;

    // Test Blake2bKdf
    {
        const query =
            \\CREATE (key:ApiKey {
            \\  signing_key: Blake2bKdf(32, "signing-v1", "master-key"),
            \\  encryption_key: Blake2bKdf(32, "encryption-v1", "master-key")
            \\})
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test Blake2sKdf
    {
        const query =
            \\SET session.token = Blake2sKdf(16, "session", $master_secret)
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test KDF in WITH clause
    {
        const query =
            \\WITH Blake2bKdf(32, "context", "key") AS derived_key
            \\RETURN derived_key
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test nested KDF calls
    {
        const query =
            \\RETURN Blake2bKdf(32, "level2", Blake2sKdf(16", "level1", "root"))
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "parse hash comparison functions" {
    const allocator = std.testing.allocator;

    // Test hash_equals
    {
        const query =
            \\MATCH (doc:Document)
            \\WHERE hash_equals(doc.checksum, HashData("BLAKE2b-256", $content))
            \\RETURN doc
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test hash_alg
    {
        const query =
            \\MATCH (n:Node)
            \\WHERE hash_alg(n.hash) = "BLAKE2b-512"
            \\RETURN n
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test complex hash comparison
    {
        const query =
            \\MATCH (a:Node), (b:Node)
            \\WHERE hash_equals(a.hash, b.hash)
            \\  AND hash_alg(a.hash) IN ["BLAKE2b-256", "BLAKE2s-256"]
            \\RETURN a, b
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "parse hash in complex queries" {
    const allocator = std.testing.allocator;

    // Test hash in CREATE with multiple properties
    {
        const query =
            \\CREATE (audit:AuditLog {
            \\  id: UUID(),
            \\  timestamp: DateTime(),
            \\  action: $action,
            \\  checksum_blake2b: HashData("BLAKE2b-256", $action),
            \\  checksum_blake2s: HashData("BLAKE2s-256", $action),
            \\  checksum_blake3: HashData("BLAKE3", $action),
            \\  signature: Hash("BLAKE2b-512", $signature_hex)
            \\})
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test hash in MERGE statement
    {
        const query =
            \\MERGE (content:UniqueContent {
            \\  hash: HashData("BLAKE2b-512", $content)
            \\})
            \\ON CREATE SET content.created = DateTime()
            \\ON MATCH SET content.accessed = DateTime()
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test hash in CASE expression
    {
        const query =
            \\MATCH (n:Node)
            \\RETURN CASE
            \\  WHEN hash_alg(n.hash) = "SHA3-256" THEN "legacy"
            \\  WHEN hash_alg(n.hash) = "BLAKE3" THEN "modern"
            \\  WHEN hash_alg(n.hash) IN ["BLAKE2b-256", "BLAKE2b-512"] THEN "blake2b"
            \\  WHEN hash_alg(n.hash) = "BLAKE2s-256" THEN "blake2s"
            \\  WHEN hash_alg(n.hash) = "Argon2id" THEN "password"
            \\  ELSE "unknown"
            \\END AS hash_type
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test hash in aggregation
    {
        const query =
            \\MATCH (doc:Document)
            \\WITH hash_alg(doc.checksum) AS algorithm, count(*) AS doc_count
            \\WHERE algorithm IN ["BLAKE2b-256", "BLAKE2b-512", "BLAKE2s-256"]
            \\RETURN algorithm, doc_count
            \\ORDER BY doc_count DESC
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "parse hash in path expressions" {
    const allocator = std.testing.allocator;

    // Test hash in relationship properties
    {
        const query =
            \\CREATE (a:Node)-[r:SIGNED {
            \\  signature: HashData("BLAKE2b-512", a.id + ":" + b.id),
            \\  timestamp: DateTime()
            \\}]->(b:Node)
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test hash in path pattern matching
    {
        const query =
            \\MATCH path = (start:Block)-[:NEXT*]->(end:Block)
            \\WHERE ALL(rel IN relationships(path) WHERE
            \\  hash_equals(
            \\    endNode(rel).previous_hash,
            \\    startNode(rel).hash
            \\  )
            \\)
            \\RETURN path
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "parse invalid hash algorithm names" {
    const allocator = std.testing.allocator;

    // These should parse successfully - validation happens at evaluation time
    {
        const query =
            \\RETURN Hash("InvalidAlgo", "abcd")
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        // Should parse without error
        try std.testing.expect(result.program.statements.len == 1);
    }

    // Test with typo in algorithm name
    {
        const query =
            \\RETURN HashData("BLAKE2b256", "data")
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        // Should parse - error occurs at runtime
        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "parse hash with string concatenation" {
    const allocator = std.testing.allocator;

    {
        const query =
            \\CREATE (chain:HashChain {
            \\  value: $value,
            \\  hash: HashData("BLAKE2b-256", $prev_hash + ":" + $value + ":" + DateTime())
            \\})
        ;
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();

        try std.testing.expect(result.program.statements.len == 1);
    }
}

test "CANARY parse BLAKE2b hash constructors" {
    const allocator = std.testing.allocator;

    const queries = [_][]const u8{
        \\RETURN Hash("BLAKE2b-256", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        ,
        \\RETURN Hash("BLAKE2b-512", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        ,
        \\RETURN HashData("BLAKE2b-256", "test data")
        ,
        \\RETURN HashData("BLAKE2b-512", "test data")
        ,
    };

    for (queries) |query| {
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();
        try std.testing.expect(result.program.statements.len == 1);
    }

    std.debug.print("CANARY BLAKE2b hash constructors parsed successfully\n", .{});
}

test "CANARY parse BLAKE2s hash constructors" {
    const allocator = std.testing.allocator;

    const queries = [_][]const u8{
        \\RETURN Hash("BLAKE2s-256", "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
        ,
        \\RETURN HashData("BLAKE2s-256", "compact data")
        ,
        \\RETURN Blake2sKdf(16, "context", "key")
        ,
    };

    for (queries) |query| {
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();
        try std.testing.expect(result.program.statements.len == 1);
    }

    std.debug.print("CANARY BLAKE2s hash constructors parsed successfully\n", .{});
}

test "CANARY parse Argon2id password hashing" {
    const allocator = std.testing.allocator;

    const queries = [_][]const u8{
        \\RETURN Hash("Argon2id", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        ,
        \\RETURN Argon2idHash("password", "salt1234567890ab", 4, 65536, 1)
        ,
        \\CREATE (u:User {pwd: Argon2idHash($pass, $salt, 6, 262144, 1)})
        ,
    };

    for (queries) |query| {
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();
        try std.testing.expect(result.program.statements.len == 1);
    }

    std.debug.print("CANARY Argon2id password hashing parsed successfully\n", .{});
}

test "CANARY parse Blake2 KDF functions" {
    const allocator = std.testing.allocator;

    const queries = [_][]const u8{
        \\RETURN Blake2bKdf(32, "signing-v1", "master-key")
        ,
        \\RETURN Blake2sKdf(16, "auth", "secret")
        ,
        \\SET key.derived = Blake2bKdf(32, "app:" + key.id, $master)
        ,
    };

    for (queries) |query| {
        var result = try geode.parseGql(query, allocator);
        defer result.deinit();
        try std.testing.expect(result.program.statements.len == 1);
    }

    std.debug.print("CANARY Blake2 KDF functions parsed successfully\n", .{});
}
