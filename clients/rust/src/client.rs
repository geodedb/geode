//! Geode client implementation using quiche library for QUIC transport.

use quiche;
use ring::rand::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::time::{timeout, Duration};

use crate::error::{Error, Result};
use crate::types::{decode_value, Value};

const GEODE_ALPN: &[u8] = b"geode/1";
const MAX_DATAGRAM_SIZE: usize = 1350;
const IDLE_TIMEOUT: u64 = 30_000; // 30 seconds

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

/// Geode database client using quiche
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

/// A single connection to Geode via QUIC (using quiche)
pub struct Connection {
    socket: Arc<UdpSocket>,
    conn: quiche::Connection,
    server_addr: SocketAddr,
    page_size: usize,
    recv_buf: Vec<u8>,
    send_buf: Vec<u8>,
    stream_recv_buf: HashMap<u64, Vec<u8>>,
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
        eprintln!("[QUICHE] Creating connection to {}:{}", host, port);

        // Resolve server address
        let server_addr = format!("{}:{}", host, port)
            .to_socket_addrs()
            .map_err(|e| Error::connection(&format!("Failed to resolve address: {}", e)))?
            .next()
            .ok_or_else(|| Error::connection("No address found"))?;

        // Bind local UDP socket
        let local_addr: SocketAddr = if server_addr.is_ipv4() {
            "0.0.0.0:0"
        } else {
            "[::]:0"
        }
        .parse()
        .unwrap();

        let socket = UdpSocket::bind(local_addr)
            .await
            .map_err(|e| Error::connection(&format!("Failed to bind socket: {}", e)))?;

        let socket = Arc::new(socket);

