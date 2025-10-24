# VDB Graph Migrations

This directory contains Graph Query Language (GQL) migrations that replicate the functionality of the VDB (Vector Database) SQL migrations in a graph-based format. These migrations demonstrate how traditional relational database schemas can be converted to property graph schemas using GQL.

## Overview

The VDB migrations have been converted from SQL to GQL to showcase:

1. **Graph-Native Data Modeling**: Converting relational tables to nodes and foreign keys to edges
2. **Hierarchical Relationships**: Natural representation of tree structures (like DNS hierarchy)
3. **Rich Relationship Modeling**: Explicit edge types for different relationship semantics
4. **Audit Trails**: Graph-based audit logging with temporal edge relationships
5. **Constraint System**: GQL constraints equivalent to SQL constraints and triggers

## Migration Files

### 001_audit.gql
**Purpose**: Graph-based audit system
**Key Features**:
- `AuditRecord` nodes replace audit tables
- `AUDITED_BY` edges link entities to their audit records
- `FOLLOWED_BY` edges create temporal audit chains
- Graph functions replace SQL triggers
- Immutable audit trail with constraint enforcement

**Example**:
```gql
// Create audit trail
MATCH (entity:Entity WHERE entity.id = $entity_id)
-[:AUDITED_BY]->(audit:AuditRecord)
RETURN audit ORDER BY audit.created_at DESC;
```

### 004_dns.gql
**Purpose**: DNS hierarchy as a graph
**Key Features**:
- `Domain` nodes with natural parent-child relationships
- `PARENT_OF`/`SUBDOMAIN_OF` edges replace foreign keys
- `ResourceRecord` nodes linked via `HAS_RECORD` edges
- Automatic hierarchy creation and validation
- DNS delegation through `DELEGATES_TO` edges

**Example**:
```gql
// Get DNS hierarchy
MATCH path = (domain:Domain WHERE domain.name = 'example.com.')
-[:SUBDOMAIN_OF*]->(root)
RETURN path;
```

### 006_core.gql
**Purpose**: Core entities and versioning
**Key Features**:
- `Address` nodes with geographical relationships
- `Version` nodes for semantic versioning
- `LOCATED_IN` edges for address-to-country relationships
- `PREDECESSOR_OF` edges for version chains
- Graph functions for address management

**Example**:
```gql
// Find addresses in a region
MATCH (addr:Address)-[:LOCATED_IN]->(country:Country)
WHERE country.alpha2 = 'US'
RETURN addr;
```

### 015_orgs.gql
**Purpose**: Organizations and their relationships
**Key Features**:
- `Organization` nodes for standards bodies, companies, etc.
- `OWNS_DOMAIN` edges linking organizations to domains
- Rich relationship modeling (`COLLABORATES_WITH`, `OPERATES_UNDER`)
- Organizational hierarchy and collaboration networks

**Example**:
```gql
// Find organization relationships
MATCH (org:Organization WHERE org.acronym = 'IETF')
-[rel]-(related:Organization)
RETURN org, type(rel), related;
```

## Graph Schema Patterns

### Base Entity Pattern
All entities extend a common `Entity` label with system fields:
```gql
CREATE (entity:Entity {
  id: UUID DEFAULT gen_random_uuid(),
  created_at: TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
  updated_at: TIMESTAMP,
  deleted_at: TIMESTAMP,
  is_locked: BOOLEAN DEFAULT FALSE,
  last_observed_at: TIMESTAMP,
  row_version: INTEGER DEFAULT 0,
  metadata: JSONB
});
```

### Audit Pattern
Every entity can be audited:
```gql
(entity:Entity)-[:AUDITED_BY]->(audit:AuditRecord)
(audit1:AuditRecord)-[:FOLLOWED_BY]->(audit2:AuditRecord)
```

### Hierarchy Pattern
Natural tree representation:
```gql
(parent)-[:PARENT_OF]->(child)
(child)-[:SUBDOMAIN_OF]->(parent)
```

### Versioning Pattern
Temporal version chains:
```gql
(v1:Version)-[:PREDECESSOR_OF]->(v2:Version)
```

## GQL Specification Compliance

**Important**: These migrations demonstrate graph modeling concepts but contain syntax that needs updating for full GQL compliance:

