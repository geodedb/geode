# Geode User Authentication System

🔐 **Complete Configurable Authentication & Security Framework**

## Overview

Geode implements a comprehensive authentication system with post-quantum ready security features, configurable policies, and enterprise-grade password requirements. All users follow the same high security standards with extensive environment-based customization.

### Supported / Not Supported Mechanisms

**Supported today:**

- Password-based authentication (Argon2id, RFC 9106)
- Multi-factor authentication (TOTP)
- mTLS client-certificate requirement (a transport gate: the client then
  still authenticates with a user name and password)
- Role-based access control (RBAC)
- Row-level security (RLS, single-tenant)

**Not supported by the server (SONNY-6554; the CLI refuses the commands
that claimed them, see "Session and API-key commands" below):**

- Session tokens: the QUIC HELLO carries a user name and a password only,
  and no server keeps the session ids it issues, so a session can be
  neither reused, validated, rotated nor invalidated
- API keys (see "API Key Authentication" below)

**Not supported (no implementation in `src/security/`):**

- LDAP / Active Directory — see issue [#802](https://gitlab.com/devnw/codepros/geode/geode/-/issues/802) (GAP-0834). Will be implemented when a customer requires it.
- OAuth2 / OIDC — see issue [#803](https://gitlab.com/devnw/codepros/geode/geode/-/issues/803) (GAP-0835). Will be implemented when a customer requires it.

For enterprise SSO requirements today, require mTLS client certificates from your PKI infrastructure in addition to user passwords.

## 1. Default User Configuration

### Basic Setup

- **Default Username**: `geode` (configurable)
- **Default Password**: generated unless `GEODE_ADMIN_PASSWORD` or
  `GEODE_DEFAULT_PASSWORD` is set: a random passphrase that meets the
  password policy (section 2), words of eight characters, with a reset forced
  at first login. There is no fixed default password.
- **Privileges**: Full superuser access
- **Auto-Creation**: Created automatically on first system initialization

### The generated admin password (SONNY-2778)

When the first boot (`geode serve`, or `geode auth init`) generates the admin
password, it is written once to a file in the data directory:

```
<data-dir>/.geode_admin_password
```

`<data-dir>` is the directory the command runs on: `geode serve
--data-dir`, `geode auth init --data-dir`, or `GEODE_DATA_DIR`. With neither,
`geode auth init` (like every offline `geode auth`, `geode user` and `geode
role` command, SONNY-6345) uses the directory `geode serve` uses:
`$XDG_STATE_HOME/geode`, else `~/.local/state/geode`, else
`/tmp/geode-<uid>`. It used to default to `/var/lib/geode`, a different
store than the server's.

`geode auth verify` on a directory with no `__geode_security` graph (or no
store at all) reports that there is no auth state and exits 1, creating
nothing; it used to create the security graph and report `0 records,
integrity OK` (SONNY-6345).

On a store with auth state `geode auth verify` seals and saves nothing
(SONNY-6359). It still takes the data-directory lock and opens the store, and
opening the store writes: the storage engine checkpoints and truncates each
graph's WAL, rewrites the graph registry and the timeseries WAL, and records
the lock holder in `.geode.lock`. There is no read-only open of the store yet;
run it with the server stopped, as it refuses a locked directory.

- The file is created with `O_CREAT | O_EXCL | O_NOFOLLOW` and mode 0600, set
  again after the open, so the umask cannot widen it.
- It is never written through a symbolic link, never over an existing file,
  and never into the current working directory.
- If anything is already at that path (a file left from an earlier
  bootstrap, or a symbolic link), nothing is written:
  - `geode auth init` refuses before it creates the admin. Read and remove
    the file (or set `GEODE_ADMIN_PASSWORD`), then run it again.
  - A first-booting server creates the admin but does not write its
    password, and logs `[startup] generated initial admin password NOT
    written …`. Set the admin password with `geode user reset-password`.
- With no data directory, no file is written. For a server started without
  one, set `GEODE_ADMIN_PASSWORD` or `GEODE_DEFAULT_PASSWORD`; for the legacy
  in-memory security manager without `GEODE_DATA_DIR`, set
  `GEODE_DEFAULT_PASSWORD`.
- The server data directory itself is kept at mode 0700 or stricter before
  the file is written (issue #819).

**Retrieve** the password once, as the user that runs the server, then delete
the file:

```bash
cat /var/lib/geode/.geode_admin_password && rm /var/lib/geode/.geode_admin_password
```

**Rotate** it right after the first login. Either:

- over the wire, as the admin: `ALTER USER geode SET PASSWORD '...'`; or
- offline, with the server stopped:
  `geode user reset-password geode --new-password '...' --data-dir <data-dir>`.
  This verifies the security graph's HMAC chain first (SONNY-2798).

An offline `geode user` or `geode role` change on a store with no auth
records yet (nothing to verify) is sealed with the key the server would use
there: `GEODE_AUTH_HMAC_KEY`, else `GEODE_TDE_KEY`, else
`<data-dir>/.geode_hmac_key`, which is generated, as at the server's first
start, when there is none. It used to be left unsealed, and the server then
refused to start (SONNY-6358). Set the same key variables for the offline
command as for `geode serve`.

The file is not read again after bootstrap; deleting it changes nothing.

### Users with no stored role (fail-closed default, 2026-10)

A user whose record carries no built-in role (not a superuser, no `admin`,
`user`, `readwrite` or `readonly` role) gets **no access** by default: no
global read or write, no admin, and no access to any graph, the `default`
graph included, except the graphs it holds a per-graph grant on, where it
gets that grant's privileges. Before 2026-10 such a user fell back to
`readwrite` (fail-open). The bootstrap admin above and users with an
assigned role are unaffected. See
[GQL_AUTH_DDL.md](GQL_AUTH_DDL.md#users-with-no-stored-role-fail-closed-default).

The offline `geode user create | import | update --role <role>` and `geode
user assign-role <user> <role>` give the user a built-in role (`admin`,
`readwrite`, `user`, `readonly`) as `ALTER USER ... SET ROLE` does: its other
built-in role is replaced. `create` and `import` with no `--role` give
`user`, as `CREATE USER` does. Any other role name is refused before
anything is changed (a custom role carries no privileges), as is
`assign-role` of a user that does not exist. Until SONNY-6367 these
commands stored a role node, never gave it to the user, and reported
success, so the user had no role. A user created offline before that holds
no role: give it one. `geode user list` and `geode user show` print the
role the server resolves at login (they printed `user` for everyone), and
`geode user show | enable | disable` of a user that does not exist fail.
`geode role create` stores the role under a new role id (it took the next
user id, which could overwrite an existing role and move its users to the
new name).

### Environment Configuration

```bash
# Configure default admin username
export GEODE_ADMIN_USERNAME="database_admin"        # Default: "geode"

# Configure default admin password  
export GEODE_DEFAULT_PASSWORD="My Super Secure Admin Passphrase 2024"
```

### Supported Admin Username Examples

```bash
# Production environments
export GEODE_ADMIN_USERNAME="prod_admin"
export GEODE_ADMIN_USERNAME="sysadmin"
export GEODE_ADMIN_USERNAME="database_operator"

# Development environments
export GEODE_ADMIN_USERNAME="dev_admin"
export GEODE_ADMIN_USERNAME="test_user"
```

## 2. Unified Password Policy (All Users)

### Security Requirements

**Every user in the system must meet these standards:**

- ✅ **Minimum Length**: 20+ characters (configurable, absolute minimum: 20)
- ✅ **Passphrase Format**: 3+ words required (configurable, absolute minimum: 2)
- ✅ **Case Requirements**: Must contain both uppercase and lowercase letters
- ✅ **Character Support**: Spaces, numbers, and symbols allowed
- ✅ **No Exceptions**: Admin and regular users follow identical standards

### Where It Applies (SONNY-6331)

One policy (`PasswordPolicy.geodeSecure()`), on every path that sets a
password:

- `CREATE USER ... SET PASSWORD` and `CALL geode.auth.user_create(...)`
- `ALTER USER ... SET PASSWORD` (the transport's own-password intercept and
  the GQL route), `CALL geode.auth.user_reset_password(...)` and
  `CALL geode.auth.user_change_password(...)`
- the forced reset at first login
- the offline `geode user create | update | change-password | reset-password`
- the first-boot admin: a generated password meets the policy; a
  `GEODE_ADMIN_PASSWORD` / `GEODE_DEFAULT_PASSWORD` seed that does not is
  accepted with a forced reset (section 3)

A password the policy refuses is an error, SQLSTATE `22000` on the server,
whose message names the first rule it breaks with the configured limit, for
example `Password too short (minimum 25 characters)` or `Password must be a
passphrase with at least 4 words`. The message never contains the password.
Words are separated by spaces. `GEODE_PASSWORD_MIN_LENGTH` above 256 (the
longest password accepted) is read as 256.

Passwords stored before the policy applied to a path (for example a user
created with an 8-character password by an older server) keep working: the
policy is checked when a password is set, not at login. The user is held to
it at the next password change.

### Policy Configuration

```bash
# Password length (minimum 20 enforced)
export GEODE_PASSWORD_MIN_LENGTH=25        # Default: 20

# Word count (minimum 2 enforced)  
export GEODE_PASSWORD_MIN_WORDS=4          # Default: 3
```

### Configuration Examples

```bash
# High security environment
export GEODE_PASSWORD_MIN_LENGTH=35
export GEODE_PASSWORD_MIN_WORDS=6

# Moderate security (cannot go below minimums)
export GEODE_PASSWORD_MIN_LENGTH=22
export GEODE_PASSWORD_MIN_WORDS=3

# Invalid (will use minimums instead)
export GEODE_PASSWORD_MIN_LENGTH=15        # Becomes 20
export GEODE_PASSWORD_MIN_WORDS=1          # Becomes 2
```

## 3. Forced Password Reset System

### Reset Triggers

Password reset is **automatically required** when:

- ✅ The first-boot admin password was generated
- ✅ The first-boot `GEODE_ADMIN_PASSWORD` / `GEODE_DEFAULT_PASSWORD` seed
  does not meet the password policy (shorter than the configured minimum, no
  upper or no lower case letter, or fewer words than required)

### Reset Flow Process

1. **Authentication Succeeds**: User identity verified
2. **Policy Check**: Password evaluated against current policy
3. **Reset Prompt**: Clear explanation of requirements shown
4. **New Password Entry**: Secure input with confirmation
5. **Real-time Validation**: Immediate feedback on policy compliance
6. **Session Termination**: Forced logout requiring re-authentication

### Reset Experience

```
Authentication successful, but a password reset is required.
Your current password does not meet the security policy:
  - Minimum 25 characters
  - Must be a passphrase (4 or more words)
  - Must contain uppercase and lowercase letters
  - Spaces, numbers, and symbols are allowed

You must set a new password before accessing the database.

New password: [Type secure passphrase here]
Confirm password: [Retype to confirm]
```

## 4. CLI Authentication Commands

### Login Command

```bash
# Basic login (uses default server)
geode auth login --user <username>

# Specify custom server
geode auth login --user <username> --server <host:port>

# With password file
geode auth login --user <username> --password-file /path/to/password

# With environment-configured admin
geode auth login --user $GEODE_ADMIN_USERNAME
```

### Login Options

| Option | Description | Example |
|--------|-------------|---------|
| `--user`, `-U` | Username to authenticate | `--user admin` |
| `--server` | Server address | `--server prod.geode.com:3141` |
| `--password` | Password (not recommended) | `--password "secret"` |
| `--password-file` | Read password from file | `--password-file /dev/stdin` |

### Logout Command

```bash
# Remove the local saved session file (~/.geode/credentials.json)
geode auth logout
```

`auth logout` removes a local file and nothing else: no server keeps a
session to end. It prints `Removed the local saved session file ...` (or
`No saved session file to remove`); it used to print `Successfully logged
out`. `auth logout --token <t>` is refused (exit 2): no token can be
invalidated (SONNY-6554).

### Authentication Flow Examples

**Standard Login:**

```bash
$ geode auth login --user geode
Username: geode
Password: [hidden input]
Successfully authenticated as 'geode' on server '127.0.0.1:3141'
Saved a record of this login to the local file ~/.geode/credentials.json. geode servers do not accept session tokens yet, so it does not log later commands in; pass -U and --password (or --dsn) to each command
```

`auth login` checks the user name and password against the server
(a real HELLO). Without `--save-session` it prints `Note: geode servers do
not accept session tokens yet, ...`; it used to print the server's session
id as a reusable `Session token: ...` with `Use --save-session to persist
credentials locally` (SONNY-6554).

**Password Reset Required:**

```bash
$ geode auth login --user prod_admin  
Username: prod_admin
Password: [weak_password]
Authentication successful, but a password reset is required.
[Policy explanation and reset flow]
```

## 5. Complete Environment Configuration

### All Available Variables

```bash
# === User Configuration ===
export GEODE_ADMIN_USERNAME="database_admin"        # Default: "geode"
export GEODE_DEFAULT_PASSWORD="Secure Admin Passphrase Goes Here 2024"

# === Password Policy ===
export GEODE_PASSWORD_MIN_LENGTH=25                 # Default: 20, Min: 20
export GEODE_PASSWORD_MIN_WORDS=4                   # Default: 3, Min: 2

# === Server Configuration ===
export GEODE_SERVER_HOST="prod.geode.com"          # Default: "127.0.0.1"
export GEODE_SERVER_PORT="3141"                    # Default: "3141"

# === Brute-Force Lockout (see "Brute-Force Lockout" below) ===
export GEODE_AUTH_RATE_MAX_ATTEMPTS=10             # Default: 10
export GEODE_AUTH_RATE_LOCKOUT_SECS=60             # Default: 60, range 1-86400
```

## 6. Security Implementation

### Enhanced Password Validation

- **Pre-Hash Validation**: Passwords checked against policy before hashing
- **Post-Auth Validation**: Authenticated passwords re-checked against current policy
- **Policy Enforcement**: Non-bypassable requirement for policy compliance
- **Dynamic Updates**: Policy changes immediately affect all users

### Password Hashing

- **Current**: Argon2id with OWASP parameters (`m=19456,t=2,p=1`), stored
  as a PHC string (`$argon2id$v=19$...`) by every path that sets a password:
  CREATE USER, ALTER USER SET PASSWORD, the `geode.auth.*` procedures, the
  first-boot admin, and the offline `geode user create | update | change-password | reset-password`
  (`geode_auth.hashPasswordArgon2id`). The offline `geode user create` and
  `geode user update --password` stored the password itself until
  SONNY-6358; such a record cannot log in: set its password again.
- **Stored hash bounds**: a stored hash with other parameters still
  verifies, within 1 <= t <= 10, 8*p <= m <= 262144 KiB (256 MiB) and
  1 <= p <= 16; outside them, or unparseable, verification fails without
  running Argon2, so a corrupt stored hash cannot burn CPU or memory on
  every login (SONNY-6378)
- **Legacy**: an imported BLAKE2b hash (`geode user import --algorithm blake2b`,
  `geode.auth.user_import(..., 'blake2b')`) is accepted for migration only:
  64 hex digits of BLAKE2b-256 over the password followed by the static salt
  `geode-salt-secure-v2`. The login verifies it (SONNY-6367; such a user
  could not log in before). It is a fast hash with a fixed salt, far weaker
  than Argon2id: have the user change its password (`ALTER USER <user> SET
  PASSWORD`), which stores an Argon2id hash. FIPS builds refuse the import
  and the verification.
- **FIPS builds**: Argon2id is not FIPS-approved, so setting a password fails
  closed (`FipsUnsupported`).
- **Validation**: All passwords validated before hashing

### Session Management

- **Duration**: 24-hour expiration
- **Storage**: `~/.geode/credentials.json` (user home directory). HOME
  (USERPROFILE on Windows when HOME is unset) must be an absolute path: a
  relative or empty HOME is refused with `Error: HOME is empty or not an
  absolute path ...`, never resolved against the working directory
  (SONNY-6544). (The CLI state files of `geode session`, `authn` and
  `apikey` are no longer written: those commands are refused, SONNY-6554.)
- **Format**: the session id a server returns in HELLO is a random token;
  the server keeps no record of it, so it is not reusable
- **Cross-platform**: Windows and Unix support
- **No server-side session state**: no session is invalidated, rotated or
  expired by a server; every connection authenticates in its own HELLO

### Saved sessions (`--save-session`)

`geode auth login --save-session` writes, and `geode query`, `geode auth
token`, `geode session info` read, one file through one writer and
one reader (`src/cli/security/session_storage.zig`, SONNY-6551):

```json
{"version":1,"server":"127.0.0.1:3141","username":"alice","token":"...","created_at":1763100000,"expires_at":1763186400,"system_fingerprint":"host:alice:1000"}
```

- **Encoding**: std.json, every string escaped. A file with a missing,
  extra or mistyped field is not read. Files written before SONNY-6551 (the
  `session_token` key, no fingerprint) are not read and not migrated:
  `geode query` says `Warning: saved session ignored: ...`; run `geode auth
  login --save-session` again.
- **Times**: `created_at` / `expires_at` are Unix seconds; a session is
  offered for 24 hours.
- **`system_fingerprint`** (`hostname:USER:uid`) binds the file to the OS
  account and host that saved it, so a file that travelled (a copied or
  restored home directory, an NFS home shared between hosts) is ignored
  with a warning. It is not a secret and not authentication.
- **Server**: a session is offered only to the `--server` (or `--dsn`)
  address it was saved for, compared as written (`localhost:3141` is not
  `127.0.0.1:3141`).
- **Writing**: `~/.geode` is created mode 0700, opened without following a
  symbolic link, and must belong to you; group or other access on an
  existing one (an older geode created it 0755) is removed. The file is
  written to a new temporary file (mode 0600, `O_EXCL`) in that directory
  and renamed over `credentials.json`, so a reader sees the old file or the
  new one and a symbolic link at the final path is replaced, never
  followed.
- **Reading** creates nothing. The file is ignored, with the reason, when
  `~/.geode` is a symbolic link, not yours, or writable by group or other,
  or when `credentials.json` is a symbolic link, not a regular file, not
  yours, accessible by group or other (as ssh treats a private key), over
  16 KiB, not the format above, saved by another account or host, or
  expired. A token is never printed by `geode query`.
- **Not yet usable for authentication.** The QUIC HELLO carries a user name
  and a password only, and the server keeps no record of the session ids
  it returns, so a saved session cannot authenticate a query. When `geode
  query` (no `-U` or `--dsn` credentials) finds a valid one for
  its server it prints `Note: found a saved session for <server> (user
  '<name>'), but geode servers do not accept a saved session token yet, so
  it is not used; ...` and sends nothing from it; pass `-U` with
  `--password` / `--password-file`, or `--dsn`. Server-side session
  resumption (a token field in the HELLO, a server registry of issued
  tokens with expiry and revocation on password or role change) is open
  work (SONNY-6551, SONNY-6553).

### Session and API-key commands (SONNY-6554)

These commands claimed a server-side effect that no server performs. Each
now exits 1 with `Error: ... is not supported by this server: <what>` and
writes nothing:

| Command | It printed | It did |
|---------|------------|--------|
| `geode session validate [--token t]` | `Session is valid for user: ...` for any 32+ character string | read a local state file no one writes |
| `geode session rotate` | `Session token rotated successfully.` | replaced the saved token with random bytes made on the client |
| `geode session invalidate-all --user u` | `All sessions for user 'u' have been invalidated.` | nothing |
| `geode session check-idle` | `Session is active.` | checked that a saved file exists |
| `geode auth validate --token t` | `Session token valid` for any non-empty string | nothing |
| `geode authn config / test-access` | `anonymous access allowed for path`, `Access allowed` | wrote / read a local file no server reads |
| `geode authn stepup-check` | `Step-up ... required` from an `admin:` prefix | nothing (the server decides step-up per statement, GAP-0884) |
| `geode authn stepup-mark` | `Session elevated successfully.` | nothing |
| `geode apikey create / list / revoke / revoke-all / check-scope` | `API key created`, `revoked`, `scope granted` | kept keys in a local file no server reads |

`geode query --token <t>` (parsed and never sent) and `geode auth logout
--token <t>` are refused with exit 2. What still works, locally:
`geode session info` and `geode auth token` show the saved session file,
`geode auth logout` removes it, and `geode apikey validate` checks a key's
format (and says that no server accepts API keys).

### Audit Trail (CANARY Tracking)

- `REQ-AUTH-POLICY-001`: Password Reset Tracking
- `REQ-AUTH-POLICY-002`: Enhanced Password Policy  
- `REQ-AUTH-POLICY-003`: Passphrase Validation
- `REQ-AUTH-POLICY-004`: Unified Password Policy
- `REQ-AUTH-POLICY-005`: Password Policy Validation Before Hashing
- `REQ-AUTH-POLICY-006`: Post-Authentication Policy Check
- `REQ-AUTH-POLICY-007`: Mandatory Password Policy Enforcement
- `REQ-AUTH-POLICY-008`: Pre-Hash Password Validation
- `REQ-AUTH-POLICY-009`: Password Update Policy Validation
- `REQ-AUTH-POLICY-010`: CLI Password Policy Validation
- `REQ-AUTH-POLICY-011`: Pre-Authentication Policy Check
- `REQ-AUTH-DEFAULT-001`: Default User Creation
- `REQ-AUTH-CONFIG-001`: Configurable Password Policy

## 7. Complete Usage Examples

### Example 1: Production Environment Setup

```bash
# Configure production admin
export GEODE_ADMIN_USERNAME="prod_db_admin"
export GEODE_DEFAULT_PASSWORD="Production Database Administrative Access Phrase 2024"
export GEODE_PASSWORD_MIN_LENGTH=30
export GEODE_PASSWORD_MIN_WORDS=5

# First login (secure password meets policy)
$ geode auth login --user prod_db_admin
Password: [Production Database Administrative Access Phrase 2024]
Successfully authenticated as 'prod_db_admin' on server '127.0.0.1:3141'
Saved a record of this login to the local file ~/.geode/credentials.json. geode servers do not accept session tokens yet, ...
```

### Example 2: Development Environment (Requires Reset)

```bash
# Configure dev admin with weak password
export GEODE_ADMIN_USERNAME="dev_admin"
export GEODE_DEFAULT_PASSWORD="dev123"

# Login triggers reset
$ geode auth login --user dev_admin
Password: [dev123]
Authentication successful, but a password reset is required.
Your current password does not meet the security policy:
  - Minimum 20 characters
  - Must be a passphrase (3 or more words)
  - Must contain uppercase and lowercase letters
  - Spaces, numbers, and symbols are allowed

You must set a new password before accessing the database.

New password: [Development Environment Secure Access Phrase 2024]
Confirm password: [Development Environment Secure Access Phrase 2024]
Password updated successfully.
You can now log in with your new password.
```

### Example 3: High Security Environment

```bash
# Maximum security configuration
export GEODE_ADMIN_USERNAME="security_officer"
export GEODE_PASSWORD_MIN_LENGTH=40
export GEODE_PASSWORD_MIN_WORDS=6

# All users now require 40+ character passphrases with 6+ words
$ geode auth login --user security_officer
Username: security_officer
Password: [Ultra Secure Database Administrative Access Control Passphrase With Extended Length Requirements 2024]
Successfully authenticated as 'security_officer' on server '127.0.0.1:3141'
```

### Example 4: Custom Server Configuration

```bash
export GEODE_ADMIN_USERNAME="cluster_admin"
export GEODE_DEFAULT_PASSWORD="Distributed Database Cluster Administrative Passphrase 2024"

$ geode auth login --user cluster_admin --server cluster-01.geode.internal:3141
Password: [Distributed Database Cluster Administrative Passphrase 2024]
Successfully authenticated as 'cluster_admin' on server 'cluster-01.geode.internal:3141'
```

## 8. Security Features & Benefits

### Mandatory Policy Enforcement

- **One Policy on Every Path**: every path that sets a password applies the
  same policy before hashing (section 2)
- **Set-Time Enforcement**: the policy is checked when a password is set. A
  stored password that predates it (or a stricter configured limit) keeps
  working until it is next changed; it does not force a reset at login

### Post-Quantum Readiness

- **High Computational Cost**: 20+ character passphrases with multiple words
- **Resistance**: GPU-based attacks, side-channel attacks, time-memory trade-offs
- **Future-Proof**: Computational requirements scale against quantum threats
- **Policy-Enforced**: Quantum resistance enforced through mandatory policy compliance

### Enterprise Security

- **Unified Standards**: No weak password exceptions for any user
- **Environment Flexibility**: Different security levels per deployment
- **Audit Compliance**: Comprehensive logging and policy enforcement
- **Zero Trust**: Every authentication attempt validated against current policy
- **Immediate Compliance**: Policy updates require immediate user compliance

### Operational Benefits  

- **Easy Deployment**: Environment variable configuration
- **Flexible Identity**: Customizable admin usernames for different environments
- **User Friendly**: Clear error messages and guided password reset
- **Cross-Platform**: Consistent behavior across Windows and Unix systems

## 9. Troubleshooting

### Common Issues

**Issue**: Login fails with "Invalid username or password"

```bash
# Check configured admin username
echo $GEODE_ADMIN_USERNAME  # Should match login username

# Verify password matches environment
echo $GEODE_DEFAULT_PASSWORD  # Should match login password
```

**Issue**: Password reset required unexpectedly  

```bash
# Check current policy requirements
echo "Min Length: $GEODE_PASSWORD_MIN_LENGTH (default: 20)"
echo "Min Words: $GEODE_PASSWORD_MIN_WORDS (default: 3)"

# Verify password meets all requirements:
# - Length >= configured minimum
# - Word count >= configured minimum  
# - Contains uppercase and lowercase
```

**Issue**: Password reset required after policy update

```bash
# This is normal behavior - policy enforcement is mandatory
# Check what changed in the policy:
echo "Current Min Length: $GEODE_PASSWORD_MIN_LENGTH"
echo "Current Min Words: $GEODE_PASSWORD_MIN_WORDS"

# Policy violations are non-bypassable
# Users must update passwords to meet current requirements
```

**Issue**: "Password does not meet security requirements" during login

```bash
# This indicates pre-authentication policy validation failed
# Check your password against current policy:
# - Minimum length requirement
# - Uppercase and lowercase requirement
# - Passphrase word count requirement

# Update password to meet current policy standards
```

**Issue**: Cannot save credentials

```bash
# Ensure home directory is writable
ls -la ~/.geode/

# geode tightens ~/.geode to 0700 itself on save; it refuses a ~/.geode
# that is a symbolic link or belongs to another user
chmod 700 ~/.geode/
chmod 600 ~/.geode/credentials.json
```

### Password Policy Validation

Test your password against the policy:

```bash
# Example password check (manual verification)
PASSWORD="My Test Database Passphrase 2024"
echo "Length: ${#PASSWORD} (need: $GEODE_PASSWORD_MIN_LENGTH)"
echo "Words: $(echo $PASSWORD | wc -w) (need: $GEODE_PASSWORD_MIN_WORDS)"
echo "Has uppercase: $(echo $PASSWORD | grep -q '[A-Z]' && echo 'Yes' || echo 'No')"
echo "Has lowercase: $(echo $PASSWORD | grep -q '[a-z]' && echo 'Yes' || echo 'No')"
```

## 10. Migration & Compatibility

### Upgrading from Previous Versions

- **Backward Compatibility**: Existing `geode` username continues to work
- **Automatic Migration**: Default user created on first startup
- **Policy Enforcement**: All existing users subject to new password requirements
- **Sessions**: no server keeps sessions, so there are none to preserve; every connection authenticates in HELLO

### Environment Migration

```bash
# Old configuration (still works)
export GEODE_DEFAULT_PASSWORD="secure_password"

# New enhanced configuration
export GEODE_ADMIN_USERNAME="production_admin"
export GEODE_DEFAULT_PASSWORD="Production Database Administrative Access Phrase 2024"
export GEODE_PASSWORD_MIN_LENGTH=25
export GEODE_PASSWORD_MIN_WORDS=4
```

This authentication system provides **enterprise-grade security** with **complete configurability** while maintaining **user-friendly operation** and **comprehensive documentation** for all deployment scenarios.

## 11. Authentication Methods Reference

### Implemented Methods

| Method | Status | Use Case | Security Level | Implementation |
|--------|--------|----------|----------------|----------------|
| **Username/Password** | ✅ Implemented | Interactive login | High | `src/security/user_management.zig` |
| **MFA (TOTP)** | ✅ Implemented | Two-factor auth | Very High | `src/security/mfa.zig` |
| **Session Tokens** | ❌ Not on the server wire | Session continuity | — | The HELLO carries no token and no server keeps the session ids it issues (SONNY-6551, SONNY-6554); `src/security/authn.zig`'s session store is used only by the embedded LSP verifier, which nothing populates |
| **API Keys** | ❌ Not on the server wire | Service accounts, automation | — | Library `auth_lib.api_keys` only; `geode apikey` refuses everything but a format check (SONNY-6554); see below |
| **mTLS (Certificate)** | ⚠️ Transport gate only (see below) | Zero-trust, service mesh | Very High | `GEODE_MTLS_REQUIRED` + `GEODE_MTLS_CLIENT_CA`; `src/security/mtls_provider.zig` |

### API Key Authentication (not implemented on the server)

**API keys are not implemented end to end (SONNY-6291).** A `geode serve`
server has no API-key store, and its QUIC and gRPC handshakes authenticate
by username and password (or mTLS), never by key. The
`geode.auth.apikey_*` procedures (`apikey_create`, `apikey_list`,
`apikey_revoke`, `apikey_check_scope`) answer SQLSTATE 0A000 (not
supported); before SONNY-6291 they were stubs that answered `scope
granted` for any key and `revoked` without revoking anything. What exists:
the `auth_lib.api_keys` library (key format `gk1.<token_id>.<secret>`,
SHA-256 digests, constant-time comparison), used in process by the MCP and
LSP verifiers. The `geode apikey` CLI kept keys in a local state file the
server never reads and reported `API key created` / `revoked`; since
SONNY-6554 it refuses `create`, `list`, `revoke`, `revoke-all` and
`check-scope` (exit 1, not supported by this server) and only checks a
key's format (`validate`). Use service-account users with passwords, or
mTLS, for programmatic access.

### mTLS Certificate Authentication

mTLS on the QUIC listener is a transport gate: with it on, a connection
must present a client certificate that chains to a CA you configure, and
then still authenticates with a username and password in HELLO.

```bash
# Server: require client certificates that chain to the CAs in this bundle
GEODE_MTLS_REQUIRED=1 \
GEODE_MTLS_CLIENT_CA=/etc/geode/client-ca.pem \
geode serve --listen 0.0.0.0:3141 --cert /etc/geode/server.crt --key /etc/geode/server.key
```

- `GEODE_MTLS_CLIENT_CA` is a PEM bundle of CA certificates
  (basicConstraints `CA:TRUE`). It is the only trust anchor for client
  certificates (SONNY-6453). `geode serve` refuses to start when
  `GEODE_MTLS_REQUIRED` is set and the bundle is unset, cannot be read,
  holds no certificate or holds a non-CA certificate.
- The bundle authenticates clients of the listener and nothing else
  (SONNY-6490). It is not a trust anchor for a server certificate: the
  server's outbound connections (cluster peers, the remote KMS) verify the
  server they reach against their own CA (`GEODE_CLUSTER_CA_CERT`, the KMS
  CA bundle), never against the client CAs.
- `GEODE_MTLS_REQUIRED` is QUIC only. The gRPC listener does not verify
  client certificates, so `geode serve` refuses to start with both
  `GEODE_MTLS_REQUIRED` and `--listen-grpc`.
- A certificate is accepted only when the client proves it holds the key
  (TLS CertificateVerify) and its chain ends in a CA from the bundle, with
  every certificate within its validity period. The server completes the
  chain from the bundle, so a client may send only its leaf (geode's Zig
  clients do), its chain up to the CA, or a self-signed CA certificate that
  is itself in the bundle (pinning). The bundle may hold several unrelated
  CAs (SONNY-6457).
- A leaf whose extendedKeyUsage extension does not list clientAuth is
  rejected; a leaf with no extendedKeyUsage extension is accepted (RFC 5280:
  any purpose).
- `geode query` / `geode shell` / `geode backup` present the certificate
  given with `--client-cert --client-key` (geode-client-zig v0.3.15,
  SONNY-6457), as does geode's internal QUIC client
  (`QuicClient.connectEx`).
- **Identity mapping is not supported (SONNY-6458).** The server's
  certificate-to-user mapping (`src/security/mtls_provider.zig`) starts
  empty and nothing loads mappings, so a client certificate never selects
  the user: the user is always the one that authenticates in HELLO. `geode
  mtls map create|list|delete`, `config` and `status` are refused as
  unsupported (non-zero exit); they used to write a local
  `geode_mtls_state.db` the server never read (SONNY-6457).

### Not Supported (Tracking Issues Open)

| Method | Status | Tracking | Notes |
|--------|--------|----------|-------|
| **LDAP/Active Directory** | ❌ Not supported | [#802](https://gitlab.com/devnw/codepros/geode/geode/-/issues/802) (GAP-0834) | The previous documentation overstated current capability. Will be implemented when a customer requires it. |
| **OAuth2/OIDC** | ❌ Not supported | [#803](https://gitlab.com/devnw/codepros/geode/geode/-/issues/803) (GAP-0835) | The previous documentation overstated current capability. Will be implemented when a customer requires it. |

**Note**: LDAP/AD and OAuth2/OIDC are NOT supported. Earlier revisions of this document advertised them on a 2026 roadmap; that was inaccurate — no implementation exists in `src/security/`. For enterprise SSO requirements today, require mTLS client certificates from your PKI infrastructure in addition to user passwords.

---

## MCP LSP Bridge — RLS Pre-Condition (GAP-0818)

The Geode MCP server exposes four LSP-bridge tools — `validate`,
`complete`, `hover`, `diagnostics` — under `src/mcp/tools.zig` /
`src/mcp/lsp.zig`. As of 2026-05-06, these tools accept a single
process-wide bearer token (or `auth_mode=.none`) and **do not thread
the calling principal into the GQL query path**. This section
documents the three pre-conditions that must be in place before
Row-Level Security (RLS) policies can be safely enforced on
MCP-bridged completions and validations. See `docs/MCP_LSP_BRIDGE.md`
for the full design.

### 1. Per-caller principal threading (BLOCKING for RLS-on-MCP)

**Today**: every MCP request runs as the bearer-token holder. There
is no `(authenticated_user, session_id)` plumbed through to
`validateQuery` / `getCompletions` / `getHover` / `getDiagnostics`.

**Required**: extend the call signatures in `src/mcp/lsp.zig` so each
takes a `principal: Principal` (a typed struct carrying user_id +
session_id + tenant_id), and have `src/mcp/server.zig` derive the
principal from the validated bearer token (or mTLS cert subject) at
request entry.

**Why blocking**: without a principal, the existing RLS expression
engine (`src/security/rls_expr_engine.zig`, see Known Limitations
notes for GAP-0510) has nothing to evaluate `current_user()` or
`current_tenant()` against. Wiring RLS on MCP today would silently
return rows the caller is not entitled to read.

### 2. Token → user mapping

**Today**: `auth_mode = .bearer` validates a single token against a
process-wide secret (or none). There is no per-token user
attribution — the token is the credential, not the identity.

**Required**: the MCP server's auth layer must (a) accept either
issued-by-Geode tokens (signed JWTs carrying `sub` claims) or service
tokens with a configured (token → user) mapping, and (b) return the
resolved `Principal` to the dispatcher at request entry.

### 3. Audit identity

**Today**: tool invocations are logged to OTel spans without
identity. A future RLS-on-MCP rollout MUST carry the resolved user
id into every audit span and into the GQL execution context's
`audit_identity` field, so reads and writes through the bridge are
attributable to a named user.

### Tracking

- GAP-0818 (latent — no exploit today) — closed by documentation,
  not code, on 2026-05-06.
- GAP-0510 (RLS expression engine wiring) — closed 2026-04-11; see
  Known Limitations in `CLAUDE.md`.
- GAP-0819 (MCP GQL input chokepoint) — closed 2026-05-06 with the
  `validateAndSanitizeGqlInput` helper.

**Operator action**: until pre-conditions 1-3 are in place, do not
configure tenant-aware RLS policies that depend on `current_user()`
for any database that is reachable through the MCP server.

CANARY: REQ=REQ-DOC-MCP-LSP-BRIDGE; FEATURE="MCPLSPBridgeDoc"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=mcp; UPDATED=2026-05-06

---

## Brute-Force Lockout (per-principal, with a per-IP ceiling)

Geode counts failed authentications per **(source IP, username) principal**
across both transports (QUIC HELLO and gRPC HELLO). Once a principal reaches the
per-principal threshold it is refused for the duration of the lockout window
(ENG-3954 RC-1). A **coarse per-IP ceiling**, counted across ALL usernames from
an IP, sits above that threshold and still stops a username-rotating
password-spray without letting one attacker deny every other account on a shared
NAT egress. A failed login for one principal therefore never locks out another
principal from the same IP — including the operator.

### Operator configuration

| Knob | CLI flag | Environment variable | Default | Accepted range |
|---|---|---|---|---|
| Failures before a principal is locked | `--auth-lockout-attempts <n>` | `GEODE_AUTH_RATE_MAX_ATTEMPTS` | `10` | 1 - 4294967295 |
| Coarse per-IP ceiling (all usernames) | `--auth-lockout-ip-attempts <n>` | `GEODE_AUTH_RATE_IP_MAX_ATTEMPTS` | `50` | must exceed the per-principal threshold |
| Lockout window (seconds) | `--auth-lockout-secs <n>` | `GEODE_AUTH_RATE_LOCKOUT_SECS` | `60` | 1 - 86400 (1 day) |

The per-IP ceiling MUST be strictly above the per-principal threshold; a value
at or under it (or non-numeric) is REJECTED and falls through to the next source
— otherwise per-principal keying would buy nothing because the ceiling would
fire at the same count.

```bash
# Widen the lockout for a NATed office that shares one egress IP
geode serve --listen 0.0.0.0:3141 \
  --auth-lockout-attempts 25 --auth-lockout-ip-attempts 200 --auth-lockout-secs 300
```

**Precedence** is the geode-wide `flags > environment > defaults`, resolved
**per knob**: supplying only `--auth-lockout-attempts` leaves the window on its
environment value (or the default). A value outside the accepted range — `0`, a
window over one day, or anything non-numeric — is REJECTED and falls through to
the next source, so an operator typo can never disable brute-force protection.

### Behaviour notes

- **Keyed on the (source IP, username) pair**, with a coarse per-IP ceiling as a
  backstop (ENG-3954 RC-1). A stranger spraying a username that does not exist
  charges only that `(ip, bogus-username)` principal, so a legitimate user — and
  the admin — behind the same NAT egress keep their own independent budgets. The
  ceiling only fires once the IP as a whole crosses `--auth-lockout-ip-attempts`,
  which is why it must sit well above the per-principal threshold.
- **In-memory and per-process**: the counters are not persisted and are not
  shared across cluster nodes. A restart clears every lockout.
- **A successful authentication resets that principal's counter**, and only a
  credential that was actually checked and rejected increments it. Transport
  faults, malformed HELLOs, and "the security store could not answer"
  (`error.AuthUnavailable`) are NOT counted (ENG-3954 / #874), so a legitimate
  client cannot lock itself out by hitting a degraded server. (Store-unavailable
  resolver reads are surfaced as the `geode_security_auth_store_unavailable_total`
  runtime metric so an operator can see a degraded store even though it never
  arms a lockout.)
- **Only a password mismatch counts (SONNY-6598).** Every credential check has
  three outcomes: match, mismatch, or an error. An error is a check the server
  could not carry out: the Argon2id key derivation could not allocate its
  memory (a loaded server), the stored hash cannot be used (not an Argon2id
  PHC string or legacy BLAKE2b hash, unparseable or out-of-bounds parameters,
  a salt or digest that is not hex), or the security store could not answer.
  An error never authenticates, is not counted toward the lockout, is logged
  at ERROR with the user name (never the password), and is audited as an
  auth-system error rather than a failed login (below). Until SONNY-6598 an
  Argon2id failure and a malformed stored hash read as a wrong password: a
  correct password under memory pressure was answered "Authentication
  failed" and counted, so server load could lock a user out.
- **A correct credential does not clear an active lockout.** This is deliberate:
  verifying the password first would let an attacker force an unbounded number
  of Argon2id verifications from a locked principal (a CPU-amplification DoS).
  The lockout check therefore runs BEFORE credential verification.
- **The lockout window is anchored, not sliding (ENG-3954 RC-2).** When a bucket
  arms, its deadline is fixed at `now + window`. Failures that keep arriving
  while it is already locked are still counted but do NOT push the deadline
  forward, so sustained guessing can no longer turn a fixed window into an
  indefinite one. Once the anchored window elapses the lockout expires on its
  own and the client may retry.
- **Introspection and recovery (ENG-3954 RC-3).** A denial is logged with the
  attempted username and which bucket denied (`denial_reason=principal` vs
  `ip_ceiling`), and the limiter exposes `lockoutReason`, `lockoutRemainingNs`,
  and `clearLockout` (an empty username clears an IP's ceiling bucket) so an
  operator can see and release a misfiring lockout without restarting the server.

CANARY: REQ=REQ-DOC-AUTH-LOCKOUT-CONFIG; FEATURE="AuthRateLimiting"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=security; UPDATED=2026-08-29

### What a client sees when a login is refused (SONNY-6598)

A refused HELLO answers `success=false` with one of these `error_message`
values, the same on QUIC and gRPC:

| `error_message` | Meaning | Counted toward the lockout | Retry? |
|---|---|---|---|
| `Authentication failed` | The credentials were checked and rejected (wrong password, unknown or disabled user). | Yes | With the right credentials |
| `Authentication temporarily unavailable` | The server could not check the credentials: the password key derivation could not run (e.g. out of memory under load) or the security store could not answer. | No | Yes, after a back-off |
| `Authentication unavailable: the stored credential of this account cannot be used (server-side error; contact the administrator)` | The account's stored password hash is malformed (e.g. a bad `geode.auth.user_import`). No password logs this account in until an administrator resets it. | No | No: reset the password (`geode.auth.user_reset_password` / `ALTER USER ... SET PASSWORD`) |
| `Too many failed authentication attempts. ...` | The principal (or the source IP) is locked out. | (already locked) | After the lockout window |
| `Authentication required` | The HELLO carried no user name or password. | No | With credentials |

The last answer of the table but one names the account's state, so it tells a
caller that a user with a malformed stored hash exists; only an administrator
can create such a hash, and the server logs each occurrence at ERROR.

With the process audit log enabled (`GEODE_AUDIT_ENABLED=1`), every refused
HELLO credential check writes a record whose `details.username` is the user
name sent:

- a rejected credential: `event_type` `authentication_failure`, `action`
  `LOGIN`, `result` `failure`;
- a check the server could not run: `event_type` `system_event`, `action`
  `AUTH_ERROR`, `result` `error_`, severity error, with the error name in
  `details.details` (e.g. `auth-system error, not a failed login: OutOfMemory`).

The same three-outcome rule applies to the other credential checks:
`geode.auth.mfa_verify` and `mfa_enable` answer a TOTP check the server cannot
run (MFA turned off, an unusable stored secret) with that error (e.g. 0A000),
not 28000 "invalid code", and mfa_verify does not count it toward the MFA
lockout; the offline `geode user change-password --old-password` says the old password
could not be checked instead of "old password is incorrect"; and a
`__geode_security` HMAC chain verification that could not run (out of memory,
a store read error) is reported as unverifiable, not as tampering: the server
refuses to start with `AuthChainUnverifiable` (the reseal override does not
apply), the offline CLI refuses with "could not be verified", and the periodic
check logs it without the tampering alarm.

CANARY: REQ=REQ-DOC-SONNY-6598-AUTH-ERRORS; FEATURE="AuthOutcomeClassification"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=security; UPDATED=2026-11-15
