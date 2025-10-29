//! Geode client implementation using Cloudflare's quiche library for QUIC transport.

use quiche;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{SocketAddr, ToSocketAddrs, UdpSocket};
use std::time::{Duration, Instant};

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

/// Geode database client using quiche
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
    pub fn connect(&self) -> Result<Connection> {
        Connection::new(
            &self.host,
            self.port,
            self.skip_verify,
            self.page_size,
            &self.hello_name,
            &self.hello_ver,
            &self.conformance,
        )
    }
}

/// A single connection to Geode via QUIC (using quiche)
pub struct Connection {
    socket: UdpSocket,
    conn: quiche::Connection,
    page_size: usize,
    peer_addr: SocketAddr,
    stream_id: u64,
    recv_buffer: Vec<u8>,
    send_buffer: Vec<u8>,
}

impl Connection {
    fn new(
        host: &str,
        port: u16,
        skip_verify: bool,
        page_size: usize,
        hello_name: &str,
        hello_ver: &str,
        conformance: &str,
    ) -> Result<Self> {
        eprintln!("[QUICHE] Creating connection to {}:{}", host, port);

        // Resolve server address
        let addr_str = format!("{}:{}", host, port);
        let peer_addr: SocketAddr = addr_str
            .to_socket_addrs()
            .map_err(|e| Error::connection(&format!("Failed to resolve address {}: {}", addr_str, e)))?
            .next()
            .ok_or_else(|| Error::connection(&format!("No addresses found for {}", addr_str)))?;

        eprintln!("[QUICHE] Resolved server address: {}", peer_addr);

        // Bind local UDP socket
        let bind_addr = if peer_addr.is_ipv6() {
            "[::]:0"
        } else {
            "0.0.0.0:0"
        };

        let socket = UdpSocket::bind(bind_addr)
            .map_err(|e| Error::connection(&format!("Failed to bind socket: {}", e)))?;

        socket.set_nonblocking(true)
            .map_err(|e| Error::connection(&format!("Failed to set nonblocking: {}", e)))?;

        eprintln!("[QUICHE] Bound local socket to: {:?}", socket.local_addr());

        // Configure QUIC
        let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION)
            .map_err(|e| Error::connection(&format!("Failed to create QUIC config: {}", e)))?;

        // Set ALPN protocol
        config
            .set_application_protos(&[b"geode/1"])
            .map_err(|e| Error::connection(&format!("Failed to set ALPN: {}", e)))?;

        // Configure TLS
        if skip_verify {
            config.verify_peer(false);
            eprintln!("[QUICHE] TLS peer verification DISABLED (skip_verify=true)");
        } else {
            // Try to load CA certificate
            let test_ca_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../test-harness/certs/ca.crt");

            if test_ca_path.exists() {
                eprintln!("[QUICHE] Loading CA certificate from: {:?}", test_ca_path);
                config.load_verify_locations_from_file(test_ca_path.to_str().unwrap())
                    .map_err(|e| Error::connection(&format!("Failed to load CA cert: {}", e)))?;
            } else {
                eprintln!("[QUICHE] No CA certificate found, using system trust store");
            }
        }

        // Set transport parameters
        config.set_max_idle_timeout(60000); // 60 seconds
        config.set_max_recv_udp_payload_size(4096);
        config.set_max_send_udp_payload_size(4096);
        config.set_initial_max_data(10_000_000);
        config.set_initial_max_stream_data_bidi_local(1_000_000);
        config.set_initial_max_stream_data_bidi_remote(1_000_000);
        config.set_initial_max_streams_bidi(100);
        config.set_disable_active_migration(true);

        // Generate connection ID (scid - source connection ID)
        let mut scid = [0; quiche::MAX_CONN_ID_LEN];
        use ring::rand::SecureRandom;
        ring::rand::SystemRandom::new().fill(&mut scid)
            .map_err(|_| Error::connection("Failed to generate connection ID"))?;
        let scid = quiche::ConnectionId::from_ref(&scid);

        eprintln!("[QUICHE] Creating QUIC connection with scid: {:?}", scid);

        // Get local socket address
        let local_addr = socket.local_addr()
            .map_err(|e| Error::connection(&format!("Failed to get local address: {}", e)))?;

