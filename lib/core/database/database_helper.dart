import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Manages SQLite lifecycle, desktop FFI initialization, and configurable vault path.
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static const String _prefVaultDirKey = 'vault_custom_dir';
  static const String _prefReadOnlyExamKey = 'vault_exam_read_only';
  static const String _prefStructureLockedKey = 'vault_structure_locked';
  static const String _prefSkipSeedKey = 'vault_skip_seed_after_signout';
  static const String dbFileName = 'vault_study.db';
  static const String vaultFilesFolderName = 'vault_files';

  static bool _ffiInitialized = false;

  Database? _db;
  Future<Database>? _dbOpeningFuture;
  String? _vaultRootDir;
  Future<String>? _vaultRootDirFuture;

  static void ensureFfiInitialized() {
    if (_ffiInitialized) return;
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _ffiInitialized = true;
  }

  /// Resolves and ensures the vault root directory (default or user-configured).
  Future<String> getVaultRootDir() async {
    if (_vaultRootDir != null) return _vaultRootDir!;
    return _vaultRootDirFuture ??= _resolveVaultRootDir().catchError((Object e) {
      _vaultRootDirFuture = null;
      throw e;
    });
  }

  Future<String> _resolveVaultRootDir() async {
    final prefs = await SharedPreferences.getInstance();
    final customDir = prefs.getString(_prefVaultDirKey);
    if (customDir != null && customDir.trim().isNotEmpty) {
      final dir = Directory(customDir);
      if (await dir.exists() || await _tryCreateDir(dir)) {
        _vaultRootDir = dir.path;
        await Directory(p.join(_vaultRootDir!, vaultFilesFolderName))
            .create(recursive: true);
        return _vaultRootDir!;
      }
    }

    final supportDir = await getApplicationSupportDirectory();
    final defaultVaultDir = Directory(p.join(supportDir.path, 'VaultStudy'));
    await Directory(p.join(defaultVaultDir.path, vaultFilesFolderName))
        .create(recursive: true);
    _vaultRootDir = defaultVaultDir.path;
    return _vaultRootDir!;
  }

  Future<bool> _tryCreateDir(Directory dir) async {
    try {
      await dir.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> getVaultFilesDir() async {
    final root = await getVaultRootDir();
    final filesDir = Directory(p.join(root, vaultFilesFolderName));
    if (!await filesDir.exists()) {
      await filesDir.create(recursive: true);
    }
    return filesDir.path;
  }

  Future<String> getDatabasePath() async {
    final root = await getVaultRootDir();
    return p.join(root, dbFileName);
  }

  /// Resolves a stored relative path (inside vault_files) or absolute path.
  Future<String> resolveVaultFilePath(String storedPath) async {
    if (p.isAbsolute(storedPath)) return storedPath;
    final root = await getVaultRootDir();
    return p.join(root, storedPath);
  }

  Future<void> setCustomVaultDir(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    await close();
    if (path == null || path.trim().isEmpty) {
      await prefs.remove(_prefVaultDirKey);
    } else {
      await prefs.setString(_prefVaultDirKey, path.trim());
    }
    _vaultRootDir = null;
    _vaultRootDirFuture = null;
  }

  Future<bool> getExamReadOnlyMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefReadOnlyExamKey) ?? false;
  }

  Future<void> setExamReadOnlyMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefReadOnlyExamKey, value);
  }

  Future<bool> getStructureLockedMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefStructureLockedKey) ?? true;
  }

  Future<void> setStructureLockedMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefStructureLockedKey, value);
  }

  Future<bool> getSkipSeedAfterSignOut() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefSkipSeedKey) ?? false;
  }

  Future<void> setSkipSeedAfterSignOut(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefSkipSeedKey, value);
  }

  /// Physically removes all local vault database files (including WAL/SHM
  /// journals) and cached PDF binaries so zero data residue remains on disk
  /// after Sign Out.
  Future<void> clearAllLocalVaultData() async {
    final db = await database;
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}
    await close();

    final dbPath = await getDatabasePath();
    for (final path in [
      dbPath,
      '$dbPath-wal',
      '$dbPath-shm',
      '$dbPath-journal',
    ]) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }

    final filesDir = Directory(await getVaultFilesDir());
    if (await filesDir.exists()) {
      await filesDir.delete(recursive: true);
    }
    await filesDir.create(recursive: true);
    await setSkipSeedAfterSignOut(true);
  }

  Future<Database> get database async {
    if (_db != null && _db!.isOpen) return _db!;
    return _dbOpeningFuture ??= _openDatabase().catchError((Object e) {
      _dbOpeningFuture = null;
      throw e;
    });
  }

  Future<Database> _openDatabase() async {
    ensureFfiInitialized();
    final dbPath = await getDatabasePath();
    final opened = await openDatabase(
      dbPath,
      version: 2,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        try {
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = NORMAL');
          await db.execute('PRAGMA temp_store = MEMORY');
        } catch (_) {}
      },
      onCreate: (db, version) async {
        await createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _upgradeToV2(db);
        }
      },
    );
    _db = opened;
    return opened;
  }

  static Future<void> _upgradeToV2(Database db) async {
    await db.execute(
      'ALTER TABLE items ADD COLUMN sync_dirty INTEGER DEFAULT 1',
    );
    await db.execute(
      'ALTER TABLE pdf_annotations ADD COLUMN sync_dirty INTEGER DEFAULT 1',
    );
    await _createSyncTombstonesTable(db);
  }

  static Future<void> _createSyncTombstonesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_tombstones (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        storage_object_path TEXT NULL,
        deleted_at TEXT NOT NULL
      )
    ''');
  }

  /// Creates the VaultStudy SQLite schema on [db]. Exposed for unit tests.
  static Future<void> createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY,
        parent_id TEXT NULL,
        title TEXT NOT NULL,
        type TEXT NOT NULL CHECK(type IN ('folder','pdf','book','note')),
        file_path TEXT NULL,
        file_size INTEGER DEFAULT 0,
        extracted_text TEXT DEFAULT '',
        content_md TEXT DEFAULT '',
        is_pinned INTEGER DEFAULT 0,
        sort_order INTEGER DEFAULT 0,
        updated_at TEXT NOT NULL,
        sync_dirty INTEGER DEFAULT 1,
        FOREIGN KEY (parent_id) REFERENCES items(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_items_parent ON items(parent_id, sort_order)',
    );
    await db.execute(
      'CREATE INDEX idx_items_pinned ON items(is_pinned)',
    );

    await db.execute('''
      CREATE TABLE pdf_pages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id TEXT NOT NULL,
        page_number INTEGER NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_pdf_pages_item_page ON pdf_pages(item_id, page_number)',
    );

    await db.execute('''
      CREATE TABLE pdf_annotations (
        id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL,
        page_number INTEGER NOT NULL,
        rects_json TEXT NOT NULL,
        selected_text TEXT NOT NULL DEFAULT '',
        color_hex TEXT NOT NULL DEFAULT '#4EDEA3',
        note TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        sync_dirty INTEGER DEFAULT 1,
        FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_pdf_annotations_item_page ON pdf_annotations(item_id, page_number)',
    );
    await _createSyncTombstonesTable(db);
  }

  Future<void> close() async {
    _dbOpeningFuture = null;
    if (_db != null && _db!.isOpen) {
      await _db!.close();
    }
    _db = null;
  }
}
