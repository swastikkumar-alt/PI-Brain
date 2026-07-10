-- Personal Intelligence Engine (PIE) - Database Schema Specifications
-- Target Systems: Client-side SQLite (SQLite3MultipleCiphers + sqlite-vec), Backend PostgreSQL 15+

--------------------------------------------------------------------------------
-- PART 1: CLIENT-SIDE LOCAL SQLITE SCHEMA (Encrypted at Rest)
--------------------------------------------------------------------------------

-- Enable AES-256 transparent encryption via SQLite3MultipleCiphers:
-- PRAGMA key = 'user-derived-master-key';

-- 1. Entities Table
CREATE TABLE entities (
    id TEXT PRIMARY KEY, -- UUID
    entity_type TEXT NOT NULL, -- 'document', 'person', 'memory', 'event'
    source_connector TEXT, -- 'gmail', 'local_photos', etc.
    content TEXT,
    created_at INTEGER NOT NULL, -- Epoch timestamp
    updated_at INTEGER NOT NULL, -- Epoch timestamp
    is_synced BOOLEAN DEFAULT 0
);

CREATE INDEX idx_entities_type_time ON entities(entity_type, created_at);

-- 2. Edges Table (Graph Relationships)
CREATE TABLE edges (
    id TEXT PRIMARY KEY, -- UUID
    source_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    target_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    relationship_type TEXT NOT NULL, -- 'ATTENDED', 'AUTHORED_BY', 'MENTIONS'
    confidence_score REAL DEFAULT 1.0,
    valid_from INTEGER NOT NULL, -- Timeline tracking start
    valid_until INTEGER, -- Timeline tracking end (NULL = currently active)
    FOREIGN KEY(source_id) REFERENCES entities(id),
    FOREIGN KEY(target_id) REFERENCES entities(id)
);

CREATE INDEX idx_edges_source ON edges(source_id);
CREATE INDEX idx_edges_target ON edges(target_id);

-- 3. Embeddings Table (sqlite-vec virtual table layout)
-- Uses Float32 or Int8 vectors of dimension 384 (MiniLM-L6-v2)
CREATE VIRTUAL TABLE embeddings USING vec0(
    entity_id TEXT UNIQUE REFERENCES entities(id) ON DELETE CASCADE,
    embedding float[384]
);

-- 4. Memories Table (Episodic, Semantic, Procedural, Preference summaries)
CREATE TABLE memories (
    id TEXT PRIMARY KEY, -- UUID
    entity_id TEXT REFERENCES entities(id) ON DELETE SET NULL,
    memory_type TEXT NOT NULL, -- 'episodic', 'semantic', 'procedural', 'preference'
    summary TEXT NOT NULL
);

CREATE INDEX idx_memories_type ON memories(memory_type);

-- 5. Synchronization Ledger Table (CRDT event tracking)
CREATE TABLE sync_events (
    event_id TEXT PRIMARY KEY, -- UUID v7 (Chronologically sortable)
    mutation_type TEXT NOT NULL, -- 'INSERT', 'UPDATE', 'DELETE'
    target_table TEXT NOT NULL, -- 'entities', 'edges', 'memories'
    payload TEXT NOT NULL, -- Base64 AES-256-GCM encrypted JSON mutation payload
    status TEXT NOT NULL -- 'PENDING', 'SYNCED', 'FAILED'
);

CREATE INDEX idx_sync_status ON sync_events(status);

-- 6. FTS5 Virtual Table for local text full-text search
CREATE VIRTUAL TABLE entities_fts USING fts5(
    entity_id UNINDEXED,
    content
);


--------------------------------------------------------------------------------
-- PART 2: POSTGRESQL BACKEND SCHEMA (Identity & Metadata Sync Bridge)
--------------------------------------------------------------------------------

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_name VARCHAR(128),
    public_ecdh_key TEXT NOT NULL, -- secp256r1 public key PEM used for E2EE key wrapping
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- PostgreSQL Relay Event Table (盲目存储 and forward of encrypted payloads)
CREATE TABLE relay_sync_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id UUID NOT NULL,
    event_id TEXT NOT NULL, -- UUID v7
    ciphertext TEXT NOT NULL, -- Encrypted mutation payload
    iv TEXT NOT NULL, -- AES GCM initialization vector
    wrapped_keys JSONB NOT NULL, -- Key-map: {peer_device_id: wrapped_session_key}
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_relay_events_user_time ON relay_sync_events(user_id, created_at);
