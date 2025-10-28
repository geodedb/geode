//! Error types for the Geode client.

use thiserror::Error;

/// Result type alias for Geode operations
pub type Result<T> = std::result::Result<T, Error>;

/// Error types that can occur when using the Geode client
#[derive(Error, Debug)]
pub enum Error {
    /// Connection error
    #[error("Connection error: {0}")]
    Connection(String),

    /// Query execution error
    #[error("Query error: {code} - {message}")]
    Query {
        code: String,
        message: String,
    },

    /// Authentication error
    #[error("Authentication error: {0}")]
    Auth(String),

    /// I/O error
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// JSON serialization/deserialization error
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    /// QUIC connection error
    #[error("QUIC error: {0}")]
    Quic(String),

    /// TLS error
    #[error("TLS error: {0}")]
    Tls(String),

    /// Invalid DSN format
    #[error("Invalid DSN: {0}")]
    InvalidDsn(String),

    /// Type conversion error
    #[error("Type error: {0}")]
    Type(String),

    /// Timeout error
    #[error("Operation timed out")]
    Timeout,

    /// Pool error
    #[error("Pool error: {0}")]
    Pool(String),

    /// Generic error
    #[error("{0}")]
    Other(String),
}

impl Error {
    /// Create a connection error
    pub fn connection<S: Into<String>>(msg: S) -> Self {
        Error::Connection(msg.into())
    }

    /// Create a query error
    pub fn query<S: Into<String>>(code: S, message: S) -> Self {
        Error::Query {
            code: code.into(),
            message: message.into(),
        }
    }

    /// Create an auth error
    pub fn auth<S: Into<String>>(msg: S) -> Self {
        Error::Auth(msg.into())
    }

    /// Create a QUIC error
    pub fn quic<S: Into<String>>(msg: S) -> Self {
        Error::Quic(msg.into())
    }

    /// Create a TLS error
    pub fn tls<S: Into<String>>(msg: S) -> Self {
        Error::Tls(msg.into())
    }

    /// Create a type error
    pub fn type_error<S: Into<String>>(msg: S) -> Self {
        Error::Type(msg.into())
    }

    /// Create a pool error
    pub fn pool<S: Into<String>>(msg: S) -> Self {
        Error::Pool(msg.into())
    }
}

// Convert quinn errors to our Error type
impl From<quinn::ConnectionError> for Error {
    fn from(err: quinn::ConnectionError) -> Self {
        Error::quic(err.to_string())
    }
}

impl From<quinn::WriteError> for Error {
    fn from(err: quinn::WriteError) -> Self {
        Error::quic(err.to_string())
    }
}

impl From<quinn::ReadError> for Error {
    fn from(err: quinn::ReadError) -> Self {
        Error::quic(err.to_string())
    }
}

impl From<quinn::ConnectError> for Error {
    fn from(err: quinn::ConnectError) -> Self {
        Error::quic(err.to_string())
    }
}

impl From<quinn::ConfigError> for Error {
    fn from(err: quinn::ConfigError) -> Self {
        Error::quic(err.to_string())
    }
}
