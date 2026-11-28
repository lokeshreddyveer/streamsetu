import Foundation

/// The graph database schema, version 1 (section 2.3). Append new versions to `MusicGraphMigrator.migrations`; never edit a released one.
enum MusicGraphSchemaV1 {
    static let sql = """
    CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
    CREATE TABLE entity(
      rid         INTEGER PRIMARY KEY,
      id          TEXT NOT NULL UNIQUE,
      kind        INTEGER NOT NULL,
      subkind     TEXT,
      name        TEXT NOT NULL,
      name_latin  TEXT NOT NULL,
      lang        TEXT, year INTEGER, year_end INTEGER, country TEXT,
      duration_ms INTEGER, image_ref TEXT,
      attrs       BLOB,
      provisional INTEGER NOT NULL DEFAULT 0,
      state       INTEGER NOT NULL DEFAULT 0,
      merged_into INTEGER REFERENCES entity(rid) ON DELETE SET NULL,
      pinned      INTEGER NOT NULL DEFAULT 0,
      created_at  INTEGER NOT NULL, updated_at INTEGER NOT NULL, accessed_at INTEGER NOT NULL
    );
    CREATE INDEX entity_kind_latin ON entity(kind, name_latin);
    CREATE INDEX entity_kind_year  ON entity(kind, year);
    CREATE INDEX entity_access     ON entity(pinned, accessed_at);
    CREATE INDEX entity_merged     ON entity(merged_into) WHERE merged_into IS NOT NULL;

    CREATE TABLE external_id(
      entity INTEGER NOT NULL REFERENCES entity(rid) ON DELETE CASCADE,
      scheme TEXT NOT NULL, value TEXT NOT NULL,
      strong INTEGER NOT NULL, source TEXT, retrieved_at INTEGER NOT NULL, conflict INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(entity, scheme, value)
    );
    CREATE UNIQUE INDEX external_strong ON external_id(scheme, value) WHERE strong = 1 AND conflict = 0;
    CREATE INDEX external_lookup ON external_id(scheme, value);

    CREATE TABLE name_alias(
      entity INTEGER NOT NULL REFERENCES entity(rid) ON DELETE CASCADE,
      text TEXT NOT NULL, latin TEXT NOT NULL, lang TEXT, script TEXT,
      primary_name INTEGER NOT NULL DEFAULT 0, source TEXT,
      PRIMARY KEY(entity, text)
    );
    CREATE INDEX alias_latin ON name_alias(latin);

    CREATE VIRTUAL TABLE entity_fts USING fts5(
      name, latin, aliases, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
    );

    CREATE TABLE edge(
      rid INTEGER PRIMARY KEY,
      subject INTEGER NOT NULL REFERENCES entity(rid) ON DELETE CASCADE,
      predicate INTEGER NOT NULL,
      object INTEGER NOT NULL REFERENCES entity(rid) ON DELETE CASCADE,
      qual TEXT NOT NULL DEFAULT '',
      attrs BLOB, ord INTEGER,
      confidence REAL NOT NULL, status INTEGER NOT NULL, credit_level INTEGER NOT NULL DEFAULT 3,
      tomb INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      UNIQUE(subject, predicate, object, qual)
    );
    CREATE INDEX edge_out ON edge(subject, predicate, tomb, ord);
    CREATE INDEX edge_in  ON edge(object, predicate, tomb);

    CREATE TABLE fact(
      rid INTEGER PRIMARY KEY,
      edge INTEGER NOT NULL REFERENCES edge(rid) ON DELETE CASCADE,
      source TEXT NOT NULL, source_ref TEXT NOT NULL DEFAULT '',
      retrieved_at INTEGER NOT NULL, expires_at INTEGER,
      license INTEGER NOT NULL, score REAL, matcher_version INTEGER, evidence TEXT,
      stance INTEGER NOT NULL DEFAULT 1, override INTEGER NOT NULL DEFAULT 0,
      UNIQUE(edge, source, source_ref)
    );
    CREATE INDEX fact_expiry ON fact(expires_at) WHERE expires_at IS NOT NULL;

    CREATE TABLE cache_state(
      entity INTEGER NOT NULL REFERENCES entity(rid) ON DELETE CASCADE,
      facet TEXT NOT NULL, source TEXT NOT NULL,
      fetched_at INTEGER, expires_at INTEGER, outcome INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0, next_retry_at INTEGER, etag TEXT, matcher_version INTEGER,
      PRIMARY KEY(entity, facet, source)
    );
    CREATE TABLE work_item(
      rid INTEGER PRIMARY KEY, entity INTEGER NOT NULL, facet TEXT NOT NULL, source TEXT NOT NULL,
      lane INTEGER NOT NULL, priority INTEGER NOT NULL, not_before INTEGER NOT NULL, created_at INTEGER NOT NULL,
      UNIQUE(entity, facet, source)
    );
    CREATE TABLE source_health(source TEXT PRIMARY KEY, state INTEGER NOT NULL, failures INTEGER NOT NULL, open_until INTEGER, last_ok INTEGER);
    CREATE TABLE affinity(
      entity INTEGER PRIMARY KEY REFERENCES entity(rid) ON DELETE CASCADE,
      score REAL NOT NULL, plays INTEGER NOT NULL, completes INTEGER NOT NULL, skips INTEGER NOT NULL, likes INTEGER NOT NULL,
      last_event INTEGER NOT NULL
    );
    CREATE TABLE rec_cache(
      entity INTEGER NOT NULL, view TEXT NOT NULL, payload BLOB NOT NULL, graph_rev INTEGER NOT NULL, computed_at INTEGER NOT NULL,
      PRIMARY KEY(entity, view)
    );
    CREATE TABLE decision(
      rid INTEGER PRIMARY KEY, kind TEXT NOT NULL, a INTEGER NOT NULL, b INTEGER, verdict INTEGER NOT NULL,
      score REAL, by_user INTEGER NOT NULL DEFAULT 0, matcher_version INTEGER, created_at INTEGER NOT NULL
    );
    INSERT INTO meta(k, v) VALUES('graph_rev', '0');
    """
}
