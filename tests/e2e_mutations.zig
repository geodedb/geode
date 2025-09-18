const std = @import("std");
const geode = @import("geode");

test "CREATE statement parsing" {
    const allocator = std.testing.allocator;
    
    // Test CREATE with node
    const create_node = "CREATE (n:Person {name: 'Alice', age: 30})";
    var res = try geode.parseGql(create_node, allocator);
    defer res.deinit();
    
    const stmt = res.program.statements[0];
    try std.testing.expect(stmt == .Create);
    
    const create = stmt.Create;
    try std.testing.expectEqual(@as(usize, 1), create.pattern.chains.len);
    
    const chain = create.pattern.chains[0];
    try std.testing.expectEqual(@as(usize, 1), chain.hops.len);
    
    const hop = chain.hops[0];
    try std.testing.expect(hop.left.name != null);
    try std.testing.expectEqualStrings("n", hop.left.name.?);
    try std.testing.expectEqual(@as(usize, 1), hop.left.labels.len);
    try std.testing.expectEqualStrings("Person", hop.left.labels[0]);
    try std.testing.expect(hop.left.props != null);
    try std.testing.expectEqual(@as(usize, 2), hop.left.props.?.len);
}

test "DELETE statement parsing" {
    const allocator = std.testing.allocator;
    
    // Test DELETE with variable
    const delete_simple = "DELETE n";
    var res = try geode.parseGql(delete_simple, allocator);
    defer res.deinit();
    
    const stmt = res.program.statements[0];
    try std.testing.expect(stmt == .Delete);
    
    const delete = stmt.Delete;
    try std.testing.expectEqual(@as(usize, 1), delete.items.len);
    try std.testing.expect(delete.items[0] == .Variable);
    try std.testing.expectEqualStrings("n", delete.items[0].Variable);
    try std.testing.expectEqual(false, delete.detach);
}

test "MERGE statement parsing" {
    const allocator = std.testing.allocator;
    
    // Test MERGE with ON CREATE and ON MATCH
    const merge_stmt = "MERGE (n:Person {email: 'alice@example.com'}) ON CREATE SET n.created = 1 ON MATCH SET n.updated = 2";
    var res = try geode.parseGql(merge_stmt, allocator);
    defer res.deinit();
    
    const stmt = res.program.statements[0];
    try std.testing.expect(stmt == .Merge);
    
    const merge = stmt.Merge;
    try std.testing.expectEqual(@as(usize, 1), merge.pattern.chains.len);
    try std.testing.expectEqual(@as(usize, 1), merge.on_create.len);
    try std.testing.expectEqual(@as(usize, 1), merge.on_match.len);
    
    // Check ON CREATE clause
    const on_create = merge.on_create[0];
    try std.testing.expectEqualStrings("n", on_create.target.object);
    try std.testing.expectEqualStrings("created", on_create.target.property);
    
    // Check ON MATCH clause
    const on_match = merge.on_match[0];
    try std.testing.expectEqualStrings("n", on_match.target.object);
    try std.testing.expectEqualStrings("updated", on_match.target.property);
}

test "CREATE with relationship" {
    const allocator = std.testing.allocator;
    
    // Test CREATE with relationship
    const create_rel = "CREATE (a:Person {name: 'Alice'})-[:KNOWS {since: 2020}]->(b:Person {name: 'Bob'})";
    var res = try geode.parseGql(create_rel, allocator);
    defer res.deinit();
    
    const stmt = res.program.statements[0];
    try std.testing.expect(stmt == .Create);
    
    const create = stmt.Create;
    const chain = create.pattern.chains[0];
    const hop = chain.hops[0];
    
    // Check relationship
    try std.testing.expectEqual(@as(usize, 1), hop.rel.types.len);
    try std.testing.expectEqualStrings("KNOWS", hop.rel.types[0]);
    try std.testing.expect(hop.rel.props != null);
    try std.testing.expectEqual(@as(usize, 1), hop.rel.props.?.len);
    try std.testing.expectEqualStrings("since", hop.rel.props.?[0].key);
}

test "DETACH DELETE parsing" {
    const allocator = std.testing.allocator;
    
    // Test DETACH DELETE
    const detach_delete = "DETACH DELETE n";
    var res = try geode.parseGql(detach_delete, allocator);
    defer res.deinit();
    
    const stmt = res.program.statements[0];
    try std.testing.expect(stmt == .Delete);
    
    const delete = stmt.Delete;
    try std.testing.expectEqual(true, delete.detach);
    try std.testing.expectEqual(@as(usize, 1), delete.items.len);
}