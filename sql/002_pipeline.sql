-- Pipeline support: staging schema, Transfermarkt natural keys, snapshot tracking,
-- and relaxed constraints for what the Kaggle dataset can and cannot tell us.

CREATE SCHEMA IF NOT EXISTS stg;

-- Transfermarkt is the "spine" source: its IDs become natural keys so loads can upsert.
-- Other sources (FBref, etc.) get mapped to these rows through source_ids later.
ALTER TABLE leagues ADD COLUMN tm_competition_id TEXT UNIQUE;
ALTER TABLE leagues ADD COLUMN competition_type TEXT;
ALTER TABLE leagues ADD COLUMN sub_type TEXT;
ALTER TABLE leagues ALTER COLUMN tier DROP NOT NULL;   -- cups have no tier

ALTER TABLE clubs   ADD COLUMN tm_club_id BIGINT UNIQUE;
ALTER TABLE players ADD COLUMN tm_player_id BIGINT UNIQUE;

-- Some players have no listed position in the source.
ALTER TABLE players DROP CONSTRAINT IF EXISTS players_primary_position_check;
ALTER TABLE players ADD CONSTRAINT players_primary_position_check
    CHECK (primary_position IN ('GK','DF','MF','FW','UNK'));

-- The Kaggle transfers table has no loan/free flag, so type is often unknowable.
ALTER TABLE transfers DROP CONSTRAINT IF EXISTS transfers_transfer_type_check;
ALTER TABLE transfers ADD CONSTRAINT transfers_transfer_type_check
    CHECK (transfer_type IN ('permanent','loan','loan_with_option','free','end_of_loan','unknown'));

-- Natural key for idempotent upserts.
CREATE UNIQUE INDEX uq_transfers_natural ON transfers
    (player_id, transfer_date, (COALESCE(from_club_id, 0)), (COALESCE(to_club_id, 0)), source);

CREATE INDEX idx_player_seasons_player ON player_seasons (player_id);
CREATE INDEX idx_contracts_player ON contracts (player_id);

-- One row per downloaded dataset version.
CREATE TABLE dataset_snapshots (
    snapshot_id      SERIAL PRIMARY KEY,
    source           TEXT NOT NULL,
    version_hash     TEXT NOT NULL,
    fetched_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    row_counts       JSONB,
    status           TEXT NOT NULL CHECK (status IN ('fetched','rejected','loaded'))
);
CREATE INDEX idx_snapshots_source_status ON dataset_snapshots (source, status, snapshot_id);

ALTER TABLE ingestion_runs ADD COLUMN snapshot_id INT REFERENCES dataset_snapshots(snapshot_id);
