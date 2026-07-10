# Personal Intelligence Engine (PIE) - MVP Roadmap & Milestones

This document details the phased implementation roadmap to deploy the Minimum Viable Product (MVP) of the **Personal Intelligence Engine (PIE)**.

---

## 1. MVP Scope & Phases

The PIE project implements a strict local-first, zero-knowledge architectural rollout divided into 5 chronological phases.

### Phase 1: Secure Local Persistence
*   **Focus**: Device-side cryptographic foundation and ORM integration.
*   **Deliverables**:
    - Flutter application shell structure.
    - Local SQLite database encrypted at rest using **SQLite3MultipleCiphers** (AES-256).
    - Establish Domain-Driven Design (DDD) file structures.
    - Setup CI/CD build scripts and unit testing frameworks.

### Phase 2: Edge AI & Semantic Search
*   **Focus**: Local models execution and vector/graph indexing.
*   **Deliverables**:
    - Integrate `llamadart` (Llama.cpp wrapper) executing Q4_K_M model formats on mobile NPUs/CPUs.
    - Integrate `flutter_onnxruntime` executing local embedding model (MiniLM).
    - Link `sqlite-vec` extension to the local database to run vector distance searches.
    - Implement recursive CTE traversals in SQLite to execute graph walks client-side.

### Phase 3: Processing & Connectors
*   **Focus**: Ingestion pipeline and background scheduling.
*   **Deliverables**:
    - Integrate local Speech-to-Text (STT) for offline voice queries.
    - Build the Plugin SDK abstraction interface.
    - Deploy connectors for local Contacts, local Calendar, and SMS messages.
    - Manage background workers using the `flutter_workmanager` library.

### Phase 4: Zero-Knowledge Sync
*   **Focus**: Distributed synchronization and key management.
*   **Deliverables**:
    - Deploy FastAPI cloud backend, PostgreSQL meta-store, and Kafka events queue.
    - Client-side Elliptic-Curve Diffie-Hellman (ECDH) key derivation over **secp256r1** curve.
    - Implement AES-256-GCM symmetric session keys and wrapped key exchanges.
    - Construct the client CRDT event ledger using Last-Write-Wins (LWW) conflict resolution.
    - React web client setup running WASM-compiled SQLite and the WebCrypto API.

### Phase 5: Orchestration & Polish
*   **Focus**: Cognitive orchestrators and system diagnostics.
*   **Deliverables**:
    - Implement the AI Orchestration layer (Planner, Retriever, Verifier) enforcing the strict never-hallucinate directive.
    - Build the React-based Admin and Diagnostics Dashboard for system health.
    - Profile battery usage, context window limitations, and RAM footprints.
    - Finalize OpenAPI integration testing.
