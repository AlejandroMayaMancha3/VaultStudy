import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/database/vault_seeder.dart';
import '../../../core/storage/vault_storage_service.dart';
import '../../cloud_sync/application/cloud_sync_service.dart';
import '../data/vault_repository.dart';
import '../domain/vault_item.dart';

const _uuid = Uuid();

final vaultRepositoryProvider = Provider<VaultRepository>((ref) {
  return VaultRepository();
});

/// Holds and mutates the full list of hierarchical `VaultItem`s from SQLite.
class VaultItemsNotifier extends AsyncNotifier<List<VaultItem>> {
  @override
  Future<List<VaultItem>> build() async {
    final db = await DatabaseHelper.instance.database;
    await VaultSeeder.seedIfEmpty(db);
    return ref
        .read(vaultRepositoryProvider)
        .getAllItems(includeExtractedText: false);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final db = await DatabaseHelper.instance.database;
      await VaultSeeder.seedIfEmpty(db);
      return ref
          .read(vaultRepositoryProvider)
          .getAllItems(includeExtractedText: false);
    });
  }

  void _scheduleCloudSync() {
    ref.read(cloudSyncProvider.notifier).scheduleAutoSync();
  }

  Future<VaultItem> createFolder({
    required String title,
    String? parentId,
  }) async {
    final current = state.value ?? [];
    final siblingsCount =
        current.where((e) => e.parentId == parentId).length;
    final item = VaultItem(
      id: _uuid.v4(),
      parentId: parentId,
      title: title.trim(),
      type: VaultItemType.folder,
      sortOrder: siblingsCount,
      updatedAt: DateTime.now(),
    );
    await ref.read(vaultRepositoryProvider).insertItem(item);
    await refresh();
    _scheduleCloudSync();
    return item;
  }

  Future<VaultItem> createNote({
    required String title,
    String? parentId,
    String initialContent = '',
  }) async {
    final current = state.value ?? [];
    final siblingsCount =
        current.where((e) => e.parentId == parentId).length;
    final item = VaultItem(
      id: _uuid.v4(),
      parentId: parentId,
      title: title.trim(),
      type: VaultItemType.note,
      contentMd: initialContent.isNotEmpty
          ? initialContent
          : '## ${title.trim()}\n\nEscribe tus apuntes aquí.\n\n```sql\n-- Tu código aquí\n```\n',
      sortOrder: siblingsCount,
      updatedAt: DateTime.now(),
    );
    await ref.read(vaultRepositoryProvider).insertItem(item);
    await refresh();
    _scheduleCloudSync();
    return item;
  }

  Future<VaultItem> importPdf({
    required String sourcePath,
    required String title,
    required VaultItemType type,
    String? parentId,
  }) async {
    final current = state.value ?? [];
    final siblingsCount =
        current.where((e) => e.parentId == parentId).length;
    final id = _uuid.v4();
    final imported = await VaultStorageService.instance.importPdfFile(
      itemId: id,
      sourceFilePath: sourcePath,
    );

    final item = VaultItem(
      id: id,
      parentId: parentId,
      title: title.trim(),
      type: type.isDocument ? type : VaultItemType.pdf,
      filePath: imported.relativePath,
      fileSize: imported.fileSize,
      extractedText: imported.extractedText,
      sortOrder: siblingsCount,
      updatedAt: DateTime.now(),
    );

    await ref
        .read(vaultRepositoryProvider)
        .insertPdfWithPages(item, imported.pages);
    await refresh();
    _scheduleCloudSync();
    return item;
  }

  /// Batch-imports files (PDFs, `.md`, `.txt`, and source code) and dropped
  /// directories recursively (up to depth 4 and 200 files), preserving folder
  /// hierarchy inside [parentId] and refreshing once at the end.
  Future<List<VaultItem>> importExternalEntries({
    required List<String> paths,
    VaultItemType pdfType = VaultItemType.pdf,
    String? parentId,
    void Function(int processed, int total, String label)? onProgress,
  }) async {
    final repo = ref.read(vaultRepositoryProvider);
    final existing = state.value ?? await repo.getAllItems();
    var rootSiblings = existing.where((e) => e.parentId == parentId).length;

    final folderQueue = <({String dirPath, String? targetParentId, int depth})>[];
    final fileQueue = <({String filePath, String? targetParentId})>[];

    for (final rawPath in paths) {
      if (rawPath.trim().isEmpty) continue;
      final type = FileSystemEntity.typeSync(rawPath);
      if (type == FileSystemEntityType.directory) {
        folderQueue.add((dirPath: rawPath, targetParentId: parentId, depth: 0));
      } else if (type == FileSystemEntityType.file &&
          VaultStorageService.isSupportedImportFile(rawPath)) {
        fileQueue.add((filePath: rawPath, targetParentId: parentId));
      }
    }

    const maxBatchFiles = 200;
    final createdFolders = <VaultItem>[];
    final createdFiles = <VaultItem>[];

    // Expand dropped directories first, creating matching vault folders.
    while (folderQueue.isNotEmpty && fileQueue.length < maxBatchFiles) {
      final current = folderQueue.removeAt(0);
      final dir = Directory(current.dirPath);
      final dirName = p.basename(current.dirPath);
      if (dirName.isEmpty || dirName.startsWith('.')) continue;

      final folderId = _uuid.v4();
      final folderItem = VaultItem(
        id: folderId,
        parentId: current.targetParentId,
        title: dirName,
        type: VaultItemType.folder,
        sortOrder: current.targetParentId == parentId
            ? rootSiblings++
            : createdFolders
                .where((f) => f.parentId == current.targetParentId)
                .length,
        updatedAt: DateTime.now(),
      );
      await repo.insertItem(folderItem);
      createdFolders.add(folderItem);

      if (current.depth >= 4) continue;
      await for (final entity in dir.list(followLinks: false)) {
        if (fileQueue.length >= maxBatchFiles) break;
        final name = p.basename(entity.path);
        if (name.startsWith('.') || name == 'node_modules' || name == 'build') {
          continue;
        }
        if (entity is Directory) {
          folderQueue.add((
            dirPath: entity.path,
            targetParentId: folderId,
            depth: current.depth + 1,
          ));
        } else if (entity is File &&
            VaultStorageService.isSupportedImportFile(entity.path)) {
          fileQueue.add((filePath: entity.path, targetParentId: folderId));
        }
      }
    }

    final total = fileQueue.length;
    for (var i = 0; i < fileQueue.length; i++) {
      final entry = fileQueue[i];
      final fileName = p.basename(entry.filePath);
      onProgress?.call(i + 1, total, fileName);

      if (VaultStorageService.isPdfExtension(entry.filePath)) {
        final id = _uuid.v4();
        final imported = await VaultStorageService.instance.importPdfFile(
          itemId: id,
          sourceFilePath: entry.filePath,
        );
        final item = VaultItem(
          id: id,
          parentId: entry.targetParentId,
          title: fileName,
          type: pdfType.isDocument ? pdfType : VaultItemType.pdf,
          filePath: imported.relativePath,
          fileSize: imported.fileSize,
          extractedText: imported.extractedText,
          sortOrder: i,
          updatedAt: DateTime.now(),
        );
        await repo.insertPdfWithPages(item, imported.pages);
        createdFiles.add(item);
      } else if (VaultStorageService.isNoteOrCodeExtension(entry.filePath)) {
        final bytes = await File(entry.filePath).readAsBytes();
        final rawText = utf8.decode(bytes, allowMalformed: true);
        final mdContent =
            VaultStorageService.instance.formatImportedTextAsMarkdown(
          filePath: entry.filePath,
          rawText: rawText,
        );
        final noteTitle = p.extension(fileName).toLowerCase() == '.md' ||
                p.extension(fileName).toLowerCase() == '.markdown'
            ? p.basenameWithoutExtension(fileName)
            : fileName;
        final item = VaultItem(
          id: _uuid.v4(),
          parentId: entry.targetParentId,
          title: noteTitle.trim().isEmpty ? 'Nota importada' : noteTitle.trim(),
          type: VaultItemType.note,
          contentMd: mdContent,
          sortOrder: i,
          updatedAt: DateTime.now(),
        );
        await repo.insertItem(item);
        createdFiles.add(item);
      }
    }

    if (createdFolders.isNotEmpty || createdFiles.isNotEmpty) {
      await refresh();
      _scheduleCloudSync();
    }
    return [...createdFiles, ...createdFolders];
  }

  Future<void> renameItem(String id, String newTitle) async {
    await ref.read(vaultRepositoryProvider).renameItem(id, newTitle);
    await refresh();
    _scheduleCloudSync();
  }

  Future<void> updateNoteContent({
    required String id,
    required String title,
    required String contentMd,
  }) async {
    await ref.read(vaultRepositoryProvider).updateNoteContent(
          id: id,
          title: title,
          contentMd: contentMd,
        );
    final list = state.value;
    if (list != null) {
      state = AsyncData([
        for (final item in list)
          if (item.id == id)
            item.copyWith(
              title: title.trim().isEmpty ? 'Nota sin título' : title.trim(),
              contentMd: contentMd,
              updatedAt: DateTime.now(),
            )
          else
            item,
      ]);
    }
    _scheduleCloudSync();
  }

  Future<void> togglePin(String id, bool isPinned) async {
    await ref.read(vaultRepositoryProvider).togglePin(id, isPinned);
    await refresh();
    _scheduleCloudSync();
  }

  Future<void> toggleDocumentType(String id, VaultItemType newType) async {
    await ref.read(vaultRepositoryProvider).updateDocumentType(id, newType);
    await refresh();
    _scheduleCloudSync();
  }

  Future<void> moveItem(String id, String? newParentId) async {
    await ref.read(vaultRepositoryProvider).moveItem(id, newParentId);
    await refresh();
    _scheduleCloudSync();
  }

  Future<void> reorderSibling(String id, int delta) async {
    await ref.read(vaultRepositoryProvider).reorderSibling(id, delta);
    await refresh();
    _scheduleCloudSync();
  }

  Future<void> deleteItem(String id) async {
    await ref.read(vaultRepositoryProvider).deleteItem(id);
    await refresh();
    _scheduleCloudSync();
  }

  Future<void> resetDemoData() async {
    await DatabaseHelper.instance.setSkipSeedAfterSignOut(false);
    final db = await DatabaseHelper.instance.database;
    await db.delete('sync_tombstones');
    await db.delete('items');
    await VaultSeeder.seedForce(db);
    await refresh();
    _scheduleCloudSync();
  }
}

