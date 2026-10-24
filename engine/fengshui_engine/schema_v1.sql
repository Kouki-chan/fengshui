-- Fengshui schema v1 (spec §5). The ONLY copy: Swift (GRDB migrator) and
-- Python both execute this file. Index additions are listed in DECISIONS.md.
CREATE TABLE schema_version (version INTEGER NOT NULL);

-- PROCESSED: everything from HealthKit
CREATE TABLE processed_samples (
  id INTEGER PRIMARY KEY,
  hk_uuid TEXT UNIQUE NOT NULL,
  hk_type TEXT NOT NULL,
  label TEXT NOT NULL,
  value REAL,
  value_text TEXT,
  unit TEXT,
  start_ts REAL NOT NULL,
  end_ts REAL NOT NULL,
  minute_id INTEGER NOT NULL,
  source_name TEXT, source_bundle TEXT, device TEXT,
  metadata_json TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  inserted_at REAL NOT NULL
);
CREATE INDEX ix_ps_label_time ON processed_samples(label, start_ts);
CREATE INDEX ix_ps_minute ON processed_samples(minute_id);

CREATE TABLE processed_route_points (
  id INTEGER PRIMARY KEY,
  workout_uuid TEXT NOT NULL,
  ts REAL NOT NULL, minute_id INTEGER NOT NULL,
  lat REAL, lon REAL, alt_m REAL, speed_mps REAL, h_accuracy REAL
);
CREATE UNIQUE INDEX ux_route_workout_ts ON processed_route_points(workout_uuid, ts);

CREATE TABLE characteristics (key TEXT PRIMARY KEY, value TEXT);

-- RAW: watch sensor chunks, one per sensor per minute
CREATE TABLE raw_chunks (
  id INTEGER PRIMARY KEY,
  minute_id INTEGER NOT NULL,
  sensor TEXT NOT NULL,
  tier INTEGER NOT NULL,
  rate_hz REAL NOT NULL,
  sample_count INTEGER NOT NULL,
  axes INTEGER NOT NULL,
  encoding TEXT NOT NULL,
  scale REAL NOT NULL,
  offset REAL NOT NULL DEFAULT 0,
  payload BLOB,
  archive_ref TEXT, archived_at REAL,
  received_at REAL NOT NULL,
  UNIQUE(minute_id, sensor, tier)
);

CREATE TABLE raw_minute_features (
  minute_id INTEGER PRIMARY KEY,
  accel_samples INTEGER,
  enmo_mg REAL,
  mag_sd_mg REAL,
  cadence_hz REAL,
  active_frac REAL,
  pressure_kpa REAL,
  vert_speed_m_min REAL,
  heading_change_deg REAL,
  gyro_rms_dps REAL,
  feature_version TEXT NOT NULL,
  computed_at REAL NOT NULL
);

-- CONTEXT
CREATE TABLE context_motion (
  id INTEGER PRIMARY KEY,
  start_ts REAL NOT NULL, end_ts REAL,
  minute_id INTEGER NOT NULL,
  activity TEXT NOT NULL,
  confidence INTEGER NOT NULL,
  UNIQUE(start_ts, activity)
);

CREATE TABLE context_places (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL,
  radius_m REAL NOT NULL DEFAULT 150,
  confirmed INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);

CREATE TABLE context_visits (
  id INTEGER PRIMARY KEY,
  place_id INTEGER REFERENCES context_places(id),
  lat REAL NOT NULL, lon REAL NOT NULL, h_accuracy REAL,
  arrival_ts REAL NOT NULL, departure_ts REAL,
  minute_start INTEGER NOT NULL, minute_end INTEGER
);
CREATE INDEX ix_visits_arrival ON context_visits(arrival_ts);

CREATE TABLE context_screen_events (
  id INTEGER PRIMARY KEY,
  ts REAL NOT NULL, minute_id INTEGER NOT NULL,
  schedule TEXT NOT NULL,
  threshold_min INTEGER NOT NULL,
  UNIQUE(ts, schedule, threshold_min)
);

-- INFERENCES
CREATE TABLE inferences (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  minute_start INTEGER NOT NULL, minute_end INTEGER NOT NULL,
  value_json TEXT NOT NULL,
  confidence REAL,
  algorithm TEXT NOT NULL, algorithm_version TEXT NOT NULL,
  computed_at REAL NOT NULL,
  computed_where TEXT NOT NULL,
  provisional INTEGER NOT NULL DEFAULT 0,
  superseded_by INTEGER REFERENCES inferences(id)
);
CREATE INDEX ix_inf_kind_time ON inferences(kind, minute_start);

CREATE TABLE engine_state (key TEXT PRIMARY KEY, value TEXT);

-- SYSTEM
CREATE TABLE notifications_log (
  id INTEGER PRIMARY KEY,
  inference_id INTEGER REFERENCES inferences(id),
  kind TEXT NOT NULL, identifier TEXT NOT NULL,
  scheduled_for REAL, delivered_at REAL, cancelled_at REAL, created_at REAL NOT NULL
);
CREATE TABLE preferences (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE sync_state (
  hk_type TEXT PRIMARY KEY, anchor BLOB, last_sync_ts REAL, backfill_done INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE server_sync_state (table_name TEXT PRIMARY KEY, last_id_uploaded INTEGER, last_ts REAL);
CREATE TABLE ai_questions (
  id INTEGER PRIMARY KEY,
  owner TEXT NOT NULL,
  text TEXT NOT NULL,
  schedule TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);
CREATE TABLE ai_log (
  id INTEGER PRIMARY KEY,
  ts REAL NOT NULL, question TEXT NOT NULL, model TEXT NOT NULL,
  tool_calls_json TEXT, response_text TEXT,
  input_tokens INTEGER, output_tokens INTEGER, error TEXT
);

INSERT INTO schema_version (version) VALUES (1);
