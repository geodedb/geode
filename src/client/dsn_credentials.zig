// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 CodePros
// CANARY: REQ=REQ-SONNY-6544-DSN-USERINFO; FEATURE="DSN credentials"; ASPECT=UserinfoAndRedaction; STATUS=TESTED; TEST=tests/test_sonny6544_dsn_redaction.zig; OWNER=cli; UPDATED=2026-11-14

//! SONNY-6544: the credentials in a DSN, and the one way an address or DSN
//! is printed.
//!
//! RFC 3986 §3.2: the authority runs from after `scheme://` to the first
//! `/`, `?` or `#`; its userinfo is everything before the LAST `@` of the
//! authority (a raw `@` in a password is therefore read correctly), and
//! splits into user and password at its FIRST `:` (a user name cannot hold
//! a raw `:`). Both are percent-decoded (§2.1): `%` must be followed by two
//! hex digits, and `+` is a literal plus.
//!
//! `redacted(text)` prints an address or DSN with its userinfo removed and
//! the value of every secret-looking query parameter (`pass=`,
//! `password=`, `token=`, ...) replaced by `***`. Every client-side place
//! that prints a server address or a DSN goes through it.
//!
//! SONNY-6550: these rules are geode-client-zig's `config.redact` (v0.3.17
//! took them from this file); the names below are that module's, so the
//! CLI, the REPL and the client library read and print a DSN with one
//! implementation. Its decoder checks the text before allocating and
//! allocates the result at its exact size, so no resized copy of a
//! credential is freed unzeroed.

const redact = @import("geode_client_zig").config.redact;

pub const Error = redact.Error;
pub const Authority = redact.Authority;
pub const splitAuthority = redact.splitAuthority;
pub const schemeEnd = redact.schemeEnd;
pub const Credentials = redact.Credentials;
pub const decodeUserinfo = redact.decodeUserinfo;
pub const percentDecode = redact.percentDecode;
pub const redacted_marker = redact.redacted_marker;
pub const Redacted = redact.Redacted;
pub const redacted = redact.redacted;
pub const isSecretKey = redact.isSecretKey;