        // Create quiche config
        let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION)
            .map_err(|e| Error::connection(&format!("Failed to create config: {:?}", e)))?;

        config.set_application_protos(&[GEODE_ALPN])
            .map_err(|e| Error::connection(&format!("Failed to set ALPN: {:?}", e)))?;

        config.set_max_idle_timeout(IDLE_TIMEOUT);
        config.set_max_recv_udp_payload_size(MAX_DATAGRAM_SIZE);
        config.set_max_send_udp_payload_size(MAX_DATAGRAM_SIZE);
        config.set_initial_max_data(10_000_000);
        config.set_initial_max_stream_data_bidi_local(1_000_000);
        config.set_initial_max_stream_data_bidi_remote(1_000_000);
        config.set_initial_max_stream_data_uni(1_000_000);
        config.set_initial_max_streams_bidi(100);
        config.set_initial_max_streams_uni(100);
        config.set_disable_active_migration(true);

        // Configure TLS
        if skip_verify {
            config.verify_peer(false);
        } else if let Some(cert_path) = ca_cert_path {
            config.load_verify_locations_from_file(cert_path)
                .map_err(|e| Error::connection(&format!("Failed to load CA cert: {:?}", e)))?;
        }

        // Generate connection ID
        let mut scid = [0; quiche::MAX_CONN_ID_LEN];
        SystemRandom::new().fill(&mut scid)
            .map_err(|e| Error::connection(&format!("Failed to generate connection ID: {:?}", e)))?;
        let scid = quiche::ConnectionId::from_ref(&scid);

        // Create connection
        let local_addr = socket.local_addr()
            .map_err(|e| Error::connection(&format!("Failed to get local address: {}", e)))?;

        let mut conn = quiche::connect(Some(host), &scid, local_addr, server_addr, &mut config)
            .map_err(|e| Error::connection(&format!("Failed to create connection: {:?}", e)))?;

        let mut out = vec![0; MAX_DATAGRAM_SIZE];

        // Send initial packet
        let (write, send_info) = conn.send(&mut out)
            .map_err(|e| Error::connection(&format!("Failed to create initial packet: {:?}", e)))?;

        socket.send_to(&out[..write], send_info.to)
            .await
            .map_err(|e| Error::connection(&format!("Failed to send initial packet: {}", e)))?;

        eprintln!("[QUICHE] Sent initial packet ({} bytes)", write);

        // Complete handshake
        let mut recv_buf = vec![0; 65535];
        let mut send_buf = vec![0; MAX_DATAGRAM_SIZE];

        let handshake_timeout = Duration::from_secs(10);
        let start = std::time::Instant::now();

        while !conn.is_established() {
            if start.elapsed() > handshake_timeout {
                return Err(Error::connection("Handshake timeout"));
            }

            // Receive packets
            match timeout(Duration::from_millis(100), socket.recv_from(&mut recv_buf)).await {
                Ok(Ok((len, from))) => {
                    let recv_info = quiche::RecvInfo {
                        to: local_addr,
                        from,
                    };

                    match conn.recv(&mut recv_buf[..len], recv_info) {
                        Ok(_) => {},
                        Err(quiche::Error::Done) => {},
                        Err(e) => {
                            eprintln!("[QUICHE] Recv error: {:?}", e);
                            return Err(Error::connection(&format!("Receive error: {:?}", e)));
                        }
                    }
                }
                Ok(Err(e)) => {
                    return Err(Error::connection(&format!("Socket recv error: {}", e)));
                }
                Err(_) => {
                    // Timeout, continue
                }
            }

            // Send any pending packets
            loop {
                let (write, send_info) = match conn.send(&mut send_buf) {
                    Ok(v) => v,
                    Err(quiche::Error::Done) => break,
                    Err(e) => {
                        return Err(Error::connection(&format!("Send error: {:?}", e)));
                    }
                };

                socket.send_to(&send_buf[..write], send_info.to)
                    .await
                    .map_err(|e| Error::connection(&format!("Socket send error: {}", e)))?;
            }
        }

        eprintln!("[QUICHE] Handshake complete");

        let mut connection = Connection {
            socket,
            conn,
            server_addr,
            page_size,
            recv_buf,
            send_buf,
            stream_recv_buf: HashMap::new(),
        };

        // Open stream for handshake
        let stream_id = connection.open_stream()
            .await
            .map_err(|e| Error::connection(&format!("Failed to open handshake stream: {}", e)))?;

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

        connection.write_stream(stream_id, hello_json.as_bytes()).await?;

        // Read HELLO response
        let response_line = connection.read_line(stream_id).await?;
        eprintln!("[QUICHE] Received HELLO response: {}", response_line.trim());

        let response: serde_json::Value = serde_json::from_str(&response_line)
            .map_err(|e| Error::protocol(&format!("Invalid HELLO response JSON: {}", e)))?;

        if response.get("type").and_then(|t| t.as_str()) != Some("HELLO") {
            return Err(Error::protocol(&format!(
                "Expected HELLO response, got: {}",
                response_line.trim()
            )));
        }

        eprintln!("[QUICHE] Handshake complete");

        Ok(connection)
    }

    /// Open a bidirectional stream
    async fn open_stream(&mut self) -> Result<u64> {
        // Try to open a stream
        loop {
            match self.conn.stream_writable_next() {
                Some(stream_id) if stream_id % 4 == 0 => {
                    // Client-initiated bidirectional stream
                    return Ok(stream_id);
                }
                _ => {}
            }

            // No writable stream available, create new one
            let mut stream_id = 0u64;
            while stream_id < 1000 {
                if self.conn.stream_writable(stream_id, 1).unwrap_or(false) {
                    return Ok(stream_id);
                }
                stream_id += 4; // Client-initiated bidirectional streams are 0, 4, 8, ...
            }

            // If we can't open a stream, try processing events
            self.process_events().await?;

            // Brief yield to allow other tasks to run
            tokio::task::yield_now().await;
        }
    }

    /// Write data to a stream
    async fn write_stream(&mut self, stream_id: u64, data: &[u8]) -> Result<()> {
        let mut offset = 0;
        while offset < data.len() {
            match self.conn.stream_send(stream_id, &data[offset..], false) {
                Ok(written) => {
                    offset += written;
                }
                Err(quiche::Error::Done) => {
                    // Wait and retry
                    self.process_events().await?;
                    tokio::task::yield_now().await;
                }
                Err(e) => {
                    return Err(Error::protocol(&format!("Stream write error: {:?}", e)));
                }
            }
        }

        // Flush by sending packets
        self.flush().await?;

        Ok(())
    }

    /// Read a line from a stream (newline-delimited)
    async fn read_line(&mut self, stream_id: u64) -> Result<String> {
        loop {
            // Scope the mutable borrow of stream_recv_buf
            {
                let buf = self.stream_recv_buf.entry(stream_id).or_insert_with(Vec::new);

                // Check if we have a complete line
                if let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                    let line: Vec<u8> = buf.drain(..=pos).collect();
                    return String::from_utf8(line)
                        .map_err(|e| Error::protocol(&format!("Invalid UTF-8: {}", e)));
                }
            }

            // Read more data (borrow is now released)
            let mut stream_buf = vec![0; 65535];
            match self.conn.stream_recv(stream_id, &mut stream_buf) {
                Ok((len, _fin)) => {
                    let buf = self.stream_recv_buf.entry(stream_id).or_insert_with(Vec::new);
                    buf.extend_from_slice(&stream_buf[..len]);
                }
                Err(quiche::Error::Done) => {
                    // No data available, process events and wait
                    self.process_events().await?;
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
                Err(e) => {
                    return Err(Error::protocol(&format!("Stream read error: {:?}", e)));
                }
            }
        }
    }

    /// Process network events (send/receive packets)
    async fn process_events(&mut self) -> Result<()> {
        // Send any pending packets
        loop {
            let (write, send_info) = match self.conn.send(&mut self.send_buf) {
                Ok(v) => v,
                Err(quiche::Error::Done) => break,
                Err(e) => {
                    return Err(Error::connection(&format!("Send error: {:?}", e)));
                }
            };

            self.socket.send_to(&self.send_buf[..write], send_info.to)
                .await
                .map_err(|e| Error::connection(&format!("Socket send error: {}", e)))?;
        }

        // Try to receive packets (non-blocking)
        loop {
            match timeout(Duration::from_millis(1),
                         self.socket.recv_from(&mut self.recv_buf)).await {
                Ok(Ok((len, from))) => {
                    let local_addr = self.socket.local_addr()
                        .map_err(|e| Error::connection(&format!("Failed to get local addr: {}", e)))?;

                    let recv_info = quiche::RecvInfo {
                        to: local_addr,
                        from,
                    };

                    match self.conn.recv(&mut self.recv_buf[..len], recv_info) {
                        Ok(_) => {},
                        Err(quiche::Error::Done) => {},
                        Err(e) => {
                            return Err(Error::connection(&format!("Receive error: {:?}", e)));
                        }
                    }
                }
                Ok(Err(e)) => {
                    return Err(Error::connection(&format!("Socket recv error: {}", e)));
                }
                Err(_) => {
                    // Timeout, no more packets
                    break;
                }
            }
        }

        Ok(())
    }

    /// Flush pending data
    async fn flush(&mut self) -> Result<()> {
        self.process_events().await
    }

    /// Execute a GQL query
    pub async fn query(
        &mut self,
        text: &str,
        params: Option<HashMap<String, serde_json::Value>>,
    ) -> Result<Page> {
        // Open new stream for query
        let stream_id = self.open_stream().await?;

        // Send RUN_GQL message
        let run_msg = if let Some(p) = params {
            serde_json::json!({"type": "RUN_GQL", "text": text, "params": p})
        } else {
            serde_json::json!({"type": "RUN_GQL", "text": text})
        };

        let mut run_json = serde_json::to_string(&run_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize RUN_GQL: {}", e)))?;
        run_json.push('\n');

        self.write_stream(stream_id, run_json.as_bytes()).await?;

        // Receive SCHEMA message
        let schema_line = self.read_line(stream_id).await?;
        let schema_msg: serde_json::Value = serde_json::from_str(&schema_line)
            .map_err(|e| Error::protocol(&format!("Invalid SCHEMA JSON: {}", e)))?;

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

        let mut pull_json = serde_json::to_string(&pull_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize PULL: {}", e)))?;
        pull_json.push('\n');

        self.write_stream(stream_id, pull_json.as_bytes()).await?;

        // Receive BINDINGS message
        let bindings_line = self.read_line(stream_id).await?;
        let bindings_msg: serde_json::Value = serde_json::from_str(&bindings_line)
            .map_err(|e| Error::protocol(&format!("Invalid BINDINGS JSON: {}", e)))?;

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
        let stream_id = self.open_stream().await?;

        let begin_msg = serde_json::json!({"type": "BEGIN"});
        let mut begin_json = serde_json::to_string(&begin_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize BEGIN: {}", e)))?;
        begin_json.push('\n');

        self.write_stream(stream_id, begin_json.as_bytes()).await?;

        let response_line = self.read_line(stream_id).await?;
        let response: serde_json::Value = serde_json::from_str(&response_line)
            .map_err(|e| Error::protocol(&format!("Invalid BEGIN response: {}", e)))?;

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
        let stream_id = self.open_stream().await?;

        let commit_msg = serde_json::json!({"type": "COMMIT"});
        let mut commit_json = serde_json::to_string(&commit_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize COMMIT: {}", e)))?;
        commit_json.push('\n');

        self.write_stream(stream_id, commit_json.as_bytes()).await?;

        let response_line = self.read_line(stream_id).await?;
        let response: serde_json::Value = serde_json::from_str(&response_line)
            .map_err(|e| Error::protocol(&format!("Invalid COMMIT response: {}", e)))?;

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
        let stream_id = self.open_stream().await?;

        let rollback_msg = serde_json::json!({"type": "ROLLBACK"});
        let mut rollback_json = serde_json::to_string(&rollback_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize ROLLBACK: {}", e)))?;
        rollback_json.push('\n');

        self.write_stream(stream_id, rollback_json.as_bytes()).await?;

        let response_line = self.read_line(stream_id).await?;
        let response: serde_json::Value = serde_json::from_str(&response_line)
            .map_err(|e| Error::protocol(&format!("Invalid ROLLBACK response: {}", e)))?;

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
        let stream_id = self.open_stream().await?;

        let close_msg = serde_json::json!({"type": "GOODBYE"});
        let mut close_json = serde_json::to_string(&close_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize GOODBYE: {}", e)))?;
        close_json.push('\n');

        self.write_stream(stream_id, close_json.as_bytes()).await?;

        // Try to read response, but don't fail if we can't
        let _ = timeout(Duration::from_millis(500), self.read_line(stream_id)).await;

        // Close the QUIC connection
        self.conn.close(true, 0x00, b"goodbye")
            .map_err(|e| Error::connection(&format!("Failed to close connection: {:?}", e)))?;

        self.flush().await?;

        Ok(())
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        // Connection will be closed automatically
        let _ = self.conn.close(true, 0x00, b"dropped");
    }
}
