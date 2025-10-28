//! Core client implementation for Geode.

use quinn::{ClientConfig, Connection as QuinnConnection, Endpoint, RecvStream, SendStream};
use rustls::{Certificate, ClientConfig as RustlsClientConfig, RootCertStore, ServerName};
use rustls::client::{ServerCertVerifier, ServerCertVerified, HandshakeSignatureValid};
use rustls::{DigitallySignedStruct, Error as RustlsError, SignatureScheme};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::Arc;
use std::time::SystemTime;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use tokio::sync::Mutex;

use crate::error::{Error, Result};
use crate::types::{decode_value, Value};

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

/// Skip TLS verification (insecure, for development only)
#[derive(Debug)]
struct SkipServerVerification;

impl ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &Certificate,
        _intermediates: &[Certificate],
        _server_name: &ServerName,
        _scts: &mut dyn Iterator<Item = &[u8]>,
        _ocsp_response: &[u8],
        _now: SystemTime,
    ) -> std::result::Result<ServerCertVerified, RustlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &Certificate,
        _dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, RustlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &Certificate,
        _dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, RustlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ED25519,
        ]
    }
}

/// Geode database client
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
            hello_name: "geode-rust".to_string(),
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

    /// Connect to the database
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

/// A single connection to Geode via QUIC
pub struct Connection {
    connection: QuinnConnection,
    send_stream: Mutex<BufWriter<SendStream>>,
    recv_stream: Mutex<BufReader<RecvStream>>,
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
        // Configure TLS (rustls 0.21 API - uses builder pattern)
        let mut crypto = if skip_verify {
            let mut config = RustlsClientConfig::builder()
                .with_safe_default_cipher_suites()
                .with_safe_default_kx_groups()
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
                .with_no_client_auth();
            config
        } else {
            // Try to load test harness CA certificate
            let mut root_store = RootCertStore::empty();

            let test_ca_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../test-harness/certs/ca.crt");

            if test_ca_path.exists() {
                eprintln!("[DEBUG] Loading test harness CA from: {:?}", test_ca_path);
                let ca_file = std::fs::File::open(&test_ca_path)
                    .map_err(|e| Error::connection(&format!("Failed to open CA file: {}", e)))?;
                let mut ca_reader = std::io::BufReader::new(ca_file);

                let certs = rustls_pemfile::certs(&mut ca_reader)
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| Error::connection(&format!("Failed to parse CA certs: {}", e)))?;

                for cert in certs {
                    root_store.add(cert)
                        .map_err(|e| Error::connection(&format!("Failed to add CA cert: {}", e)))?;
                }
                eprintln!("[DEBUG] Successfully loaded CA certificate");
            } else {
                eprintln!("[DEBUG] No test harness CA found at {:?}, using empty root store", test_ca_path);
            }

