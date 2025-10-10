# Session Management in Geode

This document describes the session management features in Geode, including session parameters and transaction handling.

## Session Parameters

Session parameters allow you to store named values that persist across queries within a session. Geode supports three types of session parameters:

### 1. Graph Parameters

Graph parameters store references to graphs for use in graph pattern queries.

**Syntax:**
```gql
SESSION SET GRAPH [$param_name] = <graph_expression> [IF NOT EXISTS]
```

**Examples:**
```gql
-- Set current graph as parameter
SESSION SET GRAPH $my_graph = CURRENT_GRAPH

-- Set graph with IF NOT EXISTS
SESSION SET GRAPH IF NOT EXISTS $default_graph = G1

-- Reference graph parameter in queries (future enhancement)
USE GRAPH $my_graph
```

### 2. Value Parameters

Value parameters store scalar values (integers, strings, booleans, etc.) for use in queries.

**Syntax:**
```gql
SESSION SET VALUE [$param_name] = <expression> [IF NOT EXISTS]
```

**Examples:**
```gql
-- Set integer value
SESSION SET VALUE $counter = 42

-- Set string value
SESSION SET VALUE $username = 'alice'

-- Set boolean value
SESSION SET VALUE $enabled = true

-- Conditional set (only if doesn't exist)
SESSION SET VALUE IF NOT EXISTS $default_limit = 100
```

### 3. Binding Table Parameters

Binding table parameters store references to binding tables for use in queries.

**Syntax:**
```gql
SESSION SET [BINDING] TABLE [$param_name] = <binding_table_ref> [IF NOT EXISTS]
```

**Examples:**
```gql
-- Set binding table
SESSION SET BINDING TABLE $my_table = user_bindings

-- Shorthand syntax (BINDING is optional)
SESSION SET TABLE $results = query_results
```

## Session Reset

The `SESSION RESET` command allows you to clear session state, including parameters.

**Syntax:**
```gql
SESSION RESET [ALL] PARAMETERS      -- Reset all parameters
SESSION RESET PARAMETERS             -- Same as ALL PARAMETERS
SESSION RESET PARAMETER $name        -- Reset specific parameter
SESSION RESET GRAPH                  -- Reset current graph
SESSION RESET TIME ZONE              -- Reset time zone
SESSION RESET                        -- Reset all session state
```

**Examples:**
```gql
-- Reset all parameters
SESSION RESET ALL PARAMETERS

-- Reset specific parameter
SESSION SET VALUE $temp = 123
SESSION RESET PARAMETER $temp

-- Reset graph setting
SESSION RESET GRAPH

-- Reset everything
SESSION RESET
```

## Implementation Details

### Parser Changes

The session parameter parsing includes:
- Proper handling of `$` token for parameter names
- Support for integer literal initializers
- Recognition of TABLE keyword as token (not identifier)
- ALL keyword recognized as token
- TIME ZONE multi-word keyword support

**Files Modified:**
- `src/gql/parser.zig`: Functions `parseSessionParameterName`, `parseSessionSetClause`, `parseSessionResetClause`

### Execution Changes

Session parameters are stored in the `SessionState` structure and persisted across query execution within a session.

**Files Modified:**
- `src/execution.zig`: Parameter clause handling stores values in `session.parameters` hashmap

### AST Structures

Session parameters are represented in the AST using these structures:

```zig
pub const SessionParameterName = struct {
    specification: []const u8,  // Parameter name (without $)
    if_not_exists: bool = false,
};

pub const GraphParameterClause = struct {
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null,
};

pub const ValueParameterClause = struct {
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null,
};

pub const BindingTableParameterClause = struct {
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null,
};
```

## Testing

Comprehensive unit tests are available in:
- `geodetestlab/specs/session_parameter_unit_tests.yml`

Test coverage includes:
- All three parameter types (GRAPH, VALUE, BINDING TABLE)
- IF NOT EXISTS conditional setting
- All RESET variants
- Parameter lifecycle management
- Multiple parameter handling

## GQL Compliance

These features implement ISO/IEC 39075:2024 GQL standard session management capabilities:
- SESSION SET GRAPH parameter (§15.3)
- SESSION SET VALUE parameter (§15.3)
- SESSION SET BINDING TABLE parameter (§15.3)
- SESSION RESET commands (§15.4)

## See Also

- [Transaction Management](TRANSACTION_MANAGEMENT.md)
- [GQL Compliance](GQL_COMPLIANCE.md)
- [Implementation Status](IMPLEMENTATION_STATUS_OCTOBER_2025.md)
