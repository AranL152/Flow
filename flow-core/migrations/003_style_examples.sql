-- Keep fork personalization examples when upgrading either database lineage.
CREATE TABLE IF NOT EXISTS style_examples (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    said TEXT NOT NULL,
    flow_output TEXT NOT NULL,
    sent TEXT NOT NULL,
    edited INTEGER NOT NULL,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_style_examples_created ON style_examples(created_at);

-- Must stay last: the migration runner tolerates an already-present column.
ALTER TABLE style_examples ADD COLUMN contact_key TEXT NOT NULL DEFAULT '';