        // Create QUIC connection
        let mut conn = quiche::connect(Some(&host), &scid, local_addr, peer_addr, &mut config)
            .map_err(|e| Error::connection(&format!("Failed to create connection: {}", e)))?;

        eprintln!("[QUICHE] QUIC connection created, starting handshake");

        // Prepare buffers
        let mut out = vec![0; 4096];
        let mut recv_buffer = vec![0; 65535];
        let send_buffer = Vec::new();

        // Send initial packet (ClientHello)
        let (write, send_info) = conn.send(&mut out)
            .map_err(|e| Error::connection(&format!("Failed to send initial packet: {}", e)))?;

        eprintln!("[QUICHE] Sending initial packet ({} bytes) to {}", write, send_info.to);
        socket.send_to(&out[..write], send_info.to)
            .map_err(|e| Error::connection(&format!("Failed to send UDP packet: {}", e)))?;

        // Handshake loop with timeout
        let start = Instant::now();
        let timeout = Duration::from_secs(10);

        while !conn.is_established() {
            if start.elapsed() > timeout {
                eprintln!("[QUICHE] Handshake timeout after {} seconds", timeout.as_secs());
                eprintln!("[QUICHE] Connection state: is_established={}, is_in_early_data={}",
                    conn.is_established(), conn.is_in_early_data());
                return Err(Error::connection("Handshake timeout"));
            }

            // Check if connection is established now
            if conn.is_established() {
                eprintln!("[QUICHE] Handshake complete!");
                break;
            }

            // Try to receive packets (non-blocking)
            match socket.recv_from(&mut recv_buffer) {
                Ok((len, from)) => {
                    eprintln!("[QUICHE] Received {} bytes from {}", len, from);

                    // Process received packet
                    let recv_info = quiche::RecvInfo {
                        to: socket.local_addr().unwrap(),
                        from,
                    };

                    match conn.recv(&mut recv_buffer[..len], recv_info) {
                        Ok(bytes_read) => {
                            eprintln!("[QUICHE] Packet processed successfully ({} bytes)", bytes_read);
                            eprintln!("[QUICHE] Connection is_established: {}", conn.is_established());
                        }
                        Err(quiche::Error::Done) => {
                            eprintln!("[QUICHE] Packet processing done (no more data)");
                        }
                        Err(e) => {
                            eprintln!("[QUICHE] Failed to process packet: {}", e);
                            // Don't fail immediately, might be transient
                        }
                    }

                    // After processing, send any pending packets
                    loop {
                        let (write, send_info) = match conn.send(&mut out) {
                            Ok(v) => v,
                            Err(quiche::Error::Done) => break,
                            Err(e) => {
                                eprintln!("[QUICHE] Send error: {}", e);
                                return Err(Error::connection(&format!("QUIC send error: {}", e)));
                            }
                        };

                        eprintln!("[QUICHE] Sending {} bytes to {}", write, send_info.to);
                        socket.send_to(&out[..write], send_info.to)
                            .map_err(|e| Error::connection(&format!("Failed to send UDP packet: {}", e)))?;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // No data available, but still try to send any pending packets
                    loop {
                        let (write, send_info) = match conn.send(&mut out) {
                            Ok(v) => v,
                            Err(quiche::Error::Done) => break,
                            Err(e) => {
                                eprintln!("[QUICHE] Send error: {}", e);
                                return Err(Error::connection(&format!("QUIC send error: {}", e)));
                            }
                        };

                        eprintln!("[QUICHE] Sending {} bytes to {} (no incoming data)", write, send_info.to);
                        socket.send_to(&out[..write], send_info.to)
                            .map_err(|e| Error::connection(&format!("Failed to send UDP packet: {}", e)))?;
                    }

                    // Small sleep before retrying
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => {
                    eprintln!("[QUICHE] Socket recv error: {}", e);
                    return Err(Error::connection(&format!("Socket recv error: {}", e)));
                }
            }
        }

        eprintln!("[QUICHE] Handshake completed! Connection established");

        // Open bidirectional stream
        let stream_id = conn.stream_writable_next()
            .ok_or_else(|| Error::connection("No writable streams available"))?;

        eprintln!("[QUICHE] Opened stream ID: {}", stream_id);

        let mut connection = Self {
            socket,
            conn,
            page_size,
            peer_addr,
            stream_id,
            recv_buffer,
            send_buffer,
        };

        // Send HELLO message
        let hello = serde_json::json!({
            "type": "HELLO",
            "client_name": hello_name,
            "client_ver": hello_ver,
            "wanted_conformance": conformance,
        });

        connection.write_json(&hello)?;
        connection.flush()?;

        // Read HELLO response
        let _response = connection.read_line()?;
        eprintln!("[QUICHE] HELLO exchange completed");

        Ok(connection)
    }

    fn write_json(&mut self, obj: &serde_json::Value) -> Result<()> {
        let mut line = serde_json::to_string(obj)?;
        line.push('\n');

        eprintln!("[QUICHE] Writing JSON: {}", line.trim());

        // Write to stream
        self.conn.stream_send(self.stream_id, line.as_bytes(), false)
            .map_err(|e| Error::connection(&format!("Failed to write to stream: {}", e)))?;

        Ok(())
    }

    fn flush(&mut self) -> Result<()> {
        let mut out = vec![0; 4096];

        // Send all pending data
        loop {
            let (write, send_info) = match self.conn.send(&mut out) {
                Ok(v) => v,
                Err(quiche::Error::Done) => break,
                Err(e) => return Err(Error::connection(&format!("Flush error: {}", e))),
            };

            self.socket.send_to(&out[..write], send_info.to)
                .map_err(|e| Error::connection(&format!("Failed to send UDP packet: {}", e)))?;
        }

        Ok(())
    }

    fn read_line(&mut self) -> Result<String> {
        let mut line = String::new();
        let start = Instant::now();
        let timeout = Duration::from_secs(5);

        loop {
            if start.elapsed() > timeout {
                return Err(Error::connection("Read timeout"));
            }

            // Try to receive packets from network
            match self.socket.recv_from(&mut self.recv_buffer) {
                Ok((len, from)) => {
                    let recv_info = quiche::RecvInfo {
                        to: self.socket.local_addr().unwrap(),
                        from,
                    };

                    self.conn.recv(&mut self.recv_buffer[..len], recv_info)
                        .map_err(|e| Error::connection(&format!("QUIC recv error: {}", e)))?;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // No network data, continue to check stream data
                }
                Err(e) => return Err(Error::connection(&format!("Socket error: {}", e))),
            }

            // Try to read from stream
            let mut buf = vec![0; 65535];
            match self.conn.stream_recv(self.stream_id, &mut buf) {
                Ok((len, fin)) => {
                    let data = String::from_utf8_lossy(&buf[..len]);
                    line.push_str(&data);

                    if line.contains('\n') {
                        // Found complete line
                        let newline_pos = line.find('\n').unwrap();
                        let result = line[..newline_pos].to_string();
                        eprintln!("[QUICHE] Read line: {}", result);
                        return Ok(result);
                    }

                    if fin {
                        return Ok(line);
                    }
                }
                Err(quiche::Error::Done) => {
                    // No data available yet, sleep briefly
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => return Err(Error::connection(&format!("Stream recv error: {}", e))),
            }
        }
    }

    /// Execute a query
    pub fn query(&mut self, text: &str, params: Option<HashMap<String, serde_json::Value>>) -> Result<Page> {
        let mut run_msg = serde_json::json!({"type": "RUN_GQL", "text": text});
        if let Some(p) = params {
            run_msg["params"] = serde_json::to_value(p)?;
        }

        self.write_json(&run_msg)?;
        self.flush()?;

        // Read schema
        let schema_line = self.read_line()?;
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
        }))?;
        self.flush()?;

        let bindings_line = self.read_line()?;
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
    pub fn begin(&mut self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "BEGIN"}))?;
        self.flush()?;
        self.read_line()?;
        Ok(())
    }

    /// Commit a transaction
    pub fn commit(&mut self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "COMMIT"}))?;
        self.flush()?;
        self.read_line()?;
        Ok(())
    }

    /// Rollback a transaction
    pub fn rollback(&mut self) -> Result<()> {
        self.write_json(&serde_json::json!({"type": "ROLLBACK"}))?;
        self.flush()?;
        self.read_line()?;
        Ok(())
    }

    /// Close the connection
    pub fn close(&mut self) -> Result<()> {
        self.conn.close(true, 0, b"goodbye")
            .map_err(|e| Error::connection(&format!("Failed to close connection: {}", e)))?;
        self.flush()?;
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
