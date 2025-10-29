use geode_client::Client;

fn main() {
    println!("[TEST] Starting Rust client connection test...");
    println!("[TEST] Connecting to localhost:7567");

    // Try with skip_verify first
    let client = Client::new("localhost", 7567)
        .skip_verify(true);

    println!("[TEST] Client configured with skip_verify=true");

    match client.connect() {
        Ok(conn) => {
            println!("[TEST] ✓ Successfully connected!");
            println!("[TEST] Connection established with quiche QUIC library");

            // Note: Query execution would need async runtime, skipping for now
            println!("[TEST] Connection successful - test complete");
        }
        Err(e) => {
            eprintln!("[TEST] ✗ Connection failed: {}", e);
            eprintln!("[TEST] Error details: {:?}", e);
            std::process::exit(1);
        }
    }
}
