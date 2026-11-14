import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:uuid/uuid.dart';

import '../../features/vault_tree/domain/vault_item.dart';
import '../database/database_helper.dart';

class ImportedPdfResult {
  const ImportedPdfResult({
    required this.relativePath,
    required this.fileSize,
    required this.extractedText,
    required this.pages,
  });

  final String relativePath;
  final int fileSize;
  final String extractedText;
  final List<PdfPageEntry> pages;
}

/// Handles copying PDFs into `vault_files/`, extracting per-page text offline,
/// and exporting/importing portable `.vaultpkg` bundles for exam computers.
class VaultStorageService {
  VaultStorageService._();

  static final VaultStorageService instance = VaultStorageService._();
  static const _uuid = Uuid();

  static const Set<String> imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
  };

  static const Set<String> noteTextExtensions = {
    'md',
    'markdown',
    'txt',
  };

  static const Map<String, String> codeExtensionsToLanguage = {
    'sql': 'sql',
    'py': 'python',
    'java': 'java',
    'c': 'c',
    'cpp': 'cpp',
    'cc': 'cpp',
    'h': 'c',
    'hpp': 'cpp',
    'dart': 'dart',
    'js': 'javascript',
    'ts': 'typescript',
    'jsx': 'javascript',
    'tsx': 'typescript',
    'html': 'html',
    'htm': 'html',
    'php': 'php',
    'phtml': 'php',
    'css': 'css',
    'json': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
    'sh': 'bash',
    'bash': 'bash',
    'xml': 'xml',
    'cs': 'csharp',
    'kt': 'kotlin',
    'ps1': 'powershell',
    'go': 'go',
    'rs': 'rust',
  };

  static bool isPdfExtension(String filePath) =>
      p.extension(filePath).toLowerCase() == '.pdf';

  static bool isImageExtension(String filePath) {
    final ext = p.extension(filePath).toLowerCase().replaceFirst('.', '');
    return imageExtensions.contains(ext);
  }

  static bool isNoteOrCodeExtension(String filePath) {
    final ext = p.extension(filePath).toLowerCase().replaceFirst('.', '');
    return noteTextExtensions.contains(ext) ||
        codeExtensionsToLanguage.containsKey(ext);
  }

  static bool isSupportedImportFile(String filePath) =>
      isPdfExtension(filePath) || isNoteOrCodeExtension(filePath);

  /// Formats an imported `.md`, `.txt`, or source-code file into VaultStudy Markdown.
  String formatImportedTextAsMarkdown({
    required String filePath,
    required String rawText,
  }) {
    final ext = p.extension(filePath).toLowerCase().replaceFirst('.', '');
    final normalizedText = rawText.replaceAll('\r\n', '\n').trimRight();
    if (ext == 'md' || ext == 'markdown') {
      return normalizedText;
    }
    final lang = codeExtensionsToLanguage[ext];
    final baseName = p.basename(filePath);
    final title = p.basenameWithoutExtension(filePath);
    if (lang != null) {
      final commentPrefix =
          (lang == 'python' || lang == 'bash' || lang == 'yaml' || lang == 'powershell')
              ? '#'
              : (lang == 'sql'
                  ? '--'
                  : (lang == 'html' || lang == 'xml' ? '' : '//'));
      final header = commentPrefix.isEmpty
          ? ''
          : '$commentPrefix file: $baseName\n';
      return '## $title\n\n```$lang\n$header$normalizedText\n```\n';
    }
    return '## $title\n\n$normalizedText\n';
  }

  /// Copies a local image into `vault_files/` and returns a portable relative path.
  Future<String> importImageFile({required String sourceFilePath}) async {
    final sourceFile = File(sourceFilePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('Imagen no encontrada', sourceFilePath);
    }
    final filesDir = await DatabaseHelper.instance.getVaultFilesDir();
    final originalName = p.basename(sourceFilePath);
    final sanitizedName =
        originalName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final targetFileName = 'img_${_uuid.v4().substring(0, 8)}_$sanitizedName';
    final targetFullPath = p.join(filesDir, targetFileName);
    await sourceFile.copy(targetFullPath);
    return p
        .join(DatabaseHelper.vaultFilesFolderName, targetFileName)
        .replaceAll('\\', '/');
  }

  /// Copies [sourceFilePath] into `vault_files/` and extracts text from all pages.
  Future<ImportedPdfResult> importPdfFile({
    required String itemId,
    required String sourceFilePath,
  }) async {
    final sourceFile = File(sourceFilePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('Archivo PDF no encontrado', sourceFilePath);
    }

    final filesDir = await DatabaseHelper.instance.getVaultFilesDir();
    final originalName = p.basename(sourceFilePath);
    final sanitizedName = originalName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final targetFileName = '${_uuid.v4().substring(0, 8)}_$sanitizedName';
    final targetFullPath = p.join(filesDir, targetFileName);

    await sourceFile.copy(targetFullPath);
    final fileSize = await File(targetFullPath).length();
    final relativePath = p.join(
      DatabaseHelper.vaultFilesFolderName,
      targetFileName,
    );

    final extraction = await extractTextAndPagesFromFile(
      itemId: itemId,
      fullPath: targetFullPath,
    );

    return ImportedPdfResult(
      relativePath: relativePath,
      fileSize: fileSize,
      extractedText: extraction.fullText,
      pages: extraction.pages,
    );
  }

  /// Extracts per-page text and concatenated full text from a local PDF file.
  Future<({String fullText, List<PdfPageEntry> pages})>
      extractTextAndPagesFromFile({
    required String itemId,
    required String fullPath,
  }) async {
    final pages = <PdfPageEntry>[];
    final fullTextBuf = StringBuffer();

    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(fullPath);
      for (var i = 0; i < doc.pages.length; i++) {
        final page = doc.pages[i];
        final rawText = await page.loadText();
        final pageText = (rawText?.fullText ?? '').trim();
        pages.add(
          PdfPageEntry(
            itemId: itemId,
            pageNumber: page.pageNumber,
            content: pageText,
          ),
        );
        if (pageText.isNotEmpty) {
          fullTextBuf.writeln(pageText);
        }
      }
    } catch (_) {
      // Keep PDF imported even if text extraction fails on scanned PDFs.
    } finally {
      await doc?.dispose();
    }

    return (fullText: fullTextBuf.toString().trim(), pages: pages);
  }

  Future<void> deleteStoredFile(String? storedPath) async {
    if (storedPath == null || storedPath.isEmpty) return;
    final resolved = await DatabaseHelper.instance.resolveVaultFilePath(storedPath);
    final file = File(resolved);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Builds a portable `.vaultpkg` ZIP archive bytes in memory (`vault_study.db` + `vault_files/`).
  Future<Uint8List> buildVaultPackageBytes() async {
    final db = await DatabaseHelper.instance.database;
    // Flush WAL if any before copying DB
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');

    final rootDir = await DatabaseHelper.instance.getVaultRootDir();
    final dbPath = await DatabaseHelper.instance.getDatabasePath();
    final filesDir = Directory(await DatabaseHelper.instance.getVaultFilesDir());

    final archive = Archive();

    final dbBytes = await File(dbPath).readAsBytes();
    archive.addFile(
      ArchiveFile(DatabaseHelper.dbFileName, dbBytes.length, dbBytes),
    );

    if (await filesDir.exists()) {
      await for (final entity in filesDir.list(recursive: true)) {
        if (entity is File) {
          final relPath =
              p.relative(entity.path, from: rootDir).replaceAll('\\', '/');
          final bytes = await entity.readAsBytes();
          archive.addFile(ArchiveFile(relPath, bytes.length, bytes));
        }
      }
    }

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Exports the entire vault (`vault_study.db` + `vault_files/`) to [outputPath].
  Future<File> exportVaultPackage(String outputPath) async {
    final encoded = await buildVaultPackageBytes();
    final outFile = File(outputPath);
    await outFile.writeAsBytes(encoded, flush: true);
    return outFile;
  }

  /// Imports a portable `.vaultpkg` / `.zip` archive, replacing current vault contents.
  Future<void> importVaultPackage(String packagePath) async {
    final pkgFile = File(packagePath);
    if (!await pkgFile.exists()) {
      throw FileSystemException('Paquete no encontrado', packagePath);
    }

    final bytes = await pkgFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final hasDb = archive.any((f) => f.name == DatabaseHelper.dbFileName);
    if (!hasDb) {
      throw const FormatException(
        'El paquete seleccionado no contiene una base de datos VaultStudy válida.',
      );
    }

    await DatabaseHelper.instance.close();

    final rootDir = await DatabaseHelper.instance.getVaultRootDir();
    final filesDir = Directory(await DatabaseHelper.instance.getVaultFilesDir());
    if (await filesDir.exists()) {
      await filesDir.delete(recursive: true);
    }
    await filesDir.create(recursive: true);

    const maxEntries = 5000;
    const maxTotalUncompressedBytes = 500 * 1024 * 1024; // 500 MB
    if (archive.length > maxEntries) {
      throw const FormatException(
        'El paquete supera el número máximo de archivos permitido.',
      );
    }

    final canonicalRoot = p.canonicalize(rootDir);
    final canonicalFilesDir = p.canonicalize(filesDir.path);
    final canonicalDbDest = p.canonicalize(
      p.join(canonicalRoot, DatabaseHelper.dbFileName),
    );
    var totalExtractedBytes = 0;

    for (final file in archive) {
      if (!file.isFile) continue;
      final normalized = p.normalize(file.name.replaceAll('\\', '/'));
      if (normalized.isEmpty ||
          normalized.startsWith('..') ||
          p.isAbsolute(normalized)) {
        continue;
      }

      final destPath = p.join(canonicalRoot, normalized);
      final canonicalDest = p.canonicalize(destPath);
      if (!p.isWithin(canonicalRoot, canonicalDest)) {
        continue;
      }

      final isDbFile = canonicalDest == canonicalDbDest;
      final isInsideFilesDir = p.isWithin(canonicalFilesDir, canonicalDest);
      if (!isDbFile && !isInsideFilesDir) {
        continue;
      }

      final content = file.content as List<int>;
      totalExtractedBytes += content.length;
      if (totalExtractedBytes > maxTotalUncompressedBytes) {
        throw const FormatException(
          'El paquete supera el tamaño máximo permitido al descomprimir.',
        );
      }

      final destFile = File(canonicalDest);
      await destFile.parent.create(recursive: true);
      await destFile.writeAsBytes(content, flush: true);
    }

    // Reopen DB immediately to verify integrity.
    await DatabaseHelper.instance.database;
  }
}
