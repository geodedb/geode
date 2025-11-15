//! Geode client implementation using s2n-quic library for QUIC transport.

use s2n_quic::client::Connect;
use s2n_quic::stream::BidirectionalStream;
use s2n_quic::Client as QuicClient;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::error::{Error, Result};
use crate::types::{decode_value, Value};

const GEODE_ALPN: &[u8] = b"geode/1";

/// Column in a result set
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Column {
    pub name: String,
    #[serde(rename = "type")]
    pub col_type: String,
}

/// Page of query results
#[derive(Debug, Clone)]
pub struct Page {
    pub columns: Vec<Column>,
    pub rows: Vec<HashMap<String, Value>>,
    pub ordered: bool,
    pub order_keys: Vec<String>,
    pub final_page: bool,
}

/// Savepoint within a transaction
#[derive(Debug, Clone)]
pub struct Savepoint {
    pub name: String,
}

/// Geode database client using s2n-quic
#[derive(Clone)]
pub struct Client {
    host: String,
    port: u16,
    ca_cert_path: Option<String>,
    skip_verify: bool,
    page_size: usize,
    hello_name: String,
    hello_ver: String,
    conformance: String,
}

impl Client {
    /// Create a new QUIC client
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self {
            host: host.into(),
            port,
            ca_cert_path: None,
            skip_verify: false,
            page_size: 1000,
            hello_name: "geode-rust".to_string(),
            hello_ver: "0.1.0".to_string(),
            conformance: "min".to_string(),
        }
    }

    /// Set CA certificate path for server verification
    pub fn ca_cert(mut self, path: impl Into<String>) -> Self {
        self.ca_cert_path = Some(path.into());
        self
    }

    /// Skip TLS verification (insecure, for development only)
    pub fn skip_verify(mut self, skip: bool) -> Self {
        self.skip_verify = skip;
        self
    }

    /// Set page size for queries
    pub fn page_size(mut self, size: usize) -> Self {
        self.page_size = size;
        self
    }

    /// Set client name
    pub fn client_name(mut self, name: impl Into<String>) -> Self {
        self.hello_name = name.into();
        self
    }

    /// Set client version
    pub fn client_version(mut self, version: impl Into<String>) -> Self {
        self.hello_ver = version.into();
        self
    }

    /// Set GQL conformance level
    pub fn conformance(mut self, level: impl Into<String>) -> Self {
        self.conformance = level.into();
        self
    }

    /// Connect to the database (async)
    pub async fn connect(&self) -> Result<Connection> {
        Connection::new(
            &self.host,
            self.port,
            self.ca_cert_path.as_deref(),
            self.skip_verify,
            self.page_size,
            &self.hello_name,
            &self.hello_ver,
            &self.conformance,
        )
        .await
    }
}

/// A single connection to Geode via QUIC (using s2n-quic)
pub struct Connection {
    reader: BufReader<tokio::io::ReadHalf<BidirectionalStream>>,
    writer: tokio::io::WriteHalf<BidirectionalStream>,
    page_size: usize,
}

