# Transfer Value Analyzer

Flags football transfers and players as over- or undervalued relative to their level of play.
This repo currently contains the **data pipeline**: an idempotent weekly refresh that loads the
Kaggle Transfermarkt dataset into Postgres and reports how well it covers what the models need.

## Start

```bash
cp .env.example .env              # add Kaggle credentials (kaggle.com/settings -> API)
docker compose up -d db
pip install -r requirements.txt
export $(grep -v '^#' .env | xargs)
python -m pipeline.run            # first run: downloads, loads, writes reports/coverage_<date>.md
```

Read `reports/coverage_<date>.md` first. It answers whether Kaggle alone is enough:
valuation history by year, fee coverage, how many paid transfers have a recent market value,
playing-time coverage by position, and which stats exist.

Useful flags: `--from-dir DIR` (use local CSVs), `--force` (reload unchanged data),
`--relaxed` (skip minimum-size checks, for small test data).

## Recruitment hierarchy analysis

After the first successful refresh:

```bash
python -m analysis.recruitment_tiers            # defaults to transfers since 2012
```

Writes `reports/recruitment_hierarchy_<date>.md` and `reports/classified_transfers_<date>.csv`.
It rates every club into tiers T1-T5 from point-in-time squad market value (cut at percentiles of the
top-5-league clubs: top 10% / next 20% / next 30% / next 30% / bottom 10%), then classifies each paid
transfer as step-up, lateral or step-down and profiles it by player archetype (Prospect / Proven /
Rotation), selling tier, buying tier and era. Check the "Tier membership" section first: if the clubs
in each tier look wrong, nothing downstream can be trusted.

The analysis code is tested against a synthetic league with planted flows (`tests/synth.py`), which
proves the mechanics and that planted structure is recovered. It says nothing about real football.

## What a run does

1. **Migrate** : applies `sql/*.sql` once each, in order.
2. **Fetch** : downloads the dataset and hashes the files. Same hash as the last load = skip.
3. **Stage** : copies raw CSVs into `stg.*` (all TEXT), so upstream type quirks never break loading.
4. **Validate** : required columns present, minimum row counts, no more than 5% shrink vs the
   last load, well-formed ids and dates, orphan rates. Errors reject the snapshot and
   the core tables are not touched.
5. **Load** : typed upserts into the core tables inside one transaction (all-or-nothing).
6. **Report** : writes the coverage report.

Every run is recorded in `ingestion_runs` and `dataset_snapshots`, and an advisory lock stops two
refreshes from overlapping.

## Scheduling

Run it **daily**. The upstream dataset refreshes about weekly and a weekly schedule on our side would
stack a second week of lag on top. Days with no new upstream data cost almost nothing, because
the content hash matches and the run is skipped.

```
0 3 * * *  cd /path/to/transfer-value && docker compose run --rm refresh >> refresh.log 2>&1
```

### Freshness

The source updates as a whole snapshot, not per competition, so a mid-week snapshot can include
some clubs' latest matches and not others' (for example weekend league games but not the midweek
European round). Each loaded snapshot records `data_as_of` (newest match) and `values_as_of`
(newest market value) on `dataset_snapshots`, plus the newest match per competition in
`snapshot_freshness`. The pipeline warns, without blocking the load, when the newest match is more
than 10 days old or a top-5 league trails the others by more than 10 days. Those warnings also fire
during breaks, so read them as prompts to look, not as errors. The UI should show both dates.

Modelling consequence: use per-90 rates and minutes-based shrinkage, not raw totals, so clubs with
different numbers of matches played stay comparable.

Later, wrap `pipeline.run.main` in a Dagster job for retries, run history and alerts. The
pipeline functions don't change, only the scheduler does.

## Tests

Tests run the whole pipeline against a real Postgres using small generated CSVs:

```bash
TEST_DATABASE_URL=postgresql://tv:tv@localhost:5432/scratch pytest -q
```

They **drop the public and stg schemas**, so point them at a scratch database, never your real one.

## Design notes and known limits

- Transfermarkt ids are stored as natural keys (`tm_player_id`, `tm_club_id`, `tm_competition_id`).
  Other sources (FBref, etc.) should map onto these through `source_ids`.
- The Kaggle data has goals, assists, cards and minutes only. Advanced stats (xG and friends) need a
  supplemental source before midfield and defence ratings mean much.
- Transfer type is not in the source: `fee > 0` is labelled `permanent`, everything else `unknown`.
- Contract expiry is a snapshot of "now" with `observed_on` set to the first time we saw it. It is not
  valid as a historical feature for old transfers.
- Clubs that only appear in transfers become placeholder rows (`country = 'Unknown'`) so history isn't dropped.
- The column names the loader expects are listed in `pipeline/validate.py` (`REQUIRED_COLUMNS`).
  They were written from the dataset's published schema and have not been run against the live
  download yet. If Kaggle renamed anything, the first run fails with a clear message.
- Check the dataset's license and Transfermarkt's terms before publishing anything derived from it.
