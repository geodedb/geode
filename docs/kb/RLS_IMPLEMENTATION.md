# Row-Level Security (RLS) Implementation for Geode

## Overview

This document describes the comprehensive Row-Level Security (RLS) implementation for the Geode graph database, including Users, RBAC (Role-Based Access Control), ABAC (Attribute-Based Access Control), and extensive management capabilities.

## Components Implemented

### 1. User Management (`src/security/auth.zig`)

- **User Creation & Authentication**
  - Secure password hashing (configurable for Argon2id)
  - Email validation
  - Account activation/deactivation
  - Multi-factor authentication (MFA) support
  - Session management with token-based authentication

- **Password Policies**
  - Minimum/maximum length requirements
  - Character complexity requirements (uppercase, lowercase, digits, special)
  - Password history tracking
  - Password age policies

### 2. Role-Based Access Control (RBAC)

- **Roles**
  - System roles (cannot be deleted)
  - Custom roles with descriptions
  - Role hierarchy with inheritance
  - Priority-based role resolution

- **Permissions**
  - Resource-based permissions
  - Action types: create, read, update, delete, execute, grant, revoke, all
  - Conditional permissions with JSON-based conditions
  - Fine-grained resource targeting

- **Authorization**
  - User-role assignments
  - Role-permission grants
  - Hierarchical permission inheritance
  - Superuser bypass

### 3. Attribute-Based Access Control (ABAC)

- **Policy Components**
  - Subject attributes (user properties)
  - Resource attributes
  - Environment conditions (time, IP, location)
  - Effect (allow/deny) with deny precedence

- **Attribute Conditions**
  - Comparison operators: equals, not_equals, contains, greater_than, less_than, in, matches (regex)
  - Dynamic attribute evaluation
  - Context-aware decisions

- **Environment Conditions**
  - Time-based access (business hours, time ranges)
  - IP range restrictions
  - Location-based access
  - Device type restrictions
  - Request rate limiting

### 4. Row-Level Security Engine (`src/security/rls.zig`)

- **Policy Management**
  - Per-table/graph policies
  - Operation-specific policies (SELECT, INSERT, UPDATE, DELETE)
  - Permissive vs Restrictive policies
  - Using clauses for row filtering
  - Check clauses for data validation

- **Advanced Features**
  - Temporal constraints with recurrence rules
  - Data classification levels (public, internal, confidential, restricted, top_secret)
  - Audit levels (none, errors_only, denials, all_access, detailed)
  - Policy caching for performance

- **Query Rewriting**
  - Automatic security predicate injection
  - Context-aware query modification
  - Performance-optimized predicate evaluation

