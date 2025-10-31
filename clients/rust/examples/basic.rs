//! Basic example of using the Geode Rust QUIC client.

use geode_client::{Client, Result};

fn main() -> Result<()> {
    // Create QUIC client (skip TLS verification for development)
    let client = Client::new("127.0.0.1", 3141)
        .skip_verify(true)
        .page_size(1000);

    // Connect via QUIC
    let mut conn = client.connect()?;
    println!("Connected to Geode via QUIC!");

    // Simple query
    let page = conn.query("RETURN 1 AS x, 'Hello QUIC' AS greeting", None)?;
    println!("\nSimple query results:");
    for row in &page.rows {
        if let (Ok(x), Ok(greeting)) = (
            row.get("x").unwrap().as_int(),
            row.get("greeting").unwrap().as_string(),
        ) {
            println!("  x={}, greeting={}", x, greeting);
        }
    }

    // Query with parameters
    let mut params = std::collections::HashMap::new();
    params.insert("name".to_string(), serde_json::json!("Alice"));
    params.insert("age".to_string(), serde_json::json!(30));

    let page = conn
        .query("RETURN $name AS name, $age AS age", Some(params))?;
    println!("\nParameterized query results:");
    for row in &page.rows {
        if let (Ok(name), Ok(age)) = (
            row.get("name").unwrap().as_string(),
            row.get("age").unwrap().as_int(),
        ) {
            println!("  name={}, age={}", name, age);
        }
    }

    // Transaction
    println!("\nStarting transaction...");
    conn.begin()?;

    let mut create_params = std::collections::HashMap::new();
    create_params.insert("name".to_string(), serde_json::json!("Bob"));
    create_params.insert("age".to_string(), serde_json::json!(25));

    match conn
        .query(
            "CREATE (p:Person {name: $name, age: $age})",
            Some(create_params),
        )
    {
        Ok(_) => {
            conn.commit()?;
            println!("Transaction committed successfully");
        }
        Err(e) => {
            conn.rollback()?;
            println!("Transaction rolled back: {}", e);
        }
    }

    // Close connection
    conn.close()?;
    println!("\nConnection closed");

    Ok(())
}
