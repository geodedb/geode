// Debug connection test with verbose Quiche logging
use geode_client::Client;

fn main() {
    env_logger::init();

    eprintln!("=== Starting Quiche Connection Debug Test ===");
    eprintln!("Target: localhost:19999");
    eprintln!("TLS Verification: SKIP (insecure)");
    eprintln!("");

    let client = Client::new("localhost", 19999)
        .skip_verify(true)
        .client_name("debug-test")
        .client_version("0.1.0");

    eprintln!("Client configured. Attempting connection...");
    eprintln!("");

    match client.connect() {
        Ok(_conn) => {
            eprintln!("");
            eprintln!("✓ CONNECTION SUCCESSFUL!");
            eprintln!("Connection established successfully");
        }
        Err(e) => {
            eprintln!("");
            eprintln!("✗ CONNECTION FAILED!");
            eprintln!("Error: {:?}", e);
            std::process::exit(1);
        }
    }
}