            let mut config = RustlsClientConfig::builder()
                .with_safe_default_cipher_suites()
                .with_safe_default_kx_groups()
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_root_certificates(root_store)
                .with_no_client_auth();
            config
        };

        crypto.alpn_protocols = vec![b"geode/1".to_vec()];

        let mut client_config = ClientConfig::new(Arc::new(crypto));
        let mut transport_config = quinn::TransportConfig::default();
        transport_config.max_idle_timeout(Some(std::time::Duration::from_secs(60).try_into().unwrap()));
        // Allow receiving larger UDP packets from server (for large TLS certificates)
        transport_config.receive_window(quinn::VarInt::from_u32(8 * 1024 * 1024));
        transport_config.send_window(8 * 1024 * 1024);
        client_config.transport_config(Arc::new(transport_config));

        // Create endpoint with larger UDP payload size (bind to IPv4 to match server)
        let mut endpoint_config = quinn::EndpointConfig::default();
        endpoint_config.max_udp_payload_size(4096)?;

        let socket = std::net::UdpSocket::bind("0.0.0.0:0")?;
        let mut endpoint = Endpoint::new(endpoint_config, None, socket, Arc::new(quinn::TokioRuntime))?;
        endpoint.set_default_client_config(client_config);

        // Resolve address
        let addr_str = format!("{}:{}", host, port);
        let addr: SocketAddr = addr_str.to_socket_addrs()
            .map_err(|e| Error::connection(&format!("Failed to resolve address {}: {}", addr_str, e)))?
            .next()
            .ok_or_else(|| Error::connection(&format!("No addresses found for {}", addr_str)))?;

        // Connect with timeout
        let connection = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            endpoint.connect(addr, host)?
        )
            .await
            .map_err(|_| Error::connection("Connection timeout"))?
            .map_err(|e| Error::connection(&format!("QUIC connection failed: {}", e)))?;

        // Open bidirectional stream with timeout
        let (send, recv) = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            connection.open_bi()
        )
            .await
            .map_err(|_| Error::connection("Stream open timeout"))?
            .map_err(|e| Error::connection(&format!("Failed to open stream: {}", e)))?;

        let mut conn = Self {
            connection,
            send_stream: Mutex::new(BufWriter::new(send)),
            recv_stream: Mutex::new(BufReader::new(recv)),
            page_size,
        };

        // Send HELLO
        let hello = serde_json::json!({
            "type": "HELLO",
            "client_name": hello_name,
            "client_ver": hello_ver,
            "wanted_conformance": conformance,
        });
        conn.write_json(&hello).await?;

        // Read HELLO response with timeout
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            conn.read_line()
        )
            .await
            .map_err(|_| Error::connection("HELLO response timeout"))?
            .map_err(|e| Error::connection(&format!("Failed to read HELLO response: {}", e)))?;

        Ok(conn)
    }

    async fn write_json(&self, obj: &serde_json::Value) -> Result<()> {
        let mut writer = self.send_stream.lock().await;
        let mut line = serde_json::to_string(obj)?;
        line.push('\n');
        writer.write_all(line.as_bytes()).await?;
        writer.flush().await?;
        Ok(())
    }

    async fn read_line(&self) -> Result<String> {
        let mut reader = self.recv_stream.lock().await;
        let mut line = String::new();
        reader.read_line(&mut line).await?;
        Ok(line.trim_end().to_string())
    }

    /// Execute a query
    pub async fn query(&self, text: &str, params: Option<HashMap<String, serde_json::Value>>) -> Result<Page> {
        let mut run_msg = serde_json::json!({"type": "RUN_GQL", "text": text});
        if let Some(p) = params {
            run_msg["params"] = serde_json::to_value(p)?;
        }

        self.write_json(&run_msg).await?;

        // Read schema
        let schema_line = self.read_line().await?;
        let schema: serde_json::Value = serde_json::from_str(&schema_line)?;

        let result = schema.get("result").ok_or_else(|| Error::connection("Missing result"))?;
        if result.get("type").and_then(|t| t.as_str()) == Some("ERROR") {
            let code = result.get("code").and_then(|c| c.as_str()).unwrap_or("UNKNOWN");
            let message = result.get("message").and_then(|m| m.as_str()).unwrap_or("Query failed");
            return Err(Error::query(code, message));
        }

        let columns: Vec<Column> = serde_json::from_value(
            result.get("columns").cloned().unwrap_or(serde_json::json!([]))
        )?;
        let type_map: HashMap<String, String> = columns.iter()
            .map(|c| (c.name.clone(), c.col_type.clone()))
            .collect();

        // Send PULL
        self.write_json(&serde_json::json!({
            "type": "PULL",
            "request_id": 1,
            "page_size": self.page_size,
        })).await?;

        let bindings_line = self.read_line().await?;
        let bindings: serde_json::Value = serde_json::from_str(&bindings_line)?;
        let bindings_result = bindings.get("result").ok_or_else(|| Error::connection("Missing result"))?;

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
        let raw_rows = bindings_result.get("rows").and_then(|r| r.as_array()).unwrap_or(&empty_vec);
        let rows = parse_rows(raw_rows, &type_map)?;

        Ok(Page {
            columns,
            rows,
            ordered: bindings_result.get("ordered").and_then(|o| o.as_bool()).unwrap_or(false),
            order_keys: bindings_result.get("order_keys").and_then(|ok| {
                ok.as_array().map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            }).unwrap_or_default(),
            final_page: bindings_result.get("final").and_then(|f| f.as_bool()).unwrap_or(false),
        })
    }

    /// Begin a transaction
    pub async fn begin(&self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "BEGIN"})).await?;
        self.read_line().await?;
        Ok(())
    }

    /// Commit a transaction
    pub async fn commit(&self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "COMMIT"})).await?;
        self.read_line().await?;
        Ok(())
    }

    /// Rollback a transaction
    pub async fn rollback(&self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "ROLLBACK"})).await?;
        self.read_line().await?;
        Ok(())
    }

    /// Close the connection
    pub async fn close(&self) -> Result<()> {
        self.connection.close(0u32.into(), b"goodbye");
        Ok(())
    }
}


fn parse_rows(raw_rows: &[serde_json::Value], type_map: &HashMap<String, String>) -> Result<Vec<HashMap<String, Value>>> {
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
