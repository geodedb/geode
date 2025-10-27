//! Advanced example demonstrating query builders.

use geode_client::{Client, QueryBuilder, PatternBuilder, EdgeDirection, Result};

#[tokio::main]
async fn main() -> Result<()> {
    query_builder_examples();
    Ok(())
}

fn query_builder_examples() {
    println!("=== Query Builder Examples ===\n");

    // Complex query
    let (query, params) = QueryBuilder::new()
        .match_pattern("(p:Person)")
        .where_clause("p.age > 25")
        .optional_match("(p)-[:WORKS_AT]->(c:Company)")
        .return_(&["p.name AS person", "c.name AS company"])
        .order_by(&["person"])
        .limit(10)
        .with_param("min_age", 25)
        .build();

    println!("Complex Query:\n{}\n", query);
    println!("Params: {:?}\n", params);

    // Pattern builder
    let pattern = PatternBuilder::new()
        .node("a", "Person")
        .edge("knows", "KNOWS", EdgeDirection::Undirected)
        .node("b", "Person")
        .build();

    println!("Pattern: {}\n", pattern);

    // Simple query
    let (query, _) = QueryBuilder::new()
        .match_pattern("(n:Person)")
        .return_(&["n.name", "n.age"])
        .limit(100)
        .build();

    println!("Simple Query:\n{}\n", query);
}
