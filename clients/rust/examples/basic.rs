//! Basic example of using the Geode Rust client.

use geode_client::{Client, Result};

#[tokio::main]
async fn main() -> Result<()> {
    // Create client
    let client = Client::new("process:./zig-out/bin/geode")?;

    // Connect
    let mut conn = client.connect().await?;
    println!("Connected to Geode!");

    // Simple query
    let page = conn.query("RETURN 1 AS x, 'Hello' AS greeting", None).await?;
    println!("\nSimple query results:");
    for row in &page.rows {
        if let (Ok(x), Ok(greeting)) = (row.get("x").unwrap().as_int(), row.get("greeting").unwrap().as_string()) {
            println!("  x={}, greeting={}", x, greeting);
        }
    }

    // Query with parameters
    let mut params = std::collections::HashMap::new();
    params.insert("name".to_string(), serde_json::json!("Alice"));
    params.insert("age".to_string(), serde_json::json!(30));

    let page = conn.query("RETURN $name AS name, $age AS age", Some(params)).await?;
    println!("\nParameterized query results:");
    for row in &page.rows {
        if let (Ok(name), Ok(age)) = (row.get("name").unwrap().as_string(), row.get("age").unwrap().as_int()) {
            println!("  name={}, age={}", name, age);
        }
    }

    // Transaction
    conn.begin().await?;
    let mut create_params = std::collections::HashMap::new();
    create_params.insert("name".to_string(), serde_json::json!("Bob"));
    create_params.insert("age".to_string(), serde_json::json!(25));

    match conn.query("CREATE (p:Person {name: $name, age: $age})", Some(create_params)).await {
        Ok(_) => {
            conn.commit().await?;
            println!("\nTransaction committed successfully");
        }
        Err(e) => {
            conn.rollback().await?;
            println!("\nTransaction rolled back: {}", e);
        }
    }

    Ok(())
}
