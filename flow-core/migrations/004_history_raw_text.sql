-- CREATE TABLE IF NOT EXISTS in migration 001 cannot upgrade a legacy table.
ALTER TABLE transcription_history ADD COLUMN raw_text TEXT NOT NULL DEFAULT '';
