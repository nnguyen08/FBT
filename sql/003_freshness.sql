-- Data freshness: how recent is each snapshot, overall and per competition?
-- The source refreshes as a whole snapshot, so a mid-week snapshot can hold some clubs'
-- latest matches and not others'. Recording this lets the UI say "stats through <date>"
-- and lets validation flag a partial scrape.

ALTER TABLE dataset_snapshots ADD COLUMN data_as_of DATE;    -- newest match in appearances
ALTER TABLE dataset_snapshots ADD COLUMN values_as_of DATE;  -- newest market valuation

CREATE TABLE snapshot_freshness (
    snapshot_id      INT  NOT NULL REFERENCES dataset_snapshots(snapshot_id) ON DELETE CASCADE,
    competition_id   TEXT NOT NULL,
    newest_match     DATE NOT NULL,
    appearance_rows  INT  NOT NULL,
    PRIMARY KEY (snapshot_id, competition_id)
);
