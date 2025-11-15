//! Geode client implementation using quinn library for QUIC transport.

use quinn::{ClientConfig, Connection as QuinnConnection, Endpoint};
use rustls::pki_types::CertificateDer;
use rustls::RootCertStore;
use rustls_pemfile;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::File;
use std::io::BufReader;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use crate::error::{Error, Result};
use crate::types::{decode_value, Value};

const GEODE_ALPN: &[u8] = b"geode/1";

fn apply_geode_alpn(config: &mut rustls::ClientConfig) {
    config.alpn_protocols.clear();
    config.alpn_protocols.push(GEODE_ALPN.to_vec());
}

fn build_client_config(crypto: rustls::ClientConfig) -> ClientConfig {
    let mut client_config = ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(crypto).unwrap(),
    ));
    client_config.transport_config(Arc::new(create_transport_config()));
    client_config
}

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

/// Geode database client using quinn
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

/// A single connection to Geode via QUIC (using quinn)
pub struct Connection {
    connection: QuinnConnection,
    send_stream: quinn::SendStream,
    recv_stream: quinn::RecvStream,
    page_size: usize,
    read_buffer: Vec<u8>,
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
        eprintln!("[QUINN] Creating connection to {}:{}", host, port);

        // Resolve server address
        let addr_str = format!("{}:{}", host, port);
        let server_addr: SocketAddr = addr_str
            .to_socket_addrs()
            .map_err(|e| {
                Error::connection(&format!("Failed to resolve address {}: {}", addr_str, e))
            })?
            .next()
            .ok_or_else(|| Error::connection(&format!("No addresses found for {}", addr_str)))?;

        eprintln!("[QUINN] Resolved server address: {}", server_addr);

        // Configure TLS
        let mut roots = RootCertStore::empty();

