CREATE EXTENSION IF NOT EXISTS pg_trgm;  -- fuzzy name matching for entity resolution

CREATE TABLE leagues (
    league_id        SERIAL PRIMARY KEY,
    name             TEXT NOT NULL,
    country          TEXT NOT NULL,
    tier             SMALLINT NOT NULL DEFAULT 1       -- 1 = top flight
);

CREATE TABLE clubs (
    club_id          SERIAL PRIMARY KEY,
    name             TEXT NOT NULL,
    country          TEXT NOT NULL,
    current_league_id INT REFERENCES leagues(league_id)
);

CREATE TABLE players (
    player_id        SERIAL PRIMARY KEY,
    full_name        TEXT NOT NULL,
    date_of_birth    DATE,
    nationality      TEXT,
    primary_position TEXT NOT NULL CHECK (primary_position IN ('GK','DF','MF','FW')),
    detailed_position TEXT,                            -- CB, FB, DM, CM, AM, W, ST...
    height_cm        SMALLINT,
    preferred_foot   TEXT
);
CREATE INDEX idx_players_name_trgm ON players USING gin (full_name gin_trgm_ops);

-- Mapping player/club IDs to each external source's IDs.
CREATE TABLE source_ids (
    entity_type      TEXT NOT NULL CHECK (entity_type IN ('player','club')),
    entity_id        INT  NOT NULL,
    source           TEXT NOT NULL,                    -- 'transfermarkt','fbref','understat'...
    source_key       TEXT NOT NULL,
    match_confidence REAL,                             -- 1.0 = exact, lower = fuzzy-matched
    PRIMARY KEY (source, entity_type, source_key)
);

-- One row per player + club + league + season (a player can have multiple stints/season).
CREATE TABLE player_seasons (
    player_season_id SERIAL PRIMARY KEY,
    player_id        INT NOT NULL REFERENCES players(player_id),
    club_id          INT NOT NULL REFERENCES clubs(club_id),
    league_id        INT NOT NULL REFERENCES leagues(league_id),
    season           TEXT NOT NULL,                    -- '2025-26'
    minutes_played   INT NOT NULL DEFAULT 0,
    appearances      SMALLINT,
    starts           SMALLINT,
    UNIQUE (player_id, club_id, league_id, season)
);

CREATE TABLE player_season_stats (
    player_season_id INT NOT NULL REFERENCES player_seasons(player_season_id),
    stat_name        TEXT NOT NULL,                    -- 'npxG','xAG','prog_passes','pressures'...
    value_total      NUMERIC,
    value_per90      NUMERIC,
    source           TEXT NOT NULL,
    PRIMARY KEY (player_season_id, stat_name, source)
);

CREATE TABLE contracts (
    contract_id      SERIAL PRIMARY KEY,
    player_id        INT NOT NULL REFERENCES players(player_id),
    club_id          INT NOT NULL REFERENCES clubs(club_id),
    start_date       DATE,
    expiry_date      DATE,
    observed_on      DATE NOT NULL                     -- when this info was looked at
);

CREATE TABLE injuries (
    injury_id        SERIAL PRIMARY KEY,
    player_id        INT NOT NULL REFERENCES players(player_id),
    start_date       DATE NOT NULL,
    end_date         DATE,
    injury_type      TEXT,
    games_missed     SMALLINT
);

-- Crowdsourced market value history (e.g. Transfermarkt)
CREATE TABLE valuations (
    valuation_id     BIGSERIAL PRIMARY KEY,
    player_id        INT NOT NULL REFERENCES players(player_id),
    club_id          INT REFERENCES clubs(club_id),
    valued_on        DATE NOT NULL,
    value_eur        BIGINT NOT NULL,
    source           TEXT NOT NULL,
    UNIQUE (player_id, valued_on, source)
);
CREATE INDEX idx_valuations_player_date ON valuations (player_id, valued_on);

-- Validation set
CREATE TABLE transfers (
    transfer_id      SERIAL PRIMARY KEY,
    player_id        INT NOT NULL REFERENCES players(player_id),
    from_club_id     INT REFERENCES clubs(club_id),
    to_club_id       INT REFERENCES clubs(club_id),
    transfer_date    DATE NOT NULL,
    transfer_type    TEXT NOT NULL CHECK (transfer_type IN ('permanent','loan','loan_with_option','free','end_of_loan')),
    fee_eur          BIGINT,                           -- NULL = undisclosed
    fee_includes_addons BOOLEAN,
    fee_is_estimated BOOLEAN NOT NULL DEFAULT FALSE,
    market_value_at_transfer_eur BIGINT,               -- denormalized snapshot for convenience
    source           TEXT NOT NULL
);
CREATE INDEX idx_transfers_date ON transfers (transfer_date);

