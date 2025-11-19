//! Geode client implementation using Quiche library for QUIC transport.
//! Migrated from Quinn to Quiche for better BoringSSL/msquic compatibility.

use mio::net::UdpSocket;
use ring::rand::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{SocketAddr, ToSocketAddrs};
use std::time::Duration;

use crate::error::{Error, Result};
use crate::types::Value;

const GEODE_ALPN: &[u8] = b"geode/1";
const MAX_DATAGRAM_SIZE: usize = 1350;

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

/// Geode database client using Quiche
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
            hello_name: "geode-rust-quiche".to_string(),
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

    /// Connect to the database (synchronous with Quiche)
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

/// A single connection to Geode via QUIC (using Quiche)
pub struct Connection {
    conn: quiche::Connection,
    socket: UdpSocket,
    peer_addr: SocketAddr,
    page_size: usize,
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
        let peer_addr = format!("{}:{}", host, port)
            .to_socket_addrs()
            .map_err(|e| Error::connection(&format!("Failed to resolve address: {}", e)))?
            .next()
            .ok_or_else(|| Error::connection("No address found"))?;

        // Dynamic IPv4/IPv6 binding (same fix as Quinn)
        let bind_addr = match peer_addr {
            SocketAddr::V4(_) => "0.0.0.0:0",
            SocketAddr::V6(_) => "[::]:0",
        };

        eprintln!("[QUICHE] Binding to {} (peer: {})", bind_addr, peer_addr);

        // Create UDP socket
        let socket = UdpSocket::bind(bind_addr.parse().unwrap())
            .map_err(|e| Error::connection(&format!("Failed to bind socket: {}", e)))?;

