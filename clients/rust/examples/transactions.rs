//! Transaction and savepoint example for Geode Rust client.
//!
//! Demonstrates:
//! - Transaction management (BEGIN, COMMIT, ROLLBACK)
//! - Savepoints for partial rollback
//! - Error handling with rollback
//! - Connection pooling with transactions

use geode_client::{Client, ConnectionPool, Result};
use std::collections::HashMap;

fn basic_transaction_example() -> Result<()> {
    println!("=== Basic Transaction Example ===\n");

    let client = Client::new("127.0.0.1", 3141).skip_verify(true);

    let mut conn = client.connect()?;

    // Start a transaction
    conn.begin()?;

    // Create some nodes
    conn.query("CREATE (p:Person {name: 'Alice', age: 30})", None)?;
    conn.query("CREATE (p:Person {name: 'Bob', age: 25})", None)?;

    // Query within transaction
    let page = conn.query("MATCH (p:Person) RETURN p.name AS name, p.age AS age", None)?;

    println!("Created persons:");
    for row in &page.rows {
        if let (Some(name), Some(age)) = (row.get("name"), row.get("age")) {
            println!("  - {}, age {}", name, age);
        }
    }

    // Commit the transaction
    conn.commit()?;
    println!("\nTransaction committed successfully!\n");

    conn.close()?;
    Ok(())
}

fn savepoint_example() -> Result<()> {
    println!("=== Savepoint Example ===\n");

    let client = Client::new("127.0.0.1", 3141).skip_verify(true);

    let mut conn = client.connect()?;

    // Start a transaction
    conn.begin()?;

    // Create initial data
    conn.query(
        "CREATE (p:Person {name: 'Charlie', age: 35, city: 'NYC'})",
        None,
    )?;
    println!("Created person: Charlie, age 35, city NYC");

    // Create a savepoint before making changes
    let sp1 = conn.savepoint("before_update")?;
    println!("Created savepoint: before_update");

    // Make some changes
    conn.query("MATCH (p:Person {name: 'Charlie'}) SET p.age = 40", None)?;
    println!("Updated Charlie's age to 40");

    // Create another savepoint
    let sp2 = conn.savepoint("before_city_update")?;
    println!("Created savepoint: before_city_update");

    // Make more changes
    conn.query("MATCH (p:Person {name: 'Charlie'}) SET p.city = 'SF'", None)?;
    println!("Updated Charlie's city to SF");

    // Rollback to sp2 (undoes city change)
    conn.rollback_to(&sp2)?;
    println!("\nRolled back to savepoint: before_city_update");
    println!("Charlie's city is still NYC, age is still 40");

    // Commit the transaction
    conn.commit()?;
    println!("\nTransaction committed!\n");

    // Verify final state
    let page = conn.query(
        "MATCH (p:Person {name: 'Charlie'}) RETURN p.age AS age, p.city AS city",
        None,
    )?;

    if let Some(row) = page.rows.first() {
        println!(
            "Final state: age={}, city={}",
            row.get("age").map(|v| format!("{}", v)).unwrap_or_default(),
            row.get("city")
                .map(|v| format!("{}", v))
                .unwrap_or_default()
        );
    }

    conn.close()?;
    Ok(())
}