impl Connection {
    async fn new(
        host: &str,
        port: u16,
        ca_cert_path: Option<&str>,
        skip_verify: bool,
        page_size: usize,
        hello_name: &str,
        hello_ver: &str,
        conformance: &str,
    ) -> Result<Self> {
        eprintln!("[S2N-QUIC] Creating connection to {}:{}", host, port);

        // Build TLS config
        let mut tls_builder = s2n_quic::provider::tls::default::Client::builder();

        if skip_verify {
            // For development - skip certificate verification
            tls_builder = tls_builder
                .with_empty_trust_store()
                .map_err(|e| Error::connection(&format!("Trust store error: {}", e)))?;
        } else if let Some(cert_path) = ca_cert_path {
            tls_builder = tls_builder
                .with_certificate(std::path::Path::new(cert_path))
                .map_err(|e| Error::connection(&format!("Certificate error: {}", e)))?;
        }

        let tls = tls_builder
            .with_application_protocols([GEODE_ALPN])
            .map_err(|e| Error::connection(&format!("ALPN error: {}", e)))?
            .build()
            .map_err(|e| Error::connection(&format!("TLS config error: {}", e)))?;

        // Create QUIC client
        let client = QuicClient::builder()
            .with_tls(tls)
            .map_err(|e| Error::connection(&format!("Client builder error: {}", e)))?
            .with_io("0.0.0.0:0")
            .map_err(|e| Error::connection(&format!("IO bind error: {}", e)))?
            .start()
            .map_err(|e| Error::connection(&format!("Client start error: {}", e)))?;

        // Parse server address
        let server_addr: SocketAddr = format!("{}:{}", host, port)
            .parse()
            .map_err(|e| Error::connection(&format!("Invalid address: {}", e)))?;

        // Connect to server
        let connect = Connect::new(server_addr).with_server_name(host);
        let mut connection = client
            .connect(connect)
            .await
            .map_err(|e| Error::connection(&format!("Connection failed: {}", e)))?;

        eprintln!("[S2N-QUIC] Connected, opening bidirectional stream");

        // Open bidirectional stream
        let stream = connection
            .open_bidirectional_stream()
            .await
            .map_err(|e| Error::connection(&format!("Failed to open stream: {}", e)))?;

        let (read_half, write_half) = tokio::io::split(stream);
        let mut reader = BufReader::new(read_half);
        let mut writer = write_half;

        eprintln!("[S2N-QUIC] Stream opened, sending HELLO");

        // Send HELLO message
        let hello_msg = serde_json::json!({
            "type": "HELLO",
            "name": hello_name,
            "ver": hello_ver,
            "conformance": conformance
        });

        let mut hello_json = serde_json::to_string(&hello_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize HELLO: {}", e)))?;
        hello_json.push('\n');

        writer
            .write_all(hello_json.as_bytes())
            .await
            .map_err(|e| Error::protocol(&format!("Failed to send HELLO: {}", e)))?;

        writer
            .flush()
            .await
            .map_err(|e| Error::protocol(&format!("Failed to flush HELLO: {}", e)))?;

        eprintln!("[S2N-QUIC] HELLO sent, waiting for response");

        // Read HELLO response
        let mut response_line = String::new();
        reader
            .read_line(&mut response_line)
            .await
            .map_err(|e| Error::protocol(&format!("Failed to read HELLO response: {}", e)))?;

        eprintln!("[S2N-QUIC] Received HELLO response: {}", response_line.trim());

        let response: serde_json::Value = serde_json::from_str(&response_line)
            .map_err(|e| Error::protocol(&format!("Invalid HELLO response JSON: {}", e)))?;

        if response.get("type").and_then(|t| t.as_str()) != Some("HELLO") {
            return Err(Error::protocol(&format!(
                "Expected HELLO response, got: {}",
                response_line.trim()
            )));
        }

        eprintln!("[S2N-QUIC] Handshake complete");

        // Open new stream for queries (handshake stream is consumed)
        let query_stream = connection
            .open_bidirectional_stream()
            .await
            .map_err(|e| Error::connection(&format!("Failed to open query stream: {}", e)))?;

        let (read_half, write_half) = tokio::io::split(query_stream);

        Ok(Connection {
            reader: BufReader::new(read_half),
            writer: write_half,
            page_size,
        })
    }

    /// Send JSON message to server
    async fn write_json(&mut self, obj: &serde_json::Value) -> Result<()> {
        let mut line = serde_json::to_string(obj)
            .map_err(|e| Error::protocol(&format!("Failed to serialize JSON: {}", e)))?;
        line.push('\n');

        self.writer
            .write_all(line.as_bytes())
            .await
            .map_err(|e| Error::protocol(&format!("Failed to write: {}", e)))?;

        self.writer
            .flush()
            .await
            .map_err(|e| Error::protocol(&format!("Failed to flush: {}", e)))?;

        Ok(())
    }

    /// Read JSON message from server
    async fn read_json(&mut self) -> Result<serde_json::Value> {
        let mut line = String::new();
        let bytes_read = self
            .reader
            .read_line(&mut line)
            .await
            .map_err(|e| Error::protocol(&format!("Failed to read line: {}", e)))?;

        if bytes_read == 0 {
            return Err(Error::protocol("Connection closed by server"));
        }

        serde_json::from_str(&line)
            .map_err(|e| Error::protocol(&format!("Invalid JSON: {}", e)))
    }

    /// Execute a GQL query
    pub async fn query(
        &mut self,
        text: &str,
        params: Option<HashMap<String, serde_json::Value>>,
    ) -> Result<Page> {
        // Send RUN_GQL message
        let run_msg = if let Some(p) = params {
            serde_json::json!({"type": "RUN_GQL", "text": text, "params": p})
        } else {
            serde_json::json!({"type": "RUN_GQL", "text": text})
        };

        self.write_json(&run_msg).await?;

        // Receive SCHEMA message
        let schema_msg = self.read_json().await?;

        let msg_type = schema_msg
            .get("type")
            .and_then(|t| t.as_str())
            .ok_or_else(|| Error::protocol("Missing type in response"))?;

        if msg_type == "ERROR" {
            let error_msg = schema_msg
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("Unknown error");
            return Err(Error::query(error_msg));
        }

        if msg_type != "SCHEMA" {
            return Err(Error::protocol(&format!(
                "Expected SCHEMA, got {}",
                msg_type
            )));
        }

        let columns_json = schema_msg
            .get("columns")
            .ok_or_else(|| Error::protocol("Missing columns in SCHEMA"))?;

        let columns: Vec<Column> = serde_json::from_value(columns_json.clone())
            .map_err(|e| Error::protocol(&format!("Invalid columns: {}", e)))?;

        // Send PULL message
        let pull_msg = serde_json::json!({
            "type": "PULL",
            "request_id": 1,
            "page_size": self.page_size
        });

        self.write_json(&pull_msg).await?;

        // Receive BINDINGS message
        let bindings_msg = self.read_json().await?;

        let msg_type = bindings_msg
            .get("type")
            .and_then(|t| t.as_str())
            .ok_or_else(|| Error::protocol("Missing type in bindings response"))?;

        if msg_type == "ERROR" {
            let error_msg = bindings_msg
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("Unknown error");
            return Err(Error::query(error_msg));
        }

        if msg_type != "BINDINGS" {
            return Err(Error::protocol(&format!(
                "Expected BINDINGS, got {}",
                msg_type
            )));
        }

        let rows_json = bindings_msg
            .get("rows")
            .ok_or_else(|| Error::protocol("Missing rows in BINDINGS"))?
            .as_array()
            .ok_or_else(|| Error::protocol("rows must be an array"))?;

        let mut rows = Vec::new();
        for row_json in rows_json {
            let row_obj = row_json
                .as_object()
                .ok_or_else(|| Error::protocol("Each row must be an object"))?;

            let mut row_map = HashMap::new();
            for (key, val) in row_obj {
                // Use generic "ANY" type since we don't have type info in BINDINGS
                let decoded = decode_value(val, "ANY")?;
                row_map.insert(key.clone(), decoded);
            }
            rows.push(row_map);
        }

        let ordered = bindings_msg
            .get("ordered")
            .and_then(|o| o.as_bool())
            .unwrap_or(false);

        let order_keys = bindings_msg
            .get("order_keys")
            .and_then(|ok| ok.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();

        let final_page = bindings_msg
            .get("final")
            .and_then(|f| f.as_bool())
            .unwrap_or(true);

        Ok(Page {
            columns,
            rows,
            ordered,
            order_keys,
            final_page,
        })
    }

    /// Begin a transaction
    pub async fn begin(&mut self) -> Result<()> {
        let begin_msg = serde_json::json!({"type": "BEGIN"});
        self.write_json(&begin_msg).await?;

        let response = self.read_json().await?;
        let msg_type = response
            .get("type")
            .and_then(|t| t.as_str())
            .ok_or_else(|| Error::protocol("Missing type in BEGIN response"))?;

        if msg_type == "ERROR" {
            let error_msg = response
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("Unknown error");
            return Err(Error::transaction(error_msg));
        }

        if msg_type != "ACK" {
            return Err(Error::protocol(&format!(
                "Expected ACK for BEGIN, got {}",
                msg_type
            )));
        }

        Ok(())
    }

    /// Commit the current transaction
    pub async fn commit(&mut self) -> Result<()> {
        let commit_msg = serde_json::json!({"type": "COMMIT"});
        self.write_json(&commit_msg).await?;

        let response = self.read_json().await?;
        let msg_type = response
            .get("type")
            .and_then(|t| t.as_str())
            .ok_or_else(|| Error::protocol("Missing type in COMMIT response"))?;

        if msg_type == "ERROR" {
            let error_msg = response
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("Unknown error");
            return Err(Error::transaction(error_msg));
        }

        if msg_type != "ACK" {
            return Err(Error::protocol(&format!(
                "Expected ACK for COMMIT, got {}",
                msg_type
            )));
        }

        Ok(())
    }

    /// Rollback the current transaction
    pub async fn rollback(&mut self) -> Result<()> {
        let rollback_msg = serde_json::json!({"type": "ROLLBACK"});
        self.write_json(&rollback_msg).await?;

        let response = self.read_json().await?;
        let msg_type = response
            .get("type")
            .and_then(|t| t.as_str())
            .ok_or_else(|| Error::protocol("Missing type in ROLLBACK response"))?;

        if msg_type == "ERROR" {
            let error_msg = response
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("Unknown error");
            return Err(Error::transaction(error_msg));
        }

        if msg_type != "ACK" {
            return Err(Error::protocol(&format!(
                "Expected ACK for ROLLBACK, got {}",
                msg_type
            )));
        }

        Ok(())
    }

    /// Close the connection
    pub async fn close(&mut self) -> Result<()> {
        let close_msg = serde_json::json!({"type": "GOODBYE"});
        self.write_json(&close_msg).await?;

        // Best effort - don't wait for response
        let _ = self.reader.read_line(&mut String::new()).await;

        Ok(())
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        // Connection will be closed automatically when dropped
    }
}