        // Create Quiche config
        let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION)
            .map_err(|e| Error::connection(&format!("Failed to create config: {}", e)))?;

        // Configure TLS
        if skip_verify {
            eprintln!("[QUICHE] Skipping certificate verification (insecure)");
            config.verify_peer(false);
        }

        // Set ALPN
        config
            .set_application_protos(&[GEODE_ALPN])
            .map_err(|e| Error::connection(&format!("Failed to set ALPN: {}", e)))?;

        // Set QUIC transport parameters (matching Go client)
        config.set_max_idle_timeout(30000);
        config.set_max_recv_udp_payload_size(MAX_DATAGRAM_SIZE);
        config.set_max_send_udp_payload_size(MAX_DATAGRAM_SIZE);
        config.set_initial_max_data(10_000_000);
        config.set_initial_max_stream_data_bidi_local(1_000_000);
        config.set_initial_max_stream_data_bidi_remote(1_000_000);
        config.set_initial_max_streams_bidi(100);
        config.set_initial_max_streams_uni(100);
        config.set_disable_active_migration(true);

        // Generate random source connection ID
        let mut scid = [0; quiche::MAX_CONN_ID_LEN];
        SystemRandom::new().fill(&mut scid[..]).unwrap();
        let scid = quiche::ConnectionId::from_ref(&scid);

        let local_addr = socket.local_addr().unwrap();

        eprintln!("[QUICHE] Connecting with scid={:?}", scid);

        // Create connection
        let mut conn = quiche::connect(Some(host), &scid, local_addr, peer_addr, &mut config)
            .map_err(|e| Error::connection(&format!("Failed to create connection: {}", e)))?;

        // Send initial packet
        let mut out = [0; MAX_DATAGRAM_SIZE];
        let (write, send_info) = conn.send(&mut out)
            .map_err(|e| Error::connection(&format!("Failed to send initial packet: {}", e)))?;

        socket.send_to(&out[..write], send_info.to)
            .map_err(|e| Error::connection(&format!("Failed to send UDP packet: {}", e)))?;

        eprintln!("[QUICHE] Sent initial {} bytes to {}", write, send_info.to);

        // Handshake loop with timeout
        let start = std::time::Instant::now();
        let handshake_timeout = Duration::from_secs(10);
        let mut buf = [0; 65535];

        while !conn.is_established() {
            if start.elapsed() > handshake_timeout {
                return Err(Error::connection("Handshake timeout"));
            }

            // Receive packets
            match socket.recv_from(&mut buf) {
                Ok((len, from)) => {
                    eprintln!("[QUICHE] Received {} bytes from {}", len, from);

                    let recv_info = quiche::RecvInfo {
                        to: local_addr,
                        from,
                    };

                    match conn.recv(&mut buf[..len], recv_info) {
                        Ok(_) => {
                            eprintln!("[QUICHE] Processed packet successfully");
                        }
                        Err(quiche::Error::Done) => {
                            eprintln!("[QUICHE] No more data to process");
                        }
                        Err(e) => {
                            eprintln!("[QUICHE] recv error: {:?}", e);
                        }
                    }
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    eprintln!("[QUICHE] Would block, checking timeout...");
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => {
                    return Err(Error::connection(&format!("Socket recv error: {}", e)));
                }
            }

            // Send outgoing packets
            loop {
                let (write, send_info) = match conn.send(&mut out) {
                    Ok(v) => v,
                    Err(quiche::Error::Done) => break,
                    Err(e) => return Err(Error::connection(&format!("Send error: {}", e))),
                };

                socket.send_to(&out[..write], send_info.to)
                    .map_err(|e| Error::connection(&format!("Socket send error: {}", e)))?;

                eprintln!("[QUICHE] Sent {} bytes", write);
            }

            // Handle timeout
            conn.on_timeout();
        }

        eprintln!("[QUICHE] ✓ Connection established!");

        let mut connection = Connection {
            conn,
            socket,
            peer_addr,
            page_size,
        };

        // Send HELLO message
        connection.send_hello(hello_name, hello_ver, conformance)?;

        Ok(connection)
    }

    fn send_hello(&mut self, name: &str, ver: &str, conformance: &str) -> Result<()> {
        let hello_msg = serde_json::json!({
            "type": "HELLO",
            "client_name": name,
            "client_ver": ver,
            "wanted_conformance": conformance
        });

        let mut hello_json = serde_json::to_string(&hello_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize HELLO: {}", e)))?;
        hello_json.push('\n');

        // Open bidirectional stream (stream ID 0)
        let stream_id = 0;
        self.conn.stream_send(stream_id, hello_json.as_bytes(), false)
            .map_err(|e| Error::connection(&format!("Failed to send HELLO: {}", e)))?;

        eprintln!("[QUICHE] Sent HELLO on stream {}", stream_id);

        // Read HELLO response
        let mut buf = [0; 65535];
        let response = self.read_stream_line(stream_id, &mut buf)?;

        eprintln!("[QUICHE] Received HELLO response: {}", response);

        let response_json: serde_json::Value = serde_json::from_str(&response)
            .map_err(|e| Error::protocol(&format!("Invalid HELLO response: {}", e)))?;

        if response_json.get("type").and_then(|t| t.as_str()) != Some("HELLO") {
            return Err(Error::protocol("Expected HELLO response"));
        }

        Ok(())
    }

    fn read_stream_line(&mut self, stream_id: u64, buf: &mut [u8]) -> Result<String> {
        let mut line = Vec::new();
        let mut total_read = 0;

        loop {
            match self.conn.stream_recv(stream_id, &mut buf[total_read..]) {
                Ok((read, _fin)) => {
                    total_read += read;
                    line.extend_from_slice(&buf[..total_read]);

                    // Check for newline
                    if let Some(pos) = line.iter().position(|&b| b == b'\n') {
                        let result = String::from_utf8_lossy(&line[..pos]).to_string();
                        return Ok(result);
                    }
                }
                Err(quiche::Error::Done) => {
                    // Need more data, continue event loop
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => {
                    return Err(Error::connection(&format!("Stream recv error: {:?}", e)));
                }
            }
        }
    }

    /// Execute a GQL query
    pub fn query(
        &mut self,
        text: &str,
        _params: Option<HashMap<String, serde_json::Value>>,
    ) -> Result<Page> {
        // Simplified implementation for testing
        let run_msg = serde_json::json!({"type": "RUN_GQL", "text": text});
        let mut run_json = serde_json::to_string(&run_msg)
            .map_err(|e| Error::protocol(&format!("Failed to serialize RUN_GQL: {}", e)))?;
        run_json.push('\n');

        // Send on new stream
        let stream_id = 4; // Next available stream
        self.conn.stream_send(stream_id, run_json.as_bytes(), false)
            .map_err(|e| Error::connection(&format!("Failed to send query: {}", e)))?;

        // Read SCHEMA response
        let mut buf = [0; 65535];
        let schema_line = self.read_stream_line(stream_id, &mut buf)?;

        let schema_msg: serde_json::Value = serde_json::from_str(&schema_line)
            .map_err(|e| Error::protocol(&format!("Invalid SCHEMA: {}", e)))?;

        let columns: Vec<Column> = serde_json::from_value(
            schema_msg.get("columns").ok_or_else(|| Error::protocol("Missing columns"))?.clone()
        ).map_err(|e| Error::protocol(&format!("Invalid columns: {}", e)))?;

        // Read rows (simplified)
        let rows = Vec::new();

        Ok(Page {
            columns,
            rows,
            ordered: false,
            order_keys: Vec::new(),
            final_page: true,
        })
    }

    /// Begin a transaction
    pub fn begin(&mut self) -> Result<()> {
        self.query("BEGIN", None)?;
        Ok(())
    }

    /// Commit a transaction
    pub fn commit(&mut self) -> Result<()> {
        self.query("COMMIT", None)?;
        Ok(())
    }

    /// Rollback a transaction
    pub fn rollback(&mut self) -> Result<()> {
        self.query("ROLLBACK", None)?;
        Ok(())
    }

    /// Close the connection
    pub fn close(&mut self) -> Result<()> {
        self.conn.close(true, 0x00, b"").ok();
        Ok(())
    }
}