- **Comparisons in policy expressions (SONNY-2709)**

  An expression policy is compiled to bytecode and evaluated for each row.
  It can use `row.<field>`, `principal.attribute.<key>`, `current_user`,
  `TRUE`, `FALSE`, `NULL`, string, integer and decimal literals, the
  operators `=`, `<>` (or `!=`), `<`, `<=`, `>`, `>=`, `IS [NOT] NULL`,
  `NOT`, `AND` and `OR`, and parentheses. Precedence follows SQL, from
  loosest: `OR`, `AND`, `NOT`, then the comparisons. So `NOT row.x = 'a'`
  means `NOT (row.x = 'a')`. The whole expression must parse. If anything is
  left over, or the expression is otherwise malformed, the policy denies
  every row and the engine logs a warning. (Before SONNY-2709, a valid
  prefix was compiled and the rest silently dropped.)

  **Creating a policy is strict (SONNY-2732).** `RLSEngine.createPolicy`
  and `updatePolicy` (the API, procedure and DDL paths) refuse an expression
  that does not compile, with `error.InvalidRlsExpression`, and install
  nothing. The lexer is strict too:
  - a missing `)`, an unterminated string, and an empty `row.` or
    `principal.attribute.` name are errors;
  - a bare name such as `cls` is an error; write `row.cls`.

  Only `RLSEngine.loadPolicy`, for policies read back from storage, keeps a
  policy that no longer compiles. It installs it denying every row, marks it
  `invalid`, and logs a warning, so that a grammar change cannot brick
  startup. The GPS catalog (`CREATE POLICY`) has the same split. SHOW
  POLICIES and `CALL geode.auth.policy_list()` show a policy kept that way
  with `valid = false`, and startup logs how many there are.
  `CALL geode.rls.add_attribute_policy` accepts only identifiers
  (`[A-Za-z_][A-Za-z0-9_]*`) for its row property and attribute key, because
  both are pasted into the policy text.

  **The VM refuses malformed bytecode.** A constant, row or jump index past
  its table, a jump outside the program, or more steps than the program has
  bytes (a loop) all fail the policy, which denies the row.

  Limits (SONNY-2730): an expression may use at most 256 distinct constants.
  Every field name, attribute key and literal is a constant, and a repeated
  one counts once. It may nest `(` and `NOT` at most 64 levels deep. A
  policy past either limit is refused.

  The engine uses SQL's three-valued logic: a comparison is true, false or
  UNKNOWN.

  | Comparison | Result |
  |---|---|
  | `=`, `<>`, `<`, `<=`, `>`, `>=` on two numbers (integer or float, mixed) | compared as numbers |
  | the same on two strings | compared by bytes |
  | the same on two timestamps | compared |
  | `=`, `<>` on two booleans | compared |
  | any comparison with a missing field or `NULL`, a NaN, or two values of different kinds (a string and a number, say), and any range comparison of booleans | UNKNOWN |
  | `principal.attribute.<key>` against a number | the attribute is parsed strictly as that number's type, then compared; UNKNOWN if it does not parse |
  | `x IS NULL`, `x IS NOT NULL` | true or false, never UNKNOWN |

  **Range comparisons on strings are lexicographic.** `<`, `<=`, `>` and
  `>=` on two strings compare bytes, so `'10' < '9'` and `'top' > '3'`. A
  range policy needs numeric row values: a numeric field stored as a string
  compares as text against a string literal or attribute, and is UNKNOWN
  (denied) against a number. Store levels, clearances and other ordered
  values as integers or floats.

  **Only a boolean TRUE admits a row (SONNY-2732).** A policy whose value is
  not a boolean admits nothing. That includes a bare `row.flag` holding the
  string `'no'`, a bare `'anything'`, a number, and `NULL`. `NOT`, `AND` and
  `OR` treat any non-boolean operand as UNKNOWN.

  UNKNOWN never admits a row. `NOT`, `AND` and `OR` follow SQL's
  three-valued logic:
  - `NOT` UNKNOWN is UNKNOWN;
  - `false AND` UNKNOWN is false;
  - `true OR` UNKNOWN is true;
  - every other combination with UNKNOWN is UNKNOWN.

  A policy whose result is UNKNOWN denies the row, as PostgreSQL row
  security does. So `row.level <= 3`, `NOT (row.level > 3)` and
  `row.cls <> 'secret'` all deny a row whose field is missing or of the
  wrong kind. A hand-written bytecode branch (`jump_if_false` or
  `jump_if_true`) on UNKNOWN makes the policy undecided, and the row is
  denied. The compiler emits no branches today.

  **Behaviour change (SONNY-2709).** `=` and `<>` used to treat a missing
  value as unequal: `row.cls <> 'secret'` admitted every row without `cls`.
  Now that comparison is UNKNOWN and the row is hidden. To keep the old
  behaviour, say so explicitly:

  ```text
  row.cls IS NULL OR row.cls <> 'secret'
  ```

  `row.cls = NULL` is UNKNOWN for every row, as in SQL. Use `IS NULL`.

  A principal attribute is stored as a string. Compared with an integer
  field, it must be an optional `-` followed by ASCII digits, within the
  64-bit range (`"3"`, `"-1"`). Compared with a float field, it may also have
  a `.` and at least one fraction digit (`"2.5"`). Anything else is not a
  number, and the comparison is UNKNOWN: for example `" 3"`, `"+3"`, `"3.0"`
  (against an integer), `"1e3"`, `"0x3"` or `"inf"`. A user without the
  attribute gets UNKNOWN too. Compared with a string field, the attribute is
  compared as a string. The same rules apply to `=` and `<>`, so
  `row.level = principal.attribute.clearance` matches an integer `level` of
  3 for a clearance of `"3"`. Only a principal attribute is converted: a
  row's string field is never read as a number.

