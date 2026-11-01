-- AutomationKit - shared tables for the template pack.
-- Loaded automatically on first Postgres start (docker-entrypoint-initdb.d).
--
-- Two tables, two jobs:
--   processed_keys   -> idempotency (idempotency). Every template writes the event key here
--                       before doing side effects. A duplicate key returns 0 rows and the
--                       workflow stops, so retries never write the same record twice.
--   workflow_errors  -> error branch (error branch) sink. When a node fails, the error output
--                       writes one row here instead of failing silently.

CREATE TABLE IF NOT EXISTS processed_keys (
  key         text        PRIMARY KEY,
  workflow    text        NOT NULL,
  payload     jsonb,
  -- Two-phase claim (two-phase claim): 'claimed' = a run took the key, 'done' = side effects
  -- finished. A run that dies leaves the row in 'claimed'; the key becomes claimable again
  -- after the lease (lease) expires, so a failure never blocks the retry forever.
  status      text        NOT NULL DEFAULT 'claimed',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Migration for databases created by an earlier version (no-op on a fresh volume).
ALTER TABLE processed_keys ADD COLUMN IF NOT EXISTS status     text NOT NULL DEFAULT 'claimed';
ALTER TABLE processed_keys ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS processed_keys_workflow_created_idx
  ON processed_keys (workflow, created_at DESC);

CREATE TABLE IF NOT EXISTS workflow_errors (
  id          bigserial   PRIMARY KEY,
  workflow    text        NOT NULL,
  node        text,
  message     text,
  payload     jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS workflow_errors_workflow_created_idx
  ON workflow_errors (workflow, created_at DESC);

-- Low-confidence results land here instead of being written to a business table.
-- Used by invoice-parsing; other templates can reuse it with their own item_key.
CREATE TABLE IF NOT EXISTS review_queue (
  id          bigserial   PRIMARY KEY,
  workflow    text        NOT NULL,
  item_key    text        NOT NULL,
  reason      text,
  payload     jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workflow, item_key)
);
