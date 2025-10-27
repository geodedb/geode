//! Core client implementation for Geode.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
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

/// Geode database client
pub struct Client {
    config: ClientConfig,
}

#[derive(Clone)]
struct ClientConfig {
    mode: String,
    path: String,
    addr: String,
    page_size: usize,
    hello_name: String,
    hello_ver: String,
    conformance: String,
}

impl Client {
    /// Create a new client from DSN
    pub fn new(dsn: &str) -> Result<Self> {
        let config = parse_dsn(dsn)?;
        Ok(Self { config })
    }

    /// Connect to the database
    pub async fn connect(&self) -> Result<Connection> {
        Connection::new(self.config.clone()).await
    }
}

/// A single connection to Geode
pub struct Connection {
    config: ClientConfig,
    process: Option<Child>,
    reader: Option<BufReader<tokio::process::ChildStdout>>,
    writer: Option<tokio::process::ChildStdin>,
    lock: Mutex<()>,
}

impl Connection {
    async fn new(config: ClientConfig) -> Result<Self> {
        let mut conn = Self {
            config: config.clone(),
            process: None,
            reader: None,
            writer: None,
            lock: Mutex::new(()),
        };

        if config.mode == "quic" {
            return Err(Error::connection("QUIC mode not yet implemented in Rust client"));
        }

        // Process mode
        let mut child = Command::new(&config.path)
            .arg("serve")
            .arg("--stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;

        let stdin = child.stdin.take().ok_or_else(|| Error::connection("Failed to open stdin"))?;
        let stdout = child.stdout.take().ok_or_else(|| Error::connection("Failed to open stdout"))?;

        conn.process = Some(child);
        conn.reader = Some(BufReader::new(stdout));
        conn.writer = Some(stdin);

        // Send HELLO
        let hello = serde_json::json!({
            "type": "HELLO",
            "client_name": config.hello_name,
            "client_ver": config.hello_ver,
            "wanted_conformance": config.conformance,
        });
        conn.write_json(&hello).await?;
        conn.read_line().await?; // Discard HELLO response

        Ok(conn)
    }

    async fn write_json(&mut self, obj: &serde_json::Value) -> Result<()> {
        if let Some(writer) = &mut self.writer {
            let mut line = serde_json::to_string(obj)?;
            line.push('\n');
            writer.write_all(line.as_bytes()).await?;
            writer.flush().await?;
            Ok(())
        } else {
            Err(Error::connection("Writer not available"))
        }
    }

    async fn read_line(&mut self) -> Result<String> {
        if let Some(reader) = &mut self.reader {
            let mut line = String::new();
            reader.read_line(&mut line).await?;
            Ok(line.trim_end().to_string())
        } else {
            Err(Error::connection("Reader not available"))
        }
    }

    /// Execute a query
    pub async fn query(&mut self, text: &str, params: Option<HashMap<String, serde_json::Value>>) -> Result<Page> {
        let _lock = self.lock.lock().await;

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
            "page_size": self.config.page_size,
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

        let raw_rows = bindings_result.get("rows").and_then(|r| r.as_array()).unwrap_or(&vec![]);
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
    pub async fn begin(&mut self) -> Result<()> {
        let _lock = self.lock.lock().await;
        self.write_json(&serde_json::json!({"type": "BEGIN"})).await?;
        self.read_line().await?;
        Ok(())
    }

    /// Commit a transaction
    pub async fn commit(&mut self) -> Result<()> {
        let _lock = self.lock.lock().await;
        self.write_json(&serde_json::json!({"type": "COMMIT"})).await?;
        self.read_line().await?;
        Ok(())
    }

    /// Rollback a transaction
    pub async fn rollback(&mut self) -> Result<()> {
        let _lock = self.lock.lock().await;
        self.write_json(&serde_json::json!({"type": "ROLLBACK"})).await?;
        self.read_line().await?;
        Ok(())
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        if let Some(mut child) = self.process.take() {
            let _ = child.start_kill();
        }
    }
}

fn parse_dsn(dsn: &str) -> Result<ClientConfig> {
    let mut config = ClientConfig {
        mode: "process".to_string(),
        path: "./zig-out/bin/geode".to_string(),
        addr: "127.0.0.1:8443".to_string(),
        page_size: 1000,
        hello_name: "geode-rust".to_string(),
        hello_ver: "0.1".to_string(),
        conformance: "min".to_string(),
    };

    if dsn.is_empty() {
        return Ok(config);
    }

    if let Some(rest) = dsn.strip_prefix("process:") {
        let parts: Vec<&str> = rest.splitn(2, '?').collect();
        config.path = parts[0].to_string();
        if parts.len() > 1 {
            // Parse query params
            for pair in parts[1].split('&') {
                let kv: Vec<&str> = pair.splitn(2, '=').collect();
                if kv.len() == 2 {
                    match kv[0] {
                        "page_size" => config.page_size = kv[1].parse().unwrap_or(1000),
                        _ => {}
                    }
                }
            }
        }
    } else if dsn.starts_with("quic:") {
        config.mode = "quic".to_string();
        // QUIC parsing would go here
    }

    Ok(config)
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
