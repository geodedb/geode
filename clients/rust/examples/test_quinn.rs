//! Simple test for Quinn-based QUIC client

use geode_client::{Client, Result};

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    println!("[TEST] Creating Quinn-based client...");
    let client = Client::new("127.0.0.1", 3141)
        .skip_verify(true)
        .client_name("test-quinn")
        .client_version("0.1.0");

    println!("[TEST] Connecting to server...");
    let mut conn = client.connect().await?;

    println!("[TEST] ✓ Connected successfully!");

    println!("[TEST] Executing simple query: RETURN 1 AS x");
    let (page, cursor) = conn.query("RETURN 1 AS x").await?;

    println!("[TEST] ✓ Query executed!");
    println!("[TEST] Columns: {:?}", page.columns);
    println!("[TEST] Rows: {:?}", page.rows);
    println!("[TEST] Final page: {}", page.final_page);
    println!("[TEST] Cursor: {:?}", cursor);

    println!("[TEST] Closing connection...");
    conn.close()?;

    println!("[TEST] ✓ All tests passed!");

    Ok(())
}
