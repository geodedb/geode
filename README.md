# Geode Graph Database

**Enterprise-ready graph database with industry-leading compliance and performance**

[![GQL Compliance](https://img.shields.io/badge/GQL%20Compliance-98.6%25-green)](docs/GQL_COMPLIANCE.md)
[![Test Coverage](https://img.shields.io/badge/Test%20Coverage-94.7%25-green)](docs/KNOWN_TEST_ISSUES.md)
[![CANARY Tracking](https://img.shields.io/badge/CANARY%20Markers-1016-blue)](docs/TODO.md)
[![Status](https://img.shields.io/badge/Status-Production%20Ready-brightgreen)](docs/FEATURES_OVERVIEW.md)

Geode is a production-ready graph database implementing the **ISO/IEC 39075:2024 Graph Query Language (GQL)** standard. Built in Zig for performance and reliability, Geode provides enterprise-grade features including advanced security, machine learning integration, and distributed query processing.

## 🏆 Key Features

### **Standards Compliance**
- **98.6% ISO/IEC 39075:2024 GQL Compliance** - Industry-leading standards implementation
- **ACID Transactions** - Full MVCC with Serializable Snapshot Isolation (SSI)
- **Enterprise Security** - Enhanced RLS, TDE, audit logging, MFA support

### **Advanced Capabilities**
- **Vector Search** - HNSW indexing with 6 distance metrics and SIMD acceleration
- **Machine Learning** - Node2Vec, GraphSAGE, DeepWalk graph embeddings
- **Real-time Analytics** - Streaming pattern detection and anomaly analysis
- **Distributed Queries** - Federation-aware optimization with load balancing

### **Performance & Scalability**
- **13.18x I/O Performance** - Memory-mapped operations with optimization
- **Cost-Based Query Planner** - Statistics-driven optimization
- **Cloud-Ready** - S3 backup integration with compression
- **Multi-Shard Support** - Up to 32 shards with automatic coordination

## 🚀 Quick Start

### **Installation**

#### Using Nix (Recommended)
```bash
# Run Geode directly
nix run github:spyderorg/geode

# Enter development environment
nix develop github:spyderorg/geode
```

#### Traditional Build
```bash
# Prerequisites: Zig 0.15.1+
git clone https://gitlab.com/devnw/geode/geode
cd geode

# Build optimized version
make build

# Start server
./zig-out/bin/geode serve --listen-quic 0.0.0.0:3141
```

### **Basic Usage**

#### Interactive Shell
```bash
# Start interactive REPL
./zig-out/bin/geode shell

# Connect to remote server
./zig-out/bin/geode shell --server geode.example.com:3141
```

#### Query Execution
```bash
# Execute single query
./zig-out/bin/geode query "CREATE (alice:Person {name: 'Alice', age: 30})"

# Batch query execution
./zig-out/bin/geode query "
  CREATE (alice:Person {name: 'Alice', age: 30})
  CREATE (bob:Person {name: 'Bob', age: 25})
  CREATE (alice)-[:KNOWS]->(bob)
  MATCH (p:Person) RETURN p.name, p.age
"
```

#### Example Queries

**Basic Graph Operations**:
```gql
-- Create nodes and relationships
CREATE (alice:Person {name: 'Alice', age: 30})
CREATE (bob:Person {name: 'Bob', age: 25})
CREATE (alice)-[:KNOWS {since: '2020-01-01'}]->(bob)

-- Pattern matching
MATCH (p1:Person)-[r:KNOWS]->(p2:Person)
WHERE r.since > '2019-01-01'
RETURN p1.name, p2.name, r.since
```

**Vector Similarity Search**:
```gql
-- Create document with embedding
CREATE (doc:Document {
  title: 'AI Research Paper',
  embedding: vectorf32('[0.1, 0.2, -0.3, 0.8, 0.4]')
})

-- Find similar documents
MATCH (d:Document)
WHERE vector_cosine(d.embedding, vectorf32('[0.15, 0.18, -0.25, 0.82, 0.38]')) > 0.8
RETURN d.title, vector_cosine(d.embedding, vectorf32('[0.15, 0.18, -0.25, 0.82, 0.38]')) AS similarity
ORDER BY similarity DESC
```

**Real-time Analytics**:
```gql
-- Analyze user activity patterns
MATCH (user:User)-[:PERFORMED]->(action:Action)
WHERE action.timestamp > now() - duration('PT1H')
RETURN user.id,
       count(action) AS recent_actions,
       collect(action.type) AS action_types
ORDER BY recent_actions DESC
```

**Advanced Query Features (October 2025)**:
```gql
-- Variable-length paths: Find friends within 2 hops
MATCH (alice:Person)-[:KNOWS*1..2]->(friend)
WHERE alice.name = 'Alice'
RETURN friend.name

-- FILTER clause: Additional filtering after pattern matching
MATCH (a:Person)-[r]->(b:Person)
WHERE a.name = 'Alice'
FILTER b.city = 'Seattle'
RETURN b.name AS friend

-- Dynamic label management with SET
MATCH (n:Person)
WHERE n.name = 'Alice'
SET n:Employee:Manager
RETURN n

-- Relationship type introspection with type()
MATCH (a)-[r]->(b)
RETURN a.name, type(r) AS relationship_type, b.name

-- Session and transaction management
SESSION SET GRAPH social_network;
START TRANSACTION;
  CREATE (alice:Person {name: 'Alice', age: 30});
  CREATE (bob:Person {name: 'Bob', age: 25});
  CREATE (alice)-[:KNOWS]->(bob);
COMMIT;
```

## 🏗️ Architecture

### **Core Components**
- **GQL Parser/Lexer** - 98.6% ISO standard compliance with comprehensive syntax support
- **Query Planner** - Cost-based optimization with real-time statistics integration
- **Storage Engine** - MVCC with WAL, TDE encryption, and memory-mapped I/O
- **Index System** - 6 index types: B-tree, Hash, Full-text, Spatial, Vector (HNSW), Interval
- **Transport Layer** - QUIC+TLS for secure, modern network communication

### **Advanced Features**
- **Vector Processing** - SIMD-accelerated operations with hardware optimization
- **Machine Learning** - Integrated graph embedding algorithms for AI applications
- **Security Layer** - Enhanced RLS, policy evaluation, temporal constraints
- **Analytics Engine** - Real-time stream processing with pattern detection

## 📊 Performance Benchmarks

### **Query Performance**
- **Simple Queries**: <1ms execution for indexed operations
- **Complex Joins**: 60-80% improvement with distributed coordination
- **Vector Similarity**: 10-100x faster with HNSW vs sequential scan
- **Full-text Search**: BM25 scoring with 40-60% relevance improvement

### **Storage Performance**
- **I/O Operations**: 13.18x improvement (5,754μs → 436μs)
- **Vector Operations**: 8x SIMD speedup for vectors ≥8 dimensions
- **Transaction Throughput**: SSI with minimal performance overhead
- **Memory Usage**: <2% overhead for security features

## 🔐 Security Features

### **Authentication & Authorization**
- **Enhanced Row-Level Security (RLS)** - Policy-based access control with expression evaluation
- **RBAC/ABAC** - Role and attribute-based access control
- **Multi-Factor Authentication** - Integrated MFA support
- **Session Management** - Secure session handling with timeout controls

### **Data Protection**
- **Transparent Data Encryption (TDE)** - <1% performance overhead
- **Key Management System (KMS)** - HashiCorp Vault integration
- **Audit Logging** - Comprehensive compliance tracking
- **Data Classification** - 5-level security classification system

### **Compliance Standards**
- **GDPR** - Data protection regulation compliance
- **SOX/HIPAA/PCI-DSS** - Financial and healthcare standards
- **Enterprise Governance** - Audit trails and compliance tracking

## 🧮 Data Types

### **Core Types**
- **Numeric** - Int8-64, Float32-64, Decimal128 with precision control
- **String** - UTF-8 with normalization, case folding, collation
- **Temporal** - DateTime with timezone, intervals, duration arithmetic
- **Binary** - Efficient blob storage and retrieval

### **Advanced Types**
- **Vector Types** - VectorF32/VectorI32 with SIMD acceleration
- **Network Types** - IPv4/IPv6, CIDR, MAC with <1μs parsing
- **Geographic** - Point, LineString, Polygon with R-tree indexing
- **Cryptographic** - Hash types, digital signatures, key management

### **Specialized Types**
- **JSONB** - Binary JSON with inverted indexing
- **XML** - Full XML processing with XPath support
- **Arrays** - Multi-dimensional with element-wise operations
- **Ranges** - Temporal and numeric with interval tree indexing

## 🛠️ Development & Testing

### **Build System**
```bash
# Development build
make build

# Run comprehensive tests
make test

# Generate governance status
make status-generate

# Cross-platform verification
make verify-fast

# GPU benchmarks (requires CUDA)
./run_gpu_benchmarks.sh
```

### **GPU Acceleration Testing**

Geode includes GPU-accelerated graph algorithms (BFS, PageRank, Set Operations). Test with Docker:

```bash
# Build GPU-enabled Docker image
docker build -t geode:gpu -f Dockerfile.gpu .

# Run GPU benchmarks (requires NVIDIA GPU + nvidia-docker2)
docker run --gpus all --rm geode:gpu

# Or use the convenience script
./test_gpu_docker.sh
```

**Requirements for GPU testing:**
- NVIDIA GPU with CUDA 12.3.2+ support
- NVIDIA Docker runtime installed
- Docker configured with `--gpus` flag support

**Verify GPU access:**
```bash
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi
```

### **Test Coverage**
- **94.7% Test Coverage** (1199/1266 non-skipped tests)
- **Comprehensive Test Suite** - Unit, integration, and performance tests
- **CANARY Governance** - 1016 governance markers tracking implementation
- **Cross-Platform** - Linux, macOS, Windows compatibility
- **GPU Acceleration** - Optional CUDA-based graph algorithm acceleration

### **Quality Assurance**
- **Memory Safety** - Zero memory leaks in test runs
- **Performance Regression** - Automated benchmark validation
- **Standards Compliance** - Continuous ISO/IEC 39075:2024 verification
- **GPU Performance** - Target speedups: BFS ≥5x, PageRank ≥3x, Set Ops ≥3-4x

## 📚 Documentation

### **Essential Guides**
- **[Features Overview](docs/FEATURES_OVERVIEW.md)** - Comprehensive feature catalog
- **[TODO & Status](docs/TODO.md)** - Development status (all phases complete)
- **[GQL Compliance](docs/GQL_COMPLIANCE.md)** - ISO/IEC 39075:2024 conformance
- **[Quick Reference](docs/QUICK_REFERENCE.md)** - Commands and syntax guide

### **Technical Documentation**
- **[API Reference](docs/API_REFERENCE.md)** - Complete API documentation
- **[Types & Functions](docs/TYPES_AND_FUNCTIONS.md)** - Data type specifications
- **[Architecture](docs/CURRENT_ARCHITECTURE.md)** - System architecture overview

### **Advanced Features**
- **[ML Graph Embeddings](docs/ML_GRAPH_EMBEDDINGS.md)** - Node2Vec, GraphSAGE, DeepWalk
- **[Security Progress](docs/SECURITY_PROGRESS.md)** - Enhanced RLS and compliance
- **[Real-time Analytics](docs/REAL_TIME_ANALYTICS.md)** - Streaming and pattern detection
- **[Graph Algorithms](docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md)** - Algorithm usage and performance

## 🌐 Use Cases

### **Primary Applications**
- **Social Networks** - Relationship analysis and recommendation systems
- **Knowledge Graphs** - Semantic data modeling and intelligent search
- **Fraud Detection** - Pattern analysis and anomaly detection in financial networks
- **Recommendation Engines** - Vector similarity and collaborative filtering
- **IoT Networks** - Device relationship mapping and telemetry analysis

### **Industry Solutions**
- **Financial Services** - Risk analysis, compliance monitoring, transaction networks
- **Healthcare** - Patient data modeling, research analytics, treatment pathways
- **E-commerce** - Product recommendations, customer behavior analysis
- **Cybersecurity** - Threat detection, network analysis, incident response
- **Supply Chain** - Logistics optimization, dependency tracking, risk assessment

## 🤝 Contributing

### **Development Setup**
1. **Prerequisites**: Zig 0.15.1+, Git
2. **Clone Repository**: `git clone https://gitlab.com/devnw/geode/geode`
3. **Development Environment**: `nix develop` (recommended) or manual setup
4. **Run Tests**: `make test` to verify setup

### **Contributing Guidelines**
- **CANARY Compliance** - All features must include governance tracking
- **Test Coverage** - Maintain >90% test pass rate
- **Documentation** - Update relevant docs with implementation changes
- **Performance** - No regressions in core operations

### **Community**
- **Issues** - Report bugs and feature requests via GitHub Issues
- **Discussions** - Technical discussions and questions
- **Pull Requests** - Follow contributing guidelines for submissions

## 📄 License

<!-- SPDX-License-Identifier: TODO -->

## 🔗 Links

- **Documentation**: [./docs/](docs/)
- **GitHub Repository**: [https://gitlab.com/devnw/geode/geode](https://gitlab.com/devnw/geode/geode)
- **Issue Tracker**: [GitHub Issues](https://gitlab.com/devnw/geode/geode/issues)
- **ISO/IEC 39075:2024**: [GQL Standard](https://www.iso.org/standard/76120.html)

---

**Geode** - Enterprise-ready graph database for the modern data stack

*Built with ❤️ by the Spyder Organization*