### Issues Identified:
1. **UUID Usage**: Replace `UUID DEFAULT gen_random_uuid()` with `uuid_v4()` function calls
2. **Function Definitions**: Remove `CREATE FUNCTION` statements (GQL doesn't support user-defined functions)  
3. **Constraints**: Replace `CREATE CONSTRAINT` with application-level validation or comments
4. **Indexes**: Replace `CREATE INDEX` with implementation-specific indexing or comments
5. **Type Declarations**: Use proper Geode type constructors (`UUID()`, `DateTime()`, `Jsonb()`)

### Corrected Patterns:
```gql
-- Correct UUID usage
CREATE (entity:Entity {
  id: uuid_v4(),
  created_at: DateTime(),
  metadata: Jsonb('{}')
});

-- Query patterns instead of functions
MATCH (e:Entity WHERE e.id = $entity_id)
SET e.updated_at = DateTime()
RETURN e;
```

## Key Advantages of Graph Representation

### 1. Natural Hierarchies
DNS domains, organizational structures, and taxonomies are naturally represented as graphs rather than self-referencing tables.

### 2. Rich Relationships
Multiple relationship types between the same entities:
```gql
(org1)-[:COLLABORATES_WITH]->(org2)
(org1)-[:COMPETES_WITH]->(org2)
(org1)-[:ACQUIRED]->(org2)
```

### 3. Traversal Queries
Complex path queries become simple:
```gql
// Find all DNS subdomains
MATCH (root)-[:PARENT_OF*]->(subdomain)
RETURN subdomain;

// Audit trail traversal
MATCH (entity)-[:AUDITED_BY]->(first)
-[:FOLLOWED_BY*]->(latest)
RETURN first, latest;
```

### 4. Schema Evolution
Graph schemas evolve more naturally:
- Add new node labels without affecting existing data
- Add new edge types for new relationships
- Constraints can be added incrementally

## Migration Patterns

### SQL to GQL Conversion Rules

1. **Tables → Node Labels**
   ```sql
   CREATE TABLE dns.domain (...);
   ```
   ```gql
   CREATE LABEL Domain;
   ```

2. **Foreign Keys → Edges**
   ```sql
   parent TEXT REFERENCES dns.domain(name)
   ```
   ```gql
   (child)-[:SUBDOMAIN_OF]->(parent)
   ```

3. **Triggers → Graph Functions**
   ```sql
   CREATE TRIGGER ... EXECUTE FUNCTION audit.fn_audit();
   ```
   ```gql
   CREATE FUNCTION create_audit_record(...) { ... }
   ```

4. **Joins → Path Patterns**
   ```sql
   SELECT * FROM domain d JOIN country c ON d.country = c.code;
   ```
   ```gql
   MATCH (d:Domain)-[:LOCATED_IN]->(c:Country)
   ```

### Data Conversion Strategy

1. **Extract entities** from normalized tables
2. **Identify relationships** from foreign keys and junction tables
3. **Model hierarchies** using recursive relationships
4. **Preserve constraints** using GQL constraint syntax
5. **Convert procedures** to graph functions

## Usage Examples

### Creating Sample Data
```gql
// Create a domain with hierarchy
CALL create_domain('mail.google.com');

// Add DNS records
CALL add_resource_record(
  'mail.google.com.',
  'mail.google.com.',
  'A',
  '192.168.1.1'
);
```

### Querying Relationships
```gql
// Complex organizational relationships
MATCH path = (ietf:Organization {acronym: 'IETF'})
-[:COLLABORATES_WITH*1..3]-(related:Organization)
RETURN path;
```

### Entity Management
```gql
// Update entity with metadata
CALL add_metadata($entity_id, 'last_verified', CURRENT_TIMESTAMP());

// Find entities by metadata
MATCH (e:Entity)
WHERE e.metadata.status = 'active'
RETURN e;

// Audit trails are automatically tracked by Geode's built-in system
```

## Performance Considerations

### Indexing Strategy
```gql
// Entity lookup indexes
CREATE INDEX entity_id_idx ON (:Entity) (id);
CREATE INDEX entity_created_at_idx ON (:Entity) (created_at);

// Domain-specific indexes
CREATE INDEX domain_name_idx ON (:Domain) (name);
CREATE INDEX org_name_idx ON (:Organization) (name);
```

### Query Optimization
- Use selective filters early in patterns
- Leverage relationship direction for performance
- Consider materialized views for complex aggregations

## Integration with Geode

These migrations serve as examples for:
1. Converting existing SQL schemas to GQL
2. Demonstrating graph modeling patterns
3. Showing audit trail implementation
4. Illustrating constraint and function usage
5. Providing query pattern examples

## Future Extensions

Potential additions to this migration set:
- Cryptographic entities and relationships (008_crypto.gql)
- Network topology and infrastructure (022_network.gql)
- Authentication and authorization graphs (011_auth.gql)
- API and service dependency graphs (016_api.gql)
- Security vulnerability networks (027_cvss.gql, 028_cve.gql)

## References

- Original VDB migrations: `../../../vdb/migrations/`
- GQL specification: ISO/IEC 39075:2024
- Geode documentation: `../../docs/`
- Graph modeling patterns: `../../examples/`