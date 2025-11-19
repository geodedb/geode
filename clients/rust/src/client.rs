//! Geode client implementation using Quinn library for QUIC transport.
//! Switched back to Quinn from Quiche for better MsQuic compatibility.

use quinn::{ClientConfig, Endpoint};
use rustls::pki_types::{CertificateDer, ServerName as RustlsServerName};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::time::{timeout, Duration};

use crate::error::{Error, Result};
use crate::types::Value;

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

/// Geode database client using Quinn
#[derive(Clone)]
pub struct Client {
    host: String,
    port: u16,
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
            skip_verify: false,
            page_size: 1000,
            hello_name: "geode-rust-quinn".to_string(),
            hello_ver: "0.1.0".to_string(),
            conformance: "min".to_string(),
        }
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

    /// Connect to the database (async with Quinn)
    pub async fn connect(&self) -> Result<Connection> {
        Connection::new(
            &self.host,
            self.port,
            self.skip_verify,
            self.page_size,
            &self.hello_name,
            &self.hello_ver,
            &self.conformance,
        )
        .await
    }
}

/// A single connection to Geode via QUIC (using Quinn)
pub struct Connection {
    conn: quinn::Connection,
    page_size: usize,
}

impl Connection {
    async fn new(
        host: &str,
        port: u16,
        skip_verify: bool,
        page_size: usize,
        hello_name: &str,
        hello_ver: &str,
        conformance: &str,
    ) -> Result<Self> {
        eprintln!("[QUINN] Creating connection to {}:{}", host, port);

        // Install default crypto provider for rustls
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

        // Build Quinn client config
        let mut client_crypto = if skip_verify {
            eprintln!("[QUINN] Skipping certificate verification (insecure)");
            rustls::ClientConfig::builder()
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
                .with_no_client_auth()
        } else {
            rustls::ClientConfig::builder()
                .with_root_certificates(rustls::RootCertStore::empty())
                .with_no_client_auth()
        };

        // Set ALPN protocols
        client_crypto.alpn_protocols = vec![GEODE_ALPN.to_vec()];

        let mut client_config = ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(client_crypto)
                .map_err(|e| Error::connection(&format!("Failed to create QUIC config: {}", e)))?
        ));

        // Configure QUIC transport parameters to match Python/Go clients
        let mut transport = quinn::TransportConfig::default();
        transport.max_idle_timeout(Some(Duration::from_secs(30).try_into().unwrap()));
        transport.keep_alive_interval(Some(Duration::from_secs(5)));
        client_config.transport_config(Arc::new(transport));

        // Create endpoint
        let mut endpoint = Endpoint::client("0.0.0.0:0".parse().unwrap())
            .map_err(|e| Error::connection(&format!("Failed to create endpoint: {}", e)))?;
        endpoint.set_default_client_config(client_config);

        // Connect to server
        let server_addr: SocketAddr = format!("{}:{}", host, port)
            .parse()
            .map_err(|e| Error::connection(&format!("Invalid address: {}", e)))?;

        eprintln!("[QUINN] Connecting to {}", server_addr);

        let conn = timeout(
            Duration::from_secs(10),
            endpoint.connect(server_addr, host)
                .map_err(|e| Error::connection(&format!("Connection failed: {}", e)))?
        )
        .await
        .map_err(|_| Error::connection("Connection timeout"))?
        .map_err(|e| Error::connection(&format!("Failed to establish connection: {}", e)))?;

        eprintln!("[QUINN] ✓ Connection established!");

        // Open bidirectional stream for HELLO
        let (mut send, mut recv) = conn
            .open_bi()
            .await
            .map_err(|e| Error::connection(&format!("Failed to open stream: {}", e)))?;

        // Send HELLO message
        let hello_msg = serde_json::json!({
            "type": "HELLO",
            "client_name": hello_name,
            "client_version": hello_ver,
            "conformance": conformance,
        });

        let hello_bytes = serde_json::to_vec(&hello_msg)
            .map_err(|e| Error::connection(&format!("Failed to serialize HELLO: {}", e)))?;

        send.write_all(&hello_bytes)
            .await
            .map_err(|e| Error::connection(&format!("Failed to send HELLO: {}", e)))?;
        send.finish()
            .map_err(|e| Error::connection(&format!("Failed to finish HELLO stream: {}", e)))?;

        eprintln!("[QUINN] Sent HELLO message");

        // Wait for HELLO response
        let response = timeout(
            Duration::from_secs(5),
            recv.read_to_end(1024 * 1024)
        )
        .await
        .map_err(|_| Error::connection("HELLO response timeout"))?
        .map_err(|e| Error::connection(&format!("Failed to read HELLO response: {}", e)))?;

        let _hello_response: serde_json::Value = serde_json::from_slice(&response)
            .map_err(|e| Error::connection(&format!("Invalid HELLO response: {}", e)))?;

        eprintln!("[QUINN] ✓ HELLO handshake complete");

        Ok(Self { conn, page_size })
    }

    /// Execute a GQL query
    pub async fn query(&self, gql: &str) -> Result<(Page, Option<String>)> {
        self.query_with_params(gql, &HashMap::new()).await
    }

    /// Execute a GQL query with parameters
    pub async fn query_with_params(
        &self,
        gql: &str,
        params: &HashMap<String, Value>,
    ) -> Result<(Page, Option<String>)> {
        // Open bidirectional stream
        let (mut send, mut recv) = self
            .conn
            .open_bi()
            .await
            .map_err(|e| Error::query(&format!("Failed to open stream: {}", e)))?;

        // Convert parameters to serde_json::Value
        let params_json: serde_json::Map<String, serde_json::Value> = params
            .iter()
            .map(|(k, v)| (k.clone(), v.to_json()))
            .collect();

        // Send QUERY message
        let query_msg = serde_json::json!({
            "type": "QUERY",
            "query": gql,
            "parameters": params_json,
            "page_size": self.page_size,
        });

        let query_bytes = serde_json::to_vec(&query_msg)
            .map_err(|e| Error::query(&format!("Failed to serialize query: {}", e)))?;

        send.write_all(&query_bytes)
            .await
            .map_err(|e| Error::query(&format!("Failed to send query: {}", e)))?;
        send.finish()
            .map_err(|e| Error::query(&format!("Failed to finish query stream: {}", e)))?;

        // Read response
        let response = timeout(
            Duration::from_secs(30),
            recv.read_to_end(10 * 1024 * 1024)
        )
        .await
        .map_err(|_| Error::query("Query response timeout"))?
        .map_err(|e| Error::query(&format!("Failed to read query response: {}", e)))?;

        let response_json: serde_json::Value = serde_json::from_slice(&response)
            .map_err(|e| Error::query(&format!("Invalid query response: {}", e)))?;

        // Parse response
        if response_json["type"] == "ERROR" {
            let error_msg = response_json["error"]
                .as_str()
                .unwrap_or("Unknown error");
            return Err(Error::query(error_msg));
        }

        let columns: Vec<Column> = serde_json::from_value(response_json["columns"].clone())
            .map_err(|e| Error::query(&format!("Failed to parse columns: {}", e)))?;

        // Parse rows using column types
        let rows_array = response_json["rows"]
            .as_array()
            .ok_or_else(|| Error::query("Response rows is not an array"))?;

        let mut rows = Vec::new();
        for row_json in rows_array {
            let row_obj = row_json
                .as_object()
                .ok_or_else(|| Error::query("Row is not an object"))?;

            let mut row = HashMap::new();
            for (col_name, col_value) in row_obj {
                // Find column type
                let col_type = columns
                    .iter()
                    .find(|c| &c.name == col_name)
                    .map(|c| c.col_type.as_str())
                    .unwrap_or("");

                let value = crate::types::decode_value(col_value, col_type)?;
                row.insert(col_name.clone(), value);
            }
            rows.push(row);
        }

        let page = Page {
            columns,
            rows,
            ordered: response_json["ordered"].as_bool().unwrap_or(false),
            order_keys: response_json["order_keys"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default(),
            final_page: response_json["final_page"].as_bool().unwrap_or(true),
        };

        let cursor = response_json["cursor"].as_str().map(String::from);

        Ok((page, cursor))
    }

    /// Close the connection
    pub async fn close(self) {
        self.conn.close(0u32.into(), b"client closing");
        // Wait a bit for the close to be sent
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Certificate verifier that skips all verification (INSECURE - for development only)
#[derive(Debug)]
struct SkipServerVerification;

impl rustls::client::danger::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer,
        _intermediates: &[CertificateDer],
        _server_name: &RustlsServerName,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer,
        _dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer,
        _dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ED25519,
        ]
    }
}
