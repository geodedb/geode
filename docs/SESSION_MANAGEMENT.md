# Session Management in Geode

This document describes the session management features in Geode, including session parameters and transaction handling.

A GQL session lives exactly as long as its connection. geode servers have
no session tokens: a connection authenticates with a user name and
password in its HELLO, no server keeps the session ids it issues, and a
session cannot be resumed, validated, rotated or invalidated from another
connection. The CLI's `geode session validate|rotate|invalidate-all|check-idle`
and `geode auth validate` are refused as not supported by this server
(SONNY-6554; docs/USER_AUTH.md, "Session and API-key commands").

## The session graph

A session's graph is the graph its statements read and write. Every session
starts on the graph its connection names, or on `default`. These statements
move it, and they all go through the same checks (SONNY-2775):

```gql
USE GRAPH hr
SESSION SET GRAPH hr
SESSION SET PROPERTY GRAPH hr
SESSION RESET              -- also SESSION RESET GRAPH, SESSION RESET ALL CHARACTERISTICS
SESSION CLOSE
```

- **Permission:** the user must be allowed to bind the graph (`bind_graph`:
  Admin, a grant on the graph, or ReadWrite in a single-tenant deployment).
  Anyone may bind `default`. A refusal is `42501`.
- **Existence:** the graph must exist, or the statement fails with `3F000`.
  A statement never creates a graph.
- **Internal graphs:** the engine's own graphs (`__geode_security` and every
  `__geode_*` name) cannot be selected, created or dropped, by anyone
  (`42501`), and a HELLO cannot bind one (SONNY-2791).
- **A connection bound to a graph** (the graph in its connection string) stays
  on it: naming another graph fails, and `SESSION RESET` and `SESSION CLOSE`
  keep it.
- `CURRENT_GRAPH` and `CURRENT_PROPERTY_GRAPH` name the session's graph (no
  change). `HOME_GRAPH` and `HOME_PROPERTY_GRAPH` name where `SESSION RESET`
  goes: the connection's graph, or `default`.

A statement that fails changes nothing, and the session keeps its graph.

A transaction changes one graph (SONNY-2776). Once it has changed a graph, a
request in it that changes another is refused with `0A000`. Reading other
graphs is fine. Commit or roll back before changing another graph.

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
