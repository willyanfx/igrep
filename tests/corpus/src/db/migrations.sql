-- Migration: 001_create_users
-- Created: 2025-12-01
-- Author: engineering team

CREATE TABLE IF NOT EXISTS users (
    id          SERIAL PRIMARY KEY,
    email       VARCHAR(255) NOT NULL UNIQUE,
    username    VARCHAR(100) NOT NULL,
    password    VARCHAR(255) NOT NULL,  -- bcrypt hash
    created_at  TIMESTAMP DEFAULT NOW(),
    updated_at  TIMESTAMP DEFAULT NOW()
);

-- TODO: add index on email for faster lookups
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_username ON users(username);

-- Migration: 002_create_search_index
-- This table stores the trigram posting lists for fast code search.
-- Each trigram maps to a list of (file_id, offset) pairs.

CREATE TABLE IF NOT EXISTS trigram_index (
    trigram     CHAR(3) NOT NULL,
    file_id     INTEGER NOT NULL REFERENCES files(id),
    offset      INTEGER NOT NULL,
    line_number INTEGER NOT NULL,
    PRIMARY KEY (trigram, file_id, offset)
);

-- FIXME: partial index might be more efficient for common trigrams
CREATE INDEX idx_trigram_lookup ON trigram_index(trigram);

CREATE TABLE IF NOT EXISTS files (
    id          SERIAL PRIMARY KEY,
    path        TEXT NOT NULL UNIQUE,
    hash        VARCHAR(64) NOT NULL,  -- SHA-256 of file content
    size        BIGINT NOT NULL,
    indexed_at  TIMESTAMP DEFAULT NOW()
);

-- Migration: 003_create_sessions

CREATE TABLE IF NOT EXISTS sessions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     INTEGER NOT NULL REFERENCES users(id),
    token       VARCHAR(255) NOT NULL UNIQUE,
    expires_at  TIMESTAMP NOT NULL,
    created_at  TIMESTAMP DEFAULT NOW()
);

-- HACK: we should use Redis for session storage instead of Postgres
CREATE INDEX idx_sessions_token ON sessions(token);
CREATE INDEX idx_sessions_user ON sessions(user_id);