-- Adjusting/Reference
-- League strength so 12 goals in league A != 12 goals in league B.
CREATE TABLE league_adjustments (
    league_id        INT NOT NULL REFERENCES leagues(league_id),
    season           TEXT NOT NULL,
    strength_factor  NUMERIC NOT NULL,                 -- relative to a baseline league = 1.0
    method           TEXT,                             -- 'uefa_coeff','elo_cross_league','derived'
    PRIMARY KEY (league_id, season)
);

-- Fee inflation normalization by season.
CREATE TABLE market_inflation (
    season           TEXT PRIMARY KEY,
    inflation_index  NUMERIC NOT NULL                  -- base season = 1.0
);

-- Model Layer(derived; always rerunnable)
CREATE TABLE model_versions (
    model_version_id SERIAL PRIMARY KEY,
    model_kind       TEXT NOT NULL CHECK (model_kind IN ('performance','fair_value')),
    name             TEXT NOT NULL,
    trained_through  DATE NOT NULL,                    -- latest data date used in training
    params_json      JSONB,
    metrics_json     JSONB,                            -- MAE, R2, calibration, per-position
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Position-specific, league-adjusted performance rating as of a date.
CREATE TABLE performance_scores (
    player_id        INT NOT NULL REFERENCES players(player_id),
    as_of_date       DATE NOT NULL,
    model_version_id INT NOT NULL REFERENCES model_versions(model_version_id),
    score            NUMERIC NOT NULL,                 -- 0-100 or z-score
    position_percentile NUMERIC,
    minutes_basis    INT NOT NULL,                     -- sample size behind the score
    uncertainty      NUMERIC,                          -- wider for low minutes
    PRIMARY KEY (player_id, as_of_date, model_version_id)
);

-- What the player "should" be worth, with an interval.
CREATE TABLE fair_value_predictions (
    player_id        INT NOT NULL REFERENCES players(player_id),
    as_of_date       DATE NOT NULL,
    model_version_id INT NOT NULL REFERENCES model_versions(model_version_id),
    predicted_value_eur BIGINT NOT NULL,
    lower_80_eur     BIGINT,
    upper_80_eur     BIGINT,
    top_features_json JSONB,                           -- explainability (SHAP) for scouts
    PRIMARY KEY (player_id, as_of_date, model_version_id)
);

-- One verdict per transfer (and optionally per valuation date).
CREATE TABLE transfer_verdicts (
    transfer_id      INT NOT NULL REFERENCES transfers(transfer_id),
    model_version_id INT NOT NULL REFERENCES model_versions(model_version_id),
    paid_eur         BIGINT,                           -- fee, or market value if fee undisclosed
    paid_basis       TEXT NOT NULL CHECK (paid_basis IN ('fee','market_value')),
    fair_value_eur   BIGINT NOT NULL,
    residual_eur     BIGINT NOT NULL,                  -- paid - fair (positive = overpaid)
    residual_pct     NUMERIC NOT NULL,
    verdict          TEXT NOT NULL CHECK (verdict IN ('undervalued','fair','overvalued','insufficient_data')),
    confidence       TEXT NOT NULL CHECK (confidence IN ('low','medium','high')),
    PRIMARY KEY (transfer_id, model_version_id)
);

-- Nearest-neighbor comparables ("similar players who sold for X"), a scout-facing feature.
CREATE TABLE player_comparables (
    player_id        INT NOT NULL REFERENCES players(player_id),
    as_of_date       DATE NOT NULL,
    comparable_player_id INT NOT NULL REFERENCES players(player_id),
    similarity       NUMERIC NOT NULL,
    PRIMARY KEY (player_id, as_of_date, comparable_player_id)
);

CREATE TABLE ingestion_runs (
    run_id           SERIAL PRIMARY KEY,
    source           TEXT NOT NULL,
    started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at      TIMESTAMPTZ,
    status           TEXT,
    rows_loaded      INT,
    notes            TEXT
);