fn nested_savepoints_example() -> Result<()> {
    println!("\n=== Nested Savepoints Example ===\n");

    let client = Client::new("127.0.0.1", 3141).skip_verify(true);

    let mut conn = client.connect()?;

    conn.begin()?;

    // Level 0: Initial state
    conn.query("CREATE (org:Organization {name: 'Acme Corp'})", None)?;
    println!("Created organization: Acme Corp");

    // Level 1: Add departments
    let sp_depts = conn.savepoint("departments")?;
    conn.query(
        "MATCH (org:Organization {name: 'Acme Corp'}) \
         CREATE (org)-[:HAS_DEPT]->(d:Department {name: 'Engineering'})",
        None,
    )?;
    conn.query(
        "MATCH (org:Organization {name: 'Acme Corp'}) \
         CREATE (org)-[:HAS_DEPT]->(d:Department {name: 'Sales'})",
        None,
    )?;
    println!("Added departments: Engineering, Sales");

    // Level 2: Add employees
    let sp_employees = conn.savepoint("employees")?;
    conn.query(
        "MATCH (d:Department {name: 'Engineering'}) \
         CREATE (d)-[:HAS_EMPLOYEE]->(e:Employee {name: 'Alice'})",
        None,
    )?;
    conn.query(
        "MATCH (d:Department {name: 'Engineering'}) \
         CREATE (d)-[:HAS_EMPLOYEE]->(e:Employee {name: 'Bob'})",
        None,
    )?;
    println!("Added employees to Engineering: Alice, Bob");

    // Level 3: Add projects
    let sp_projects = conn.savepoint("projects")?;
    conn.query(
        "MATCH (e:Employee {name: 'Alice'}) \
         CREATE (e)-[:WORKS_ON]->(p:Project {name: 'Project X'})",
        None,
    )?;
    println!("Added project: Project X for Alice");

    // Oops, we don't want projects yet - rollback to employees level
    conn.rollback_to(&sp_employees)?;
    println!("\nRolled back to 'employees' savepoint (removed projects)");

    // We can continue from the employees level
    conn.query(
        "MATCH (d:Department {name: 'Sales'}) \
         CREATE (d)-[:HAS_EMPLOYEE]->(e:Employee {name: 'Charlie'})",
        None,
    )?;
    println!("Added employee to Sales: Charlie");

    // Commit everything
    conn.commit()?;
    println!("\nTransaction committed!\n");

    conn.close()?;
    Ok(())
}

#[tokio::main]
async fn pool_with_transactions_example() -> Result<()> {
    println!("=== Connection Pool with Transactions ===\n");

    let pool = ConnectionPool::new("127.0.0.1", 3141, 10)
        .skip_verify(true)
        .page_size(1000);

    // Simulate concurrent transactions
    let handles: Vec<_> = vec![("David", 28), ("Emma", 32), ("Frank", 45)]
        .into_iter()
        .map(|(name, age)| {
            let pool_clone = pool.clone();
            tokio::spawn(async move {
                let mut conn = pool_clone.acquire().await?;
                conn.begin()?;

                match conn.query(
                    &format!("CREATE (p:Person {{name: '{}', age: {}}})", name, age),
                    None,
                ) {
                    Ok(_) => {
                        conn.commit()?;
                        println!("Created person: {}, age {}", name, age);
                        Ok(())
                    }
                    Err(e) => {
                        conn.rollback()?;
                        Err(e)
                    }
                }
            })
        })
        .collect();

    // Wait for all tasks to complete
    for handle in handles {
        let _ = handle.await;
    }

    println!("\nPool stats: size={}", pool.size().await);

    Ok(())
}

fn error_handling_example() -> Result<()> {
    println!("\n=== Error Handling Example ===\n");

    let client = Client::new("127.0.0.1", 3141).skip_verify(true);

    let mut conn = client.connect()?;

    conn.begin()?;

    // This will succeed
    conn.query("CREATE (p:Person {name: 'Grace', age: 27})", None)?;
    println!("Created person: Grace");

    // Create a savepoint before risky operation
    let sp = conn.savepoint("before_risky_op")?;

    // Try a risky operation
    match conn.query("CREATE (INVALID SYNTAX", None) {
        Ok(_) => {
            println!("Risky operation succeeded");
        }
        Err(e) => {
            eprintln!("Caught error in risky operation: {}", e);
            // Rollback to savepoint, keeping Grace
            conn.rollback_to(&sp)?;
            println!("Rolled back risky operation, Grace is still there");
        }
    }

    // Continue with valid operations
    conn.query("CREATE (p:Person {name: 'Henry', age: 29})", None)?;
    println!("Created person: Henry");

    // Commit the transaction
    conn.commit()?;
    println!("\nTransaction committed (Grace and Henry created)\n");

    conn.close()?;
    Ok(())
}

fn main() -> Result<()> {
    println!("Geode Rust Client - Transaction Examples\n");
    println!("==========================================\n");

    basic_transaction_example()?;
    savepoint_example()?;
    nested_savepoints_example()?;

    // Pool example is async, so run it separately
    if let Err(e) = pool_with_transactions_example() {
        eprintln!("Pool example failed: {}", e);
    }

    error_handling_example()?;

    println!("\n✅ All transaction examples completed successfully!");

    Ok(())
}
