import GRDB

public enum Schema {
  public static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    #if DEBUG
    // Dev safety net: a changed schema wipes the dev database. Remove before shipping.
    // Schema changes go in a new migration; never edit a registered one.
    migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v1") { db in
      try db.execute(sql: """
        CREATE TABLE asset (
          id TEXT PRIMARY KEY, mediaType INTEGER NOT NULL, subtypes INTEGER NOT NULL, created REAL, pixelW INTEGER, pixelH INTEGER,
          duration REAL, isFavorite INTEGER NOT NULL DEFAULT 0, burstId TEXT, uti TEXT, estBytes INTEGER NOT NULL DEFAULT 0,
          cloudOnly INTEGER NOT NULL DEFAULT 0, embedded INTEGER NOT NULL DEFAULT 0, signalsDone INTEGER NOT NULL DEFAULT 0,
          blur REAL, aesthetic REAL, isUtility INTEGER, sensitive INTEGER, phash INTEGER, featurePrint BLOB,
          deleted INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX asset_created ON asset(created);
        CREATE INDEX asset_phash ON asset(phash);
        CREATE INDEX asset_pending ON asset(created DESC, id) WHERE deleted = 0 AND (embedded = 0 OR signalsDone = 0);
        CREATE TABLE swipefile (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, preset TEXT, prompts TEXT NOT NULL,
          examples TEXT NOT NULL DEFAULT '[]', action TEXT NOT NULL, albumName TEXT, classifier BLOB,
          swipesSinceTrain INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL);
        CREATE TABLE decision (
          swipefileId TEXT NOT NULL REFERENCES swipefile(id) ON DELETE CASCADE, assetId TEXT NOT NULL, verdict TEXT NOT NULL,
          decidedAt REAL NOT NULL, applied INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (swipefileId, assetId));
        CREATE TABLE quota (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        """)
    }

    // The embedder revision a swipefile's classifier was trained on (see `SwipefileRecord`).
    migrator.registerMigration("v2") { db in
      try db.execute(sql: "ALTER TABLE swipefile ADD COLUMN classifierRevision TEXT")
    }

    // v3: `deletedAt` (when the asset left the library) and `attempts` (failed thumbnail loads). Assets
    // with `maxAttempts` failures leave the pending set until `Repositories.resetFailures()`.
    migrator.registerMigration("v3") { db in
      try db.execute(sql: """
        ALTER TABLE asset ADD COLUMN deletedAt REAL;
        ALTER TABLE asset ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
        UPDATE asset SET deletedAt = CAST(strftime('%s', 'now') AS REAL) WHERE deleted = 1;
        DROP INDEX asset_pending;
        CREATE INDEX asset_pending ON asset(created DESC, id)
          WHERE deleted = 0 AND attempts < \(maxAttempts) AND (embedded = 0 OR signalsDone = 0);
        """)
    }

    // v4: the squish journal (see `SquishJournalRecord`).
    migrator.registerMigration("v4") { db in
      try db.execute(sql: """
        CREATE TABLE squishJournal (
          assetID TEXT PRIMARY KEY, newAssetID TEXT, state TEXT NOT NULL, createdAt REAL NOT NULL, updatedAt REAL NOT NULL,
          originalBytes INTEGER NOT NULL, newBytes INTEGER NOT NULL, payload BLOB);
        CREATE INDEX squishJournal_state ON squishJournal(state);
        """)
    }

    // v5: the asset's modification date (library-owned) and remembered squish refusals (see `SquishRefusalRecord`).
    migrator.registerMigration("v5") { db in
      try db.execute(sql: """
        ALTER TABLE asset ADD COLUMN modified REAL;
        CREATE TABLE squishRefusal (
          assetId TEXT PRIMARY KEY, reason TEXT NOT NULL, modified REAL, refusedAt REAL NOT NULL);
        """)
    }

    // v6: where an asset's signals came from (`AnalysisSource`): the local preview of an iCloud-only original, or the
    // full image. Rows analysed before v6 used a full local image.
    migrator.registerMigration("v6") { db in
      try db.execute(sql: """
        ALTER TABLE asset ADD COLUMN source TEXT;
        UPDATE asset SET source = 'full' WHERE signalsDone = 1 AND cloudOnly = 0;
        """)
    }

    // v7: rows an earlier cloud flag left stuck (not analysed and no preview) go back to the local preview pass, which
    // excludes cloud rows without a source. Also the preview's long side in pixels (a preview smaller than the blur
    // analysis size can't say whether a photo is blurry) and the per-asset video format probe results.
    migrator.registerMigration("v7") { db in
      try db.execute(sql: """
        UPDATE asset SET cloudOnly = 0 WHERE signalsDone = 0 AND source IS NULL;
        ALTER TABLE asset ADD COLUMN previewSide INTEGER;
        CREATE TABLE videoProbe (
          assetId TEXT PRIMARY KEY, verdict TEXT NOT NULL, modified REAL, probedAt REAL NOT NULL);
        """)
    }

    // v8: locality is whether the original resource is on the device (`originalLocal`, NULL = not checked yet), never
    // inferred from thumbnails, so earlier inferences are dropped. Rows analysed before v8 used 960 px thumbnails.
    migrator.registerMigration("v8") { db in
      try db.execute(sql: """
        ALTER TABLE asset ADD COLUMN originalLocal INTEGER;
        UPDATE asset SET previewSide = 960 WHERE source = 'full' AND previewSide IS NULL;
        """)
    }

    // v9: what the video probe measured (codec, file size, frame rate; see `VideoProbeFacts`). Passes recorded before
    // v9 measured nothing, so they're dropped: each video is probed again (and isn't selected by default until then).
    migrator.registerMigration("v9") { db in
      try db.execute(sql: """
        DELETE FROM videoProbe;
        ALTER TABLE videoProbe ADD COLUMN codec TEXT;
        ALTER TABLE videoProbe ADD COLUMN bytes INTEGER;
        ALTER TABLE videoProbe ADD COLUMN fps REAL;
        """)
    }

    // v10: words read from images (see `Repositories+Text`). `assetText` holds one row per read image (text as read,
    // its search terms, the reader's revision, the long side of the image read, NULL when none could be loaded) and
    // `assetTextFts` indexes the terms. Porter stemming so "receipt" finds "receipts" and "printing" "printed" (English
    // only; other languages are folded and matched whole or as a prefix). The FTS table reads its content from
    // `assetText` and follows it through triggers; text goes when its asset is deleted, marked deleted, or edited
    // (`signalsDone` back to 0), whichever writer did it. Rows analysed before v10 have no text, so the text pass
    // (`TextIndexer`) picks them up: the gate's partial index (`TextGate.candidateWhere`, kept identical) makes that query cheap.
    migrator.registerMigration("v10") { db in
      try db.execute(sql: """
        CREATE TABLE assetText (
          id INTEGER PRIMARY KEY, assetId TEXT NOT NULL UNIQUE REFERENCES asset(id) ON DELETE CASCADE,
          text TEXT NOT NULL, terms TEXT NOT NULL, revision TEXT NOT NULL, side INTEGER, readAt REAL NOT NULL);
        CREATE VIRTUAL TABLE assetTextFts USING fts5(
          terms, content = 'assetText', content_rowid = 'id',
          tokenize = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'");
        CREATE TRIGGER assetText_ai AFTER INSERT ON assetText BEGIN
          INSERT INTO assetTextFts(rowid, terms) VALUES (new.id, new.terms);
        END;
        CREATE TRIGGER assetText_ad AFTER DELETE ON assetText BEGIN
          INSERT INTO assetTextFts(assetTextFts, rowid, terms) VALUES ('delete', old.id, old.terms);
        END;
        CREATE TRIGGER assetText_au AFTER UPDATE ON assetText BEGIN
          INSERT INTO assetTextFts(assetTextFts, rowid, terms) VALUES ('delete', old.id, old.terms);
          INSERT INTO assetTextFts(rowid, terms) VALUES (new.id, new.terms);
        END;
        CREATE TRIGGER asset_textGone AFTER UPDATE OF deleted ON asset WHEN new.deleted = 1 AND old.deleted = 0 BEGIN
          DELETE FROM assetText WHERE assetId = new.id;
        END;
        CREATE TRIGGER asset_textStale AFTER UPDATE OF signalsDone ON asset
          WHEN new.signalsDone = 0 AND old.signalsDone = 1 BEGIN
          DELETE FROM assetText WHERE assetId = new.id;
        END;
        CREATE INDEX asset_textGated ON asset(created DESC, id)
          WHERE deleted = 0 AND mediaType = 1 AND signalsDone = 1 AND ((subtypes & 4) != 0 OR isUtility = 1);
        """)
    }

    return migrator
  }

  /// Failed thumbnail loads after which an asset stops being pending (see `Repositories.resetFailures()`).
  /// Part of the `asset_pending` index definition: changing it needs a migration.
  public static let maxAttempts = 3
}
