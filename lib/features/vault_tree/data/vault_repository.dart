import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/storage/vault_storage_service.dart';
import '../../global_search/domain/search_result.dart';
import '../domain/vault_item.dart';

class SyncTombstone {
  const SyncTombstone({
    required this.id,
    required this.entityType,
    this.storageObjectPath,
    required this.deletedAt,
  });

  final String id;
  final String entityType; // 'item' | 'annotation'
  final String? storageObjectPath;
  final DateTime deletedAt;

  factory SyncTombstone.fromMap(Map<String, Object?> map) {
    return SyncTombstone(
      id: map['id'] as String,
      entityType: map['entity_type'] as String,
      storageObjectPath: map['storage_object_path'] as String?,
      deletedAt: DateTime.tryParse(map['deleted_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// SQLite repository for hierarchical `items`, `pdf_pages`, and `pdf_annotations`.
class VaultRepository {
  VaultRepository({Future<Database> Function()? databaseProvider})
      : _databaseProvider =
            databaseProvider ?? (() => DatabaseHelper.instance.database);

  final Future<Database> Function() _databaseProvider;

  Future<Database> get _db => _databaseProvider();

  Future<List<VaultItem>> getAllItems({bool includeExtractedText = true}) async {
    final db = await _db;
    final rows = await db.query(
      'items',
      columns: includeExtractedText
          ? null
          : const [
              'id',
              'parent_id',
              'title',
              'type',
              'file_path',
              'file_size',
              'content_md',
              'is_pinned',
              'sort_order',
              'updated_at',
            ],
      orderBy: 'sort_order ASC, title COLLATE NOCASE ASC',
    );
    return rows.map(VaultItem.fromMap).toList();
  }

  Future<void> insertItem(VaultItem item, {bool syncDirty = true}) async {
    final db = await _db;
    await db.insert(
      'items',
      {...item.toMap(), 'sync_dirty': syncDirty ? 1 : 0},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertPdfWithPages(
    VaultItem item,
    List<PdfPageEntry> pages, {
    bool syncDirty = true,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert(
        'items',
        {...item.toMap(), 'sync_dirty': syncDirty ? 1 : 0},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'pdf_pages',
        where: 'item_id = ?',
        whereArgs: [item.id],
      );
      for (final page in pages) {
        await txn.insert('pdf_pages', {
          'item_id': page.itemId,
          'page_number': page.pageNumber,
          'content': page.content,
        });
      }
    });
  }

  Future<void> updateItem(VaultItem item, {bool syncDirty = true}) async {
    final db = await _db;
    await db.update(
      'items',
      {...item.toMap(), 'sync_dirty': syncDirty ? 1 : 0},
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<void> renameItem(String id, String newTitle) async {
    final db = await _db;
    await db.update(
      'items',
      {
        'title': newTitle.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'sync_dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateNoteContent({
    required String id,
    required String title,
    required String contentMd,
  }) async {
    final db = await _db;
    await db.update(
      'items',
      {
        'title': title.trim().isEmpty ? 'Nota sin título' : title.trim(),
        'content_md': contentMd,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'sync_dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> togglePin(String id, bool isPinned) async {
    final db = await _db;
    await db.update(
      'items',
      {
        'is_pinned': isPinned ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'sync_dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateDocumentType(String id, VaultItemType newType) async {
    if (!newType.isDocument) return;
    final db = await _db;
    await db.update(
      'items',
      {
        'type': newType.dbValue,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'sync_dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> moveItem(String id, String? newParentId) async {
    if (id == newParentId) return;
    final items = await getAllItems();
    if (newParentId != null && _isDescendant(items, id, newParentId)) {
      throw ArgumentError('No puedes mover una carpeta dentro de sí misma.');
    }
    final db = await _db;
    await db.update(
      'items',
      {
        'parent_id': newParentId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'sync_dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  bool _isDescendant(List<VaultItem> items, String ancestorId, String targetId) {
    final byId = {for (final i in items) i.id: i};
    String? cursor = targetId;
    while (cursor != null) {
      if (cursor == ancestorId) return true;
      cursor = byId[cursor]?.parentId;
    }
    return false;
  }

  Future<void> reorderSibling(String id, int delta) async {
    final items = await getAllItems();
    final target = items.where((e) => e.id == id).firstOrNull;
    if (target == null) return;

    final siblings = items
        .where((e) => e.parentId == target.parentId)
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    final currentIndex = siblings.indexWhere((e) => e.id == id);
    final newIndex = currentIndex + delta;
    if (currentIndex < 0 || newIndex < 0 || newIndex >= siblings.length) return;

    final moved = siblings.removeAt(currentIndex);
    siblings.insert(newIndex, moved);

    final db = await _db;
    await db.transaction((txn) async {
      for (var i = 0; i < siblings.length; i++) {
        await txn.update(
          'items',
          {
            'sort_order': i,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            'sync_dirty': 1,
          },
          where: 'id = ?',
          whereArgs: [siblings[i].id],
        );
      }
    });
  }

  Future<void> deleteItem(
    String id, {
    bool deleteStoredFiles = true,
    bool recordTombstone = true,
  }) async {
    final items = await getAllItems();
    final toDeleteIds = <String>[];
    final toDeletePaths = <String>[];
    final tombstoneItems = <({String id, String? storageRelPath})>[];

    void collectFiles(String nodeId) {
      final node = items.where((e) => e.id == nodeId).firstOrNull;
      if (node != null) {
        toDeleteIds.add(node.id);
        if (node.filePath != null && node.filePath!.isNotEmpty) {
          toDeletePaths.add(node.filePath!);
          tombstoneItems.add((
            id: node.id,
            storageRelPath: '${node.id}/${p.basename(node.filePath!)}',
          ));
        } else {
          tombstoneItems.add((id: node.id, storageRelPath: null));
        }
      }
      for (final child in items.where((e) => e.parentId == nodeId)) {
        collectFiles(child.id);
      }
    }

    collectFiles(id);

    final db = await _db;
    final deletedAt = DateTime.now().toUtc().toIso8601String();

    await db.transaction((txn) async {
      if (recordTombstone && toDeleteIds.isNotEmpty) {
        final placeholders = List.filled(toDeleteIds.length, '?').join(',');
        final annRows = await txn.query(
          'pdf_annotations',
          columns: ['id'],
          where: 'item_id IN ($placeholders)',
          whereArgs: toDeleteIds,
        );
        for (final row in annRows) {
          await txn.insert(
            'sync_tombstones',
            {
              'id': row['id'] as String,
              'entity_type': 'annotation',
              'storage_object_path': null,
              'deleted_at': deletedAt,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final entry in tombstoneItems) {
          await txn.insert(
            'sync_tombstones',
            {
              'id': entry.id,
              'entity_type': 'item',
              'storage_object_path': entry.storageRelPath,
              'deleted_at': deletedAt,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await txn.delete('items', where: 'id = ?', whereArgs: [id]);
    });

    if (deleteStoredFiles) {
      for (final path in toDeletePaths) {
        await VaultStorageService.instance.deleteStoredFile(path);
      }
    }
  }

  // --- PDF Annotations ---

  Future<List<PdfAnnotation>> getAnnotations(String itemId) async {
    final db = await _db;
    final rows = await db.query(
      'pdf_annotations',
      where: 'item_id = ?',
      whereArgs: [itemId],
      orderBy: 'page_number ASC, created_at ASC',
    );
    return rows.map(PdfAnnotation.fromMap).toList();
  }

  Future<List<PdfAnnotation>> getAllAnnotations() async {
    final db = await _db;
    final rows = await db.query(
      'pdf_annotations',
      orderBy: 'page_number ASC, created_at ASC',
    );
    return rows.map(PdfAnnotation.fromMap).toList();
  }

  Future<void> addAnnotation(
    PdfAnnotation annotation, {
    bool syncDirty = true,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert(
        'pdf_annotations',
        {...annotation.toMap(), 'sync_dirty': syncDirty ? 1 : 0},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (syncDirty) {
        await txn.delete(
          'sync_tombstones',
          where: 'id = ? AND entity_type = ?',
          whereArgs: [annotation.id, 'annotation'],
        );
      }
    });
  }

  Future<void> deleteAnnotation(
    String annotationId, {
    bool recordTombstone = true,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      if (recordTombstone) {
        await txn.insert(
          'sync_tombstones',
          {
            'id': annotationId,
            'entity_type': 'annotation',
            'storage_object_path': null,
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.delete(
        'pdf_annotations',
        where: 'id = ?',
        whereArgs: [annotationId],
      );
    });
  }

  // --- Cloud Sync Helpers ---

  Future<List<VaultItem>> getDirtyItems() async {
    final db = await _db;
    final rows = await db.query(
      'items',
      where: 'sync_dirty = 1',
      orderBy: 'parent_id ASC, sort_order ASC',
    );
    return rows.map(VaultItem.fromMap).toList();
  }

  Future<List<PdfAnnotation>> getDirtyAnnotations() async {
    final db = await _db;
    final rows = await db.query(
      'pdf_annotations',
      where: 'sync_dirty = 1',
    );
    return rows.map(PdfAnnotation.fromMap).toList();
  }

  Future<List<SyncTombstone>> getTombstones() async {
    final db = await _db;
    final rows = await db.query('sync_tombstones');
    return rows.map(SyncTombstone.fromMap).toList();
  }

  Future<void> removeTombstone(String id, String entityType) async {
    final db = await _db;
    await db.delete(
      'sync_tombstones',
      where: 'id = ? AND entity_type = ?',
      whereArgs: [id, entityType],
    );
  }

  Future<void> markItemsSynced(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await _db;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE items SET sync_dirty = 0 WHERE id IN ($placeholders)',
      ids,
    );
  }

  Future<void> markAnnotationsSynced(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await _db;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE pdf_annotations SET sync_dirty = 0 WHERE id IN ($placeholders)',
      ids,
    );
  }

  Future<int> getPendingSyncCount() async {
    final db = await _db;
    final itemsRes = await db.rawQuery(
      'SELECT COUNT(*) as c FROM items WHERE sync_dirty = 1',
    );
    final annRes = await db.rawQuery(
      'SELECT COUNT(*) as c FROM pdf_annotations WHERE sync_dirty = 1',
    );
    final tombRes = await db.rawQuery(
      'SELECT COUNT(*) as c FROM sync_tombstones',
    );
    return ((itemsRes.first['c'] as int?) ?? 0) +
        ((annRes.first['c'] as int?) ?? 0) +
        ((tombRes.first['c'] as int?) ?? 0);
  }

  // --- Global Search ---

  static final RegExp _fencedCodeRegex = RegExp(
    r'```[^\n]*\n([\s\S]*?)```',
    multiLine: true,
  );

  Future<List<SearchResult>> search(
    String rawQuery, {
    SearchFilter filter = SearchFilter.all,
  }) async {
    final query = rawQuery.trim();
    final items = await getAllItems();
    final byId = {for (final i in items) i.id: i};

    String breadcrumbFor(VaultItem item) {
      final parts = <String>[];
      String? cursor = item.parentId;
      while (cursor != null) {
        final parent = byId[cursor];
        if (parent == null) break;
        parts.insert(0, parent.title);
        cursor = parent.parentId;
      }
      return parts.isEmpty ? 'Raíz de Bóveda' : parts.join(' > ');
    }

    if (query.isEmpty) {
      final nonFolders = items.where((e) => e.type != VaultItemType.folder);
      return nonFolders
          .where((item) => switch (filter) {
                SearchFilter.all => true,
                SearchFilter.pdfs => item.type.isDocument,
                SearchFilter.notes => item.type == VaultItemType.note,
                SearchFilter.codeOnly =>
                  item.type == VaultItemType.note &&
                      _fencedCodeRegex.hasMatch(item.contentMd),
              })
          .take(20)
          .map(
            (item) => SearchResult(
              item: item,
              breadcrumb: breadcrumbFor(item),
              snippet: item.type == VaultItemType.note
                  ? _previewText(item.contentMd)
                  : _previewText(item.extractedText),
              isCodeMatch: filter == SearchFilter.codeOnly,
            ),
          )
          .toList();
    }

    final qLower = query.toLowerCase();
    final results = <SearchResult>[];
    final db = await _db;

    // 1. Notes & Code search
    if (filter == SearchFilter.all ||
        filter == SearchFilter.notes ||
        filter == SearchFilter.codeOnly) {
      for (final item in items.where((e) => e.type == VaultItemType.note)) {
        final codeBlocks = _fencedCodeRegex
            .allMatches(item.contentMd)
            .map((m) => m.group(1) ?? '')
            .join('\n');

        final matchesCode = codeBlocks.toLowerCase().contains(qLower);
        if (filter == SearchFilter.codeOnly) {
          if (matchesCode) {
            results.add(
              SearchResult(
                item: item,
                breadcrumb: breadcrumbFor(item),
                snippet: _extractSnippet(codeBlocks, query),
                isCodeMatch: true,
              ),
            );
          }
          continue;
        }

        final titleMatch = item.title.toLowerCase().contains(qLower);
        final bodyMatch = item.contentMd.toLowerCase().contains(qLower);
        if (titleMatch || bodyMatch) {
          results.add(
            SearchResult(
              item: item,
              breadcrumb: breadcrumbFor(item),
              snippet: bodyMatch
                  ? _extractSnippet(item.contentMd, query)
                  : _previewText(item.contentMd),
              isCodeMatch: matchesCode,
            ),
          );
        }
      }
    }

    // 2. PDFs & Books search (page-level accuracy)
    if (filter == SearchFilter.all || filter == SearchFilter.pdfs) {
      final docItems = items.where((e) => e.type.isDocument).toList();
      final docMap = {for (final d in docItems) d.id: d};

      final pageRows = await db.query(
        'pdf_pages',
        where: 'LOWER(content) LIKE ?',
        whereArgs: ['%$qLower%'],
        orderBy: 'item_id ASC, page_number ASC',
        limit: 40,
      );

      final matchedDocIds = <String>{};
      for (final row in pageRows) {
        final itemId = row['item_id'] as String;
        final doc = docMap[itemId];
        if (doc == null) continue;
        // Show up to 2 best page hits per document so one large book doesn't flood results
        final existingForDoc =
            results.where((r) => r.item.id == itemId).length;
        if (existingForDoc >= 2) continue;

        matchedDocIds.add(itemId);
        final pageNumber = row['page_number'] as int;
        final pageText = row['content'] as String;
        results.add(
          SearchResult(
            item: doc,
            breadcrumb: breadcrumbFor(doc),
            snippet: _extractSnippet(pageText, query),
            matchedPageNumber: pageNumber,
          ),
        );
      }

      // Fallback to title or extracted_text match if no page hit already recorded
      for (final doc in docItems) {
        if (matchedDocIds.contains(doc.id)) continue;
        final titleHit = doc.title.toLowerCase().contains(qLower);
        final textHit = doc.extractedText.toLowerCase().contains(qLower);
        if (titleHit || textHit) {
          results.add(
            SearchResult(
              item: doc,
              breadcrumb: breadcrumbFor(doc),
              snippet: textHit
                  ? _extractSnippet(doc.extractedText, query)
                  : 'Coincidencia en título del documento',
              matchedPageNumber: 1,
            ),
          );
        }
      }
    }

    return results;
  }

  static String _extractSnippet(String source, String query) {
    final cleaned = source.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return '';
    final idx = cleaned.toLowerCase().indexOf(query.toLowerCase());
    if (idx < 0) return _previewText(cleaned);
    final start = (idx - 48).clamp(0, cleaned.length);
    final end = (idx + query.length + 72).clamp(0, cleaned.length);
    final prefix = start > 0 ? '...' : '';
    final suffix = end < cleaned.length ? '...' : '';
    return '$prefix${cleaned.substring(start, end)}$suffix';
  }

  static String _previewText(String source) {
    final cleaned = source
        .replaceAll(RegExp(r'```[\s\S]*?```'), '[código]')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length <= 110) return cleaned;
    return '${cleaned.substring(0, 110)}...';
  }
}