- **MERGE and rows a policy hides (SONNY-2686, SONNY-2728)**

  MERGE matches its pattern against existing rows before it creates one.
  When the only rows that match are rows the session's RLS policies hide (a
  node, or an edge whose type a label-deny policy denies or whose own
  properties an expression policy denies), the statement is refused with
  `MergeMatchNotVisible`, SQLSTATE 42501. Nothing is bound, updated or
  created: a pre-pass refuses the statement before its first write. A
  visible match is used wherever it sits, even when hidden rows match too.
  A row in another tenant or another graph is simply absent, as before, and
  MERGE creates the session's own.

  **The refusal is a covert channel.** It tells the session that some row
  it may not see equals the pattern. Because MERGE can match on any
  property, it works as an equality oracle over any property value:
  `MERGE (x:Employee {name: 'Ann', salary: 250000})` is refused when Ann's
  hidden row has that salary, and a wrong guess creates a new node.
  PostgreSQL has the same channel in a narrower form: when the row an
  `INSERT … ON CONFLICT DO UPDATE` conflicts with fails the UPDATE policy's
  USING clause, the update "will never be silently avoided; an error will be
  thrown instead", and its documentation lists unique-key and foreign-key
  checks among the accepted covert channels. There the channel reaches only
  the conflict key; in Geode it reaches every property a MERGE pattern
  names.

  **Why the hidden row is not treated as absent.** Treating it as absent is
  worse. MERGE promises one row per pattern, and the merge index keeps one id
  per key, so a duplicate breaks every later MERGE on that key, which can
  bind either copy. An attacker could plant a visible duplicate of a hidden
  row, and the owner's next `MERGE … ON MATCH SET` could then update the
  attacker's copy instead of the real row, while the owner sees both.
  Binding the hidden row is the leak itself: RETURN reads it, and ON MATCH
  SET rewrites it (under an expression policy, possibly into view).

  **Every refusal is audited.** Each `MergeMatchNotVisible` writes an
  `access_denied` record to the security audit log, with action
  `MERGE_MATCH_NOT_VISIBLE`, result `failure`, the user, and the statement's
  graph. Its details give the pattern's labels (or relationship types) and
  its property keys. Property values are never recorded, because they are
  the secret being guessed. A burst of these records from one user is the
  signature of enumeration. The engine has no per-session rate limit for
  refusals yet.

### 5. User Management CLI (`src/tools/user_auth.zig`)

- **User Commands**
  - `user create <username> <email> <password>` - Create new user
  - `user delete <username>` - Delete user
  - `user list` - List all users
  - `user show <username>` - Show user details
  - `user enable/disable <username>` - Enable/disable user
  - `user password <username> <new_password>` - Change password

- **Role Commands**
  - `role create <name> <description>` - Create role
  - `role delete <name>` - Delete role
  - `role list` - List all roles
  - `role show <name>` - Show role details

- **Policy Commands**
  - `policy create <name> <table> <operation>` - Create RLS policy
  - `policy delete <name>` - Delete policy
  - `policy list [table]` - List policies
  - `policy enable/disable <name>` - Enable/disable policy

- **Grant/Revoke Commands**
  - `grant role <role> to <user>` - Grant role to user
  - `grant permission <permission> to <role>` - Grant permission to role
  - `revoke role <role> from <user>` - Revoke role from user
  - `revoke permission <permission> from <role>` - Revoke permission from role

### 6. Audit Logging

