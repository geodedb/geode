//! Geode Rust Client Library
//!
//! A high-performance async Rust client for Geode graph database with full GQL support.
//!
//! # Features
//!
//! - 🚀 Async/await support using tokio
//! - 🔒 QUIC + TLS 1.3 for secure networking
//! - 📝 Full GQL (ISO/IEC 39075:2024) support
//! - 🏗️ Query builders for programmatic query construction
//! - 🔐 Authentication & RBAC with RLS policies
//! - 🏊 Connection pooling for concurrent workloads
//! - 📊 Rich type system with Decimal, temporal types
//!
//! # Example
//!
//! ```no_run
//! use geode_client::{Client, Result};
//!
//! #[tokio::main]
//! async fn main() -> Result<()> {
//!     let client = Client::new("process:./zig-out/bin/geode")?;
//!     let conn = client.connect().await?;
//!
//!     let page = conn.query("RETURN 1 AS x", None).await?;
//!     println!("Result: {:?}", page);
//!
//!     Ok(())
//! }
//! ```

pub mod auth;
pub mod client;
pub mod error;
pub mod pool;
pub mod query_builder;
pub mod types;

// Re-export main types
pub use client::{Client, Connection, Page, Column};
pub use error::{Error, Result};
pub use query_builder::{QueryBuilder, PatternBuilder, PredicateBuilder, EdgeDirection};
pub use types::{Value, ValueKind, Range};
pub use auth::{AuthClient, User, Role, Permission, RLSPolicy, SessionInfo};
pub use pool::ConnectionPool;

/// Library version
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