final vaultItemsProvider =
    AsyncNotifierProvider<VaultItemsNotifier, List<VaultItem>>(
  VaultItemsNotifier.new,
);

/// Pinned documents & notes for quick exam access.
final pinnedItemsProvider = Provider<List<VaultItem>>((ref) {
  final items = ref.watch(vaultItemsProvider).value ?? [];
  return items
      .where((e) => e.isPinned && e.type != VaultItemType.folder)
      .toList();
});

/// Recent non-folder items sorted by `updatedAt` descending.
final recentItemsProvider = Provider<List<VaultItem>>((ref) {
  final items = ref.watch(vaultItemsProvider).value ?? [];
  final files = items.where((e) => e.type != VaultItemType.folder).toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return files;
});

/// Annotations for a specific PDF/Book item ID.
final pdfAnnotationsProvider =
    FutureProvider.family<List<PdfAnnotation>, String>((ref, itemId) async {
  return ref.read(vaultRepositoryProvider).getAnnotations(itemId);
});

/// Exam Read-Only Mode toggle (prevents accidental edits during exams).
class ExamReadOnlyNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    return DatabaseHelper.instance.getExamReadOnlyMode();
  }

  Future<void> setEnabled(bool enabled) async {
    await DatabaseHelper.instance.setExamReadOnlyMode(enabled);
    state = AsyncData(enabled);
  }
}

final examReadOnlyProvider =
    AsyncNotifierProvider<ExamReadOnlyNotifier, bool>(ExamReadOnlyNotifier.new);

/// Helper to build `Asignatura > Tema` path string for any item.
String buildBreadcrumbPath(List<VaultItem> allItems, VaultItem item) {
  final byId = {for (final i in allItems) i.id: i};
  final segments = <String>[];
  String? cursor = item.parentId;
  while (cursor != null) {
    final parent = byId[cursor];
    if (parent == null) break;
    segments.insert(0, parent.title);
    cursor = parent.parentId;
  }
  return segments.join(' / ');
}