- **Event Types**
  - User lifecycle events (created, updated, deleted)
  - Authentication events (login success/failure, logout)
  - Authorization events (role/permission changes)
  - Policy events (creation, modification, deletion)
  - Access events (granted, denied)

- **Audit Entry Structure**
  - Timestamp
  - Event type
  - User ID
  - Detailed description
  - Context information

## Security Features

### Multi-Tenant Isolation

- Tenant-specific policies
- Complete data isolation between tenants
- Shared-nothing architecture support
- Per-tenant role hierarchies

### Performance Optimizations

- **Policy Caching**
  - LRU cache with configurable size
  - TTL-based expiration
  - Automatic invalidation on policy changes

- **Expression Compilation**
  - Bytecode compilation for frequently used expressions
  - JIT-style optimization for hot paths
  - Constant folding and dead code elimination

### Integration Points

- **Storage Backend**
  - Persistent user/role/permission storage
  - Policy persistence
  - Audit log storage

- **Query Engine**
  - Transparent query rewriting
  - Security predicate pushdown
  - Index-aware filtering

- **Transaction Manager**
  - Row-level locking integration
  - MVCC visibility checks
  - Conflict detection with security context

## Usage Examples

### Creating a User with Roles

```bash
# Create a user
geode-auth user create alice alice@example.com SecurePass123!

# Create a role
geode-auth role create analyst "Data analyst with read access"

# Grant role to user
geode-auth grant role analyst to alice
```

### Setting Up RLS Policies

```zig
// Create a policy for user data isolation
const policy = RLSEngine.Policy{
    .name = "user_own_data",
    .description = "Users can only see their own data",
    .table = "user_profiles",
    .operation = .select,
    .using_expr = Expression{
        .raw = "owner_id = current_user()",
    },
    .roles = &[_]RoleId{user_role_id},
    .enabled = true,
};

try rls_engine.createPolicy(policy);
```

### ABAC Policy Example

```zig
const policy = ABACPolicy{
    .name = "time_restricted_access",
    .effect = .allow,
    .subjects = &[_]AttributeCondition{
        .{ .attribute = "department", .operator = .equals, .value = .{ .string = "finance" } },
    },
    .resources = &[_]AttributeCondition{
        .{ .attribute = "classification", .operator = .equals, .value = .{ .string = "financial" } },
    },
    .conditions = &[_]EnvironmentCondition{
        .{ .type = .time_range, .parameters = .{ .object = ... } },
    },
};
```

## Testing

Comprehensive test coverage is provided in `tests/e2e_rls_security.zig`:

- User creation and authentication
- RBAC role and permission management
- ABAC policy evaluation
- RLS policy application
- Temporal constraints
- Password policy enforcement
- Session management
- Audit logging
- Multi-tenant isolation
- Performance testing with policy cache

## Build and Run

```bash
# Build the project
zig build

# Run tests
zig build test

# Run the user management CLI
./zig-out/bin/geode-auth --help

# Test RLS implementation
zig build-exe src/test_rls.zig && ./test_rls
```

## Future Enhancements

1. **OAuth2/OIDC Integration**
   - External identity provider support
   - JWT token validation
   - SAML support

2. **Advanced RLS Features**
   - Row-level encryption
   - Dynamic data masking
   - Column-level security

3. **Performance Improvements**
   - Parallel policy evaluation
   - Distributed policy cache
   - Query plan caching with security context

4. **Compliance Features**
   - GDPR compliance tools
   - Data retention policies
   - Right to be forgotten implementation

## Conclusion

The Row-Level Security implementation for Geode provides a comprehensive, performant, and flexible security framework that supports:

- Fine-grained access control at the row level
- Multiple authorization models (RBAC and ABAC)
- Multi-tenant data isolation
- Comprehensive audit logging
- Performance optimization through caching
- Easy management through CLI tools

This implementation ensures that users only see data they are authorized to access, maintaining data privacy and security in multi-user and multi-tenant environments.