        if skip_verify {
            eprintln!("[QUINN] TLS peer verification DISABLED (skip_verify=true)");
            // Create a dangerous configuration that skips verification
            let mut crypto = rustls::ClientConfig::builder()
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
                .with_no_client_auth();
            apply_geode_alpn(&mut crypto);
            eprintln!(
                "[QUINN] Using ALPNs: {:?}",
                crypto
                    .alpn_protocols
                    .iter()
                    .map(|p| String::from_utf8_lossy(p).into_owned())
                    .collect::<Vec<_>>()
            );

            let client_config = build_client_config(crypto);

            // Create endpoint
            let mut endpoint = Endpoint::client("0.0.0.0:0".parse().unwrap())
                .map_err(|e| Error::connection(&format!("Failed to create endpoint: {}", e)))?;
            endpoint.set_default_client_config(client_config);

            // Connect
            eprintln!(
                "[QUINN] Connecting to {} with skip_verify=true",
                server_addr
            );
            let connection = endpoint
                .connect(server_addr, host)
                .map_err(|e| Error::connection(&format!("Failed to initiate connection: {}", e)))?
                .await
                .map_err(|e| Error::connection(&format!("Connection failed: {}", e)))?;

            eprintln!("[QUINN] QUIC connection established");

            // Open bidirectional stream
            let (mut send_stream, mut recv_stream) = connection
                .open_bi()
                .await
                .map_err(|e| Error::connection(&format!("Failed to open stream: {}", e)))?;

            eprintln!("[QUINN] Bidirectional stream opened");

            // Create connection
            let mut conn = Self {
                connection,
                send_stream,
                recv_stream,
                page_size,
                read_buffer: Vec::new(),
            };

            // Send HELLO message
            conn.send_hello(hello_name, hello_ver, conformance).await?;

            Ok(conn)
        } else {
            // Load CA certificate
            let default_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../test-harness/certs/ca.crt");

            let ca_path: Option<&str> = if let Some(ref path) = ca_cert_path {
                Some(path)
            } else if default_path.exists() {
                default_path.to_str()
            } else {
                None
            };

            if let Some(path) = ca_path {
                eprintln!("[QUINN] Loading CA certificate from: {}", path);
                let cert_file = File::open(path)
                    .map_err(|e| Error::connection(&format!("Failed to open CA cert: {}", e)))?;
                let mut reader = BufReader::new(cert_file);

                for cert_result in rustls_pemfile::certs(&mut reader) {
                    let cert = cert_result.map_err(|e| {
                        Error::connection(&format!("Failed to parse CA cert: {}", e))
                    })?;
                    roots
                        .add(cert)
                        .map_err(|e| Error::connection(&format!("Failed to add CA cert: {}", e)))?;
                }
            } else {
                eprintln!("[QUINN] No CA certificate specified, using system trust store");
                for cert in rustls_native_certs::load_native_certs().map_err(|e| {
                    Error::connection(&format!("Failed to load system certs: {}", e))
                })? {
                    roots.add(cert).map_err(|e| {
                        Error::connection(&format!("Failed to add system cert: {}", e))
                    })?;
                }
            }

            let mut crypto = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            apply_geode_alpn(&mut crypto);
            eprintln!(
                "[QUINN] Using ALPNs: {:?}",
                crypto
                    .alpn_protocols
                    .iter()
                    .map(|p| String::from_utf8_lossy(p).into_owned())
                    .collect::<Vec<_>>()
            );

            let client_config = build_client_config(crypto);

            // Create endpoint
            let mut endpoint = Endpoint::client("0.0.0.0:0".parse().unwrap())
                .map_err(|e| Error::connection(&format!("Failed to create endpoint: {}", e)))?;
            endpoint.set_default_client_config(client_config);

            // Connect
            eprintln!("[QUINN] Connecting to {}", server_addr);
            let connection = endpoint
                .connect(server_addr, host)
                .map_err(|e| Error::connection(&format!("Failed to initiate connection: {}", e)))?
                .await
                .map_err(|e| Error::connection(&format!("Connection failed: {}", e)))?;

            eprintln!("[QUINN] QUIC connection established");

            // Open bidirectional stream
            let (mut send_stream, mut recv_stream) = connection
                .open_bi()
                .await
                .map_err(|e| Error::connection(&format!("Failed to open stream: {}", e)))?;

            eprintln!("[QUINN] Bidirectional stream opened");

            // Create connection
            let mut conn = Self {
                connection,
                send_stream,
                recv_stream,
                page_size,
                read_buffer: Vec::new(),
            };

            // Send HELLO message
            conn.send_hello(hello_name, hello_ver, conformance).await?;

            Ok(conn)
        }
    }

    async fn send_hello(
        &mut self,
        hello_name: &str,
        hello_ver: &str,
        conformance: &str,
    ) -> Result<()> {
        let hello = serde_json::json!({
            "type": "HELLO",
            "client_name": hello_name,
            "client_ver": hello_ver,
            "wanted_conformance": conformance,
        });

        self.write_json(&hello).await?;

        // Read HELLO response
        let _response = self.read_line().await?;
        eprintln!("[QUINN] HELLO exchange completed");

        Ok(())
    }

    async fn write_json(&mut self, obj: &serde_json::Value) -> Result<()> {
        let mut line = serde_json::to_string(obj)?;
        line.push('\n');

        eprintln!("[QUINN] Writing JSON: {}", line.trim());

        self.send_stream
            .write_all(line.as_bytes())
            .await
            .map_err(|e| Error::connection(&format!("Failed to write to stream: {}", e)))?;

        Ok(())
    }

    async fn read_line(&mut self) -> Result<String> {
        let mut line = String::new();

        loop {
            // Check if we have a complete line in the buffer
            if let Some(pos) = self.read_buffer.iter().position(|&b| b == b'\n') {
                let line_bytes: Vec<u8> = self.read_buffer.drain(..=pos).collect();
                line = String::from_utf8_lossy(&line_bytes[..line_bytes.len() - 1]).to_string();
                eprintln!("[QUINN] Read line: {}", line);
                return Ok(line);
            }

            // Read more data from the stream
            let mut buf = [0u8; 4096];
            let n = tokio::time::timeout(Duration::from_secs(5), self.recv_stream.read(&mut buf))
                .await
                .map_err(|_| Error::connection("Read timeout"))?
                .map_err(|e| Error::connection(&format!("Stream read error: {}", e)))?
                .ok_or_else(|| Error::connection("Stream closed"))?;

            self.read_buffer.extend_from_slice(&buf[..n]);
        }
    }

    /// Execute a query
    pub async fn query(
        &mut self,
        text: &str,
        params: Option<HashMap<String, serde_json::Value>>,
    ) -> Result<Page> {
        let mut run_msg = serde_json::json!({"type": "RUN_GQL", "text": text});
        if let Some(p) = params {
            run_msg["params"] = serde_json::to_value(p)?;
        }

        self.write_json(&run_msg).await?;

        // Read schema
        let schema_line = self.read_line().await?;
        let schema: serde_json::Value = serde_json::from_str(&schema_line)?;

        let result = schema
            .get("result")
            .ok_or_else(|| Error::connection("Missing result"))?;
        if result.get("type").and_then(|t| t.as_str()) == Some("ERROR") {
            let code = result
                .get("code")
                .and_then(|c| c.as_str())
                .unwrap_or("UNKNOWN");
            let message = result
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("Query failed");
            return Err(Error::query(code, message));
        }

        let columns: Vec<Column> = serde_json::from_value(
            result
                .get("columns")
                .cloned()
                .unwrap_or(serde_json::json!([])),
        )?;
        let type_map: HashMap<String, String> = columns
            .iter()
            .map(|c| (c.name.clone(), c.col_type.clone()))
            .collect();

        // Send PULL
        self.write_json(&serde_json::json!({
            "type": "PULL",
            "request_id": 1,
            "page_size": self.page_size,
        }))
        .await?;

        let bindings_line = self.read_line().await?;
        let bindings: serde_json::Value = serde_json::from_str(&bindings_line)?;
        let bindings_result = bindings
            .get("result")
            .ok_or_else(|| Error::connection("Missing result"))?;

        if bindings_result.get("type").and_then(|t| t.as_str()) == Some("PROFILE") {
            return Ok(Page {
                columns,
                rows: Vec::new(),
                ordered: false,
                order_keys: Vec::new(),
                final_page: true,
            });
        }

        let empty_vec = vec![];
        let raw_rows = bindings_result
            .get("rows")
            .and_then(|r| r.as_array())
            .unwrap_or(&empty_vec);
        let rows = parse_rows(raw_rows, &type_map)?;

        Ok(Page {
            columns,
            rows,
            ordered: bindings_result
                .get("ordered")
                .and_then(|o| o.as_bool())
                .unwrap_or(false),
            order_keys: bindings_result
                .get("order_keys")
                .and_then(|ok| {
                    ok.as_array().map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect()
                    })
                })
                .unwrap_or_default(),
            final_page: bindings_result
                .get("final")
                .and_then(|f| f.as_bool())
                .unwrap_or(false),
        })
    }

    /// Begin a transaction
    pub async fn begin(&mut self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "BEGIN"}))
            .await?;
        self.read_line().await?;
        Ok(())
    }

    /// Commit a transaction
    pub async fn commit(&mut self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "COMMIT"}))
            .await?;
        self.read_line().await?;
        Ok(())
    }

    /// Rollback a transaction
    pub async fn rollback(&mut self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "ROLLBACK"}))
            .await?;
        self.read_line().await?;
        Ok(())
    }

    /// Create a savepoint within the current transaction
    pub async fn savepoint(&mut self, name: &str) -> Result<Savepoint> {
        self.write_json(&serde_json::json!({
            "type": "SAVEPOINT",
            "name": name
        }))
        .await?;
        self.read_line().await?;
        Ok(Savepoint {
            name: name.to_string(),
        })
    }

    /// Rollback to a savepoint
    pub async fn rollback_to(&mut self, savepoint: &Savepoint) -> Result<()> {
        self.write_json(&serde_json::json!({
            "type": "ROLLBACK_TO",
            "name": savepoint.name
        }))
        .await?;
        self.read_line().await?;
        Ok(())
    }

    /// Close the connection
    pub async fn close(&mut self) -> Result<()> {
        self.connection.close(0u32.into(), b"goodbye");
        Ok(())
    }
}

fn parse_rows(
    raw_rows: &[serde_json::Value],
    type_map: &HashMap<String, String>,
) -> Result<Vec<HashMap<String, Value>>> {
    let mut rows = Vec::new();
    for raw_row in raw_rows {
        if let Some(obj) = raw_row.as_object() {
            let mut row = HashMap::new();
            for (col_name, raw_value) in obj {
                let col_type = type_map.get(col_name).map(|s| s.as_str()).unwrap_or("");
                row.insert(col_name.clone(), decode_value(raw_value, col_type)?);
            }
            rows.push(row);
        }
    }
    Ok(rows)
}

fn create_transport_config() -> quinn::TransportConfig {
    let mut config = quinn::TransportConfig::default();
    config.max_idle_timeout(Some(Duration::from_secs(60).try_into().unwrap()));
    config
}

// Certificate verifier that skips all verification (insecure, for development only)
#[derive(Debug)]
struct SkipServerVerification;

impl rustls::client::danger::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::ED448,
        ]
    }
}
