# Map Projection Feature Implementation

## Overview

Implemented GQL map projection syntax support allowing property extraction from graph nodes and edges using the `n {.property1, .property2}` syntax.

## Changes Made

### 1. AST Extension (src/gql/ast.zig:219)

Added new `MapProjection` variant to the `Expr` union:

```zig
MapProjection: struct { source: *Expr, fields: [][]const u8 },
```

This represents expressions like `n {.name, .age}` where:
- `source` is the expression being projected (e.g., variable `n`)
- `fields` is an array of property names to extract (e.g., `["name", "age"]`)

### 2. Parser Implementation (src/gql/parser.zig:1823-1847)

Added parsing logic in `parsePostfixExpr()` to handle map projection syntax:

```zig
if (self.cur.kind == .l_brace) {
    // Map projection: n {.name, .age}
    self.advance();
    var fields = std.ArrayList([]const u8).initCapacity(...);

    // Parse fields: .prop1, .prop2, ...
    while (self.cur.kind == .dot) {
        self.advance();
        const field_token = try self.expectIdentifierOrKeyword();
        try fields.append(self.arena.allocator(), field_token.lexeme);

        if (self.cur.kind == .comma) {
            self.advance();
        } else {
            break;
        }
    }

    _ = try self.expect(.r_brace);
    // Create MapProjection AST node
    base = .{ .MapProjection = .{ .source = bp, .fields = ... } };
}
```

**Parsing Details:**
- Detects `{` after a primary expression
- Parses dot-prefixed field names: `.field1, .field2`
- Supports trailing commas
- Validates closing `}`

### 3. Evaluator Implementation (src/eval.zig:1396-1445)

Added evaluation logic for map projections in `evalExpr()`:

```zig
.MapProjection => |mp| blk_projection: {
    // Evaluate the source expression
    const source = try evalExpr(ally, mp.source.*, env);

    // Create a map with projected fields
    var map = std.StringHashMap(Value).init(ally);

    // Extract fields based on source type
    for (mp.fields) |field| {
        const field_value = switch (source) {
            .Map => |src_map| {
                // Extract from hashmap
                src_map.get(field) orelse Value{ .Null = {} }
            },
            .Node => |node| {
                // Extract from graph node properties
                const val = node.properties.get(field) orelse break :blk_node Value{ .Null = {} };
                // Convert PropertyValue to Value
                switch (val) {
                    .String => |s| Value{ .Str = s },
                    .Int => |i| Value{ .Int = i },
                    .Bool => |b| Value{ .Bool = b },
                    else => Value{ .Null = {} },
                }
            },
            .Edge => |edge| {
                // Extract from graph edge properties
                const val = edge.properties.get(field) orelse break :blk_edge Value{ .Null = {} };
                // Convert PropertyValue to Value
                switch (val) {
                    .String => |s| Value{ .Str = s },
                    .Int => |i| Value{ .Int = i },
                    .Bool => |b| Value{ .Bool = b },
                    else => Value{ .Null = {} },
                }
            },
            .ExtValue => |_| {
                // ExtValue types don't support property access
                Value{ .Null = {} }
            },
            else => Value{ .Null = {} },
        };
        try map.put(field, field_value);
    }

    break :blk_projection Value{ .Map = map };
}
```

**Evaluation Details:**
- Evaluates source expression to get the object
- Supports extraction from:
  - `.Map`: Direct property lookup in hashmaps
  - `.Node`: Extracts from graph node properties with type conversion
  - `.Edge`: Extracts from graph edge properties with type conversion
  - Other types: Returns null for missing/unsupported types
- Returns a new `Map` value with only the requested properties

### 4. Printer Support (src/gql/print.zig:668-676)

Added pretty-printing support for map projections:

```zig
.MapProjection => |mp| {
    try printExprWith(w, mp.source.*, 0, opts);
    try w.print(" {{", .{});
    for (mp.fields, 0..) |field, i| {
        if (i > 0) try w.print(", ", .{});
        try w.print(".{s}", .{field});
    }
    try w.print("}}", .{});
},
```

**Printing Format:**
- Outputs: `source {.field1, .field2, ...}`
- Properly escapes braces in format strings
- Handles field list with comma separation

## Type Handling

### Supported Source Types

1. **Map (std.StringHashMap(Value))**
   - Direct property lookup
   - Returns value or null if field doesn't exist

2. **Node (graph_store.Node)**
   - Accesses `node.properties` hashmap
   - Converts `PropertyValue` to `Value`:
     - `PropertyValue.String` → `Value.Str`
     - `PropertyValue.Int` → `Value.Int`
     - `PropertyValue.Bool` → `Value.Bool`

3. **Edge (graph_store.Edge)**
   - Same as Node, accesses `edge.properties`
   - Performs PropertyValue → Value conversion

4. **ExtValue / Other Types**
   - Returns null for unsupported types
   - Future enhancement: could support ExtValue map types

## Usage Examples

```gql
-- Extract specific properties from a node
MATCH (n:Person)
RETURN n {.name, .age}

-- Nested projections
MATCH (n:Person)-[r:KNOWS]->(m:Person)
RETURN n {.name}, r {.since}, m {.name, .age}

-- With aliases
MATCH (n:Person)
RETURN n {.name, .age} AS person_info
```

## Known Limitations

1. **ExtValue Support**: ExtValue types (IpAddr, Subnet, etc.) currently return null for projections. Future work could add support for structured ExtValue types.

2. **Nested Projections**: The current implementation doesn't support nested property paths like `n {.address.city}`. Only top-level properties are supported.

3. **Dynamic Properties**: All projected fields must be static identifiers, not computed expressions.

## Testing Recommendations

1. Test with graph nodes containing various property types
2. Test with missing properties (should return null)
3. Test with edges/relationships
4. Test projection from map expressions
5. Test in RETURN, WITH, and WHERE clauses

## Build Status

✅ **Compilation**: Successfully compiles without errors
✅ **Binary**: `./zig-out/bin/geode` created successfully

## Files Modified

1. `src/gql/ast.zig` - Added MapProjection AST node
2. `src/gql/parser.zig` - Implemented map projection parsing
3. `src/eval.zig` - Implemented map projection evaluation
4. `src/gql/print.zig` - Added map projection pretty-printing

## Future Enhancements

1. Support for nested property paths (`.address.city`)
2. Support for wildcard projections (`.all*`)
3. Support for computed field names
4. Support for ExtValue structured types
5. Performance optimization for large property sets
