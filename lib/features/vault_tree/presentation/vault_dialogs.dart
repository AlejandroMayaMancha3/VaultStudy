import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_breakpoints.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/storage/vault_storage_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/type_badge.dart';
import '../../cloud_sync/application/cloud_sync_service.dart';
import '../application/vault_providers.dart';
import '../domain/vault_item.dart';

/// Shared VaultStudy dialogs for CRUD, PDF import, moving, and portable backup.
abstract final class VaultDialogs {
  static Future<VaultItem?> showCreateFolderDialog(
    BuildContext context,
    WidgetRef ref, {
    String? parentId,
    String? parentTitle,
  }) async {
    final controller = TextEditingController();
    final isRoot = parentId == null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isRoot ? 'Nueva Asignatura' : 'Nueva Carpeta en "$parentTitle"',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: isRoot ? 'Nombre de la asignatura' : 'Nombre del tema/carpeta',
            hintText: isRoot ? 'Ej. Sistemas Operativos' : 'Ej. Tema 3: Concurrencia',
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Crear'),
          ),
        ],
      ),
    );

    final title = controller.text.trim();
    controller.dispose();
    if (confirmed != true || title.isEmpty) return null;

    return ref.read(vaultItemsProvider.notifier).createFolder(
          title: title,
          parentId: parentId,
        );
  }

  static Future<VaultItem?> showCreateNoteDialog(
    BuildContext context,
    WidgetRef ref, {
    String? parentId,
    String? parentTitle,
  }) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          parentTitle != null
              ? 'Nueva Nota en "$parentTitle"'
              : 'Nueva Nota de Estudio',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Título de la nota',
            hintText: 'Ej. Apuntes Transacciones ACID',
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Crear Nota'),
          ),
        ],
      ),
    );

    final title = controller.text.trim();
    controller.dispose();
    if (confirmed != true || title.isEmpty) return null;

    return ref.read(vaultItemsProvider.notifier).createNote(
          title: title,
          parentId: parentId,
        );
  }

  static Future<VaultItem?> showImportPdfDialog(
    BuildContext context,
    WidgetRef ref, {
    String? parentId,
  }) async {
    final created = await showImportFilesDialog(
      context,
      ref,
      parentId: parentId,
    );
    return created.isNotEmpty ? created.first : null;
  }

  /// Opens a multi-file picker supporting PDFs, Markdown, plain text, and source code.
  static Future<List<VaultItem>> showImportFilesDialog(
    BuildContext context,
    WidgetRef ref, {
    String? parentId,
  }) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'md',
        'markdown',
        'txt',
        'sql',
        'py',
        'java',
        'c',
        'cpp',
        'h',
        'hpp',
        'dart',
        'js',
        'jsx',
        'ts',
        'tsx',
        'json',
        'yaml',
        'yml',
        'xml',
        'html',
        'htm',
        'php',
        'phtml',
        'css',
        'sh',
        'ps1',
        'cs',
        'go',
        'rs',
        'kt',
      ],
      dialogTitle: 'Importar archivos (PDF, Markdown, Texto o Código)',
    );
    final paths = picked
        .map((f) => f.path)
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toList();
    if (paths.isEmpty || !context.mounted) return const [];
    return confirmAndRunBatchImport(
      context,
      ref,
      paths: paths,
      parentId: parentId,
    );
  }

  /// Opens a folder picker and recursively imports supported study files preserving hierarchy.
  static Future<List<VaultItem>> showImportDirectoryDialog(
    BuildContext context,
    WidgetRef ref, {
    String? parentId,
  }) async {
    final dirPath = await FilePicker.getDirectoryPath(
      dialogTitle: 'Importar carpeta completa a la bóveda',
    );
    if (dirPath == null || dirPath.isEmpty || !context.mounted) {
      return const [];
    }
    return confirmAndRunBatchImport(
      context,
      ref,
      paths: [dirPath],
      parentId: parentId,
    );
  }

  /// Confirms and imports one or more external files/folders into the vault.
  static Future<List<VaultItem>> confirmAndRunBatchImport(
    BuildContext context,
    WidgetRef ref, {
    required List<String> paths,
    String? parentId,
    bool skipConfirmIfSingleUnsupported = false,
  }) async {
    if (paths.isEmpty) return const [];

    // Single PDF fast-path with full rename + classification options
    if (paths.length == 1 &&
        FileSystemEntity.isFileSync(paths.first) &&
        VaultStorageService.isPdfExtension(paths.first)) {
      final item = await _showSinglePdfImportDialog(
        context,
        ref,
        filePath: paths.first,
        parentId: parentId,
      );
      return item != null ? [item] : const [];
    }

    final hasAnyDirectory = paths.any((path) => Directory(path).existsSync());
    final supportedFiles = paths
        .where(
          (path) =>
              Directory(path).existsSync() ||
              VaultStorageService.isSupportedImportFile(path),
        )
        .toList();

    if (supportedFiles.isEmpty) {
      if (!skipConfirmIfSingleUnsupported && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Formato no compatible. Usa PDF, Markdown (.md), texto (.txt) o código fuente.',
            ),
          ),
        );
      }
      return const [];
    }

    var selectedPdfType = VaultItemType.pdf;
    String? chosenParentId = parentId;
    final allItems = ref.read(vaultItemsProvider).value ?? [];
    final folders =
        allItems.where((e) => e.type == VaultItemType.folder).toList();
    if (chosenParentId != null && !folders.any((f) => f.id == chosenParentId)) {
      chosenParentId = null;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(
            hasAnyDirectory
                ? 'Importar carpeta y archivos'
                : 'Importación masiva (${supportedFiles.length} archivo${supportedFiles.length == 1 ? '' : 's'})',
          ),
          content: SizedBox(
            width: 450,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLowest,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.outlineVariant.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final path in supportedFiles.take(6))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Icon(
                                Directory(path).existsSync()
                                    ? Icons.folder_outlined
                                    : VaultStorageService.isPdfExtension(path)
                                        ? Icons.picture_as_pdf_outlined
                                        : Icons.description_outlined,
                                size: 15,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  p.basename(path),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.bodyMd.copyWith(
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (supportedFiles.length > 6)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '... y ${supportedFiles.length - 6} elemento(s) más',
                            style: AppTypography.labelMono.copyWith(
                              fontSize: 11,
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Los archivos .md, .txt y de código se convertirán automáticamente en Apuntes Markdown editables.',
                  style: AppTypography.bodyMd.copyWith(
                    fontSize: 12,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'CLASIFICACIÓN PARA PDFs',
                  style: AppTypography.labelMono.copyWith(
                    color: AppColors.outline,
                    fontSize: 10.5,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _TypeSelectCard(
                        selected: selectedPdfType == VaultItemType.pdf,
                        badge: const TypeBadge(type: VaultItemType.pdf),
                        subtitle: 'Boletín / Apuntes',
                        onTap: () =>
                            setState(() => selectedPdfType = VaultItemType.pdf),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _TypeSelectCard(
                        selected: selectedPdfType == VaultItemType.book,
                        badge: const TypeBadge(type: VaultItemType.book),
                        subtitle: 'Libro de texto',
                        onTap: () => setState(
                          () => selectedPdfType = VaultItemType.book,
                        ),
                      ),
                    ),
                  ],
                ),
                if (folders.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String?>(
                    initialValue: chosenParentId,
                    dropdownColor: AppColors.surfaceHigh,
                    decoration: const InputDecoration(
                      labelText: 'Carpeta destino',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Raíz de Bóveda'),
                      ),
                      for (final f in folders)
                        DropdownMenuItem<String?>(
                          value: f.id,
                          child: Text(
                            buildBreadcrumbPath(allItems, f).isEmpty
                                ? f.title
                                : '${buildBreadcrumbPath(allItems, f)} / ${f.title}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (val) => setState(() => chosenParentId = val),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.file_upload_outlined, size: 17),
              label: const Text('Importar todo'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !context.mounted) return const [];

    final progressNotifier = ValueNotifier<(int, int, String)>(
      (0, supportedFiles.length, 'Preparando importación...'),
    );
    var dialogClosed = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Importando a la bóveda...'),
        content: ValueListenableBuilder<(int, int, String)>(
          valueListenable: progressNotifier,
          builder: (_, state, _) {
            final (done, total, label) = state;
            final value = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
            return SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: value),
                  const SizedBox(height: 10),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMd.copyWith(fontSize: 12.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$done / $total procesado(s)',
                    style: AppTypography.labelMono.copyWith(
                      fontSize: 11,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ).whenComplete(() => dialogClosed = true);

    List<VaultItem> created = const [];
    try {
      created = await ref.read(vaultItemsProvider.notifier).importExternalEntries(
            paths: supportedFiles,
            pdfType: selectedPdfType,
            parentId: chosenParentId,
            onProgress: (processed, total, label) {
              progressNotifier.value = (processed, total, label);
            },
          );
    } finally {
      progressNotifier.dispose();
      if (!dialogClosed && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created.isEmpty
                ? 'No se encontró ningún archivo compatible para importar.'
                : '${created.length} elemento${created.length == 1 ? '' : 's'} importado${created.length == 1 ? '' : 's'} a la bóveda.',
          ),
        ),
      );
    }
    return created;
  }

  static Future<VaultItem?> _showSinglePdfImportDialog(
    BuildContext context,
    WidgetRef ref, {
    required String filePath,
    String? parentId,
  }) async {
    final titleController = TextEditingController(
      text: p.basename(filePath),
    );
    var selectedType = VaultItemType.pdf;
    String? chosenParentId = parentId;

    final allItems = ref.read(vaultItemsProvider).value ?? [];
    final folders =
        allItems.where((e) => e.type == VaultItemType.folder).toList();
    if (chosenParentId != null && !folders.any((f) => f.id == chosenParentId)) {
      chosenParentId = null;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Importar Documento a Bóveda'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'Nombre en la bóveda',
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'CLASIFICACIÓN',
                  style: AppTypography.labelMono.copyWith(
                    color: AppColors.outline,
                    fontSize: 10.5,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _TypeSelectCard(
                        selected: selectedType == VaultItemType.pdf,
                        badge: const TypeBadge(type: VaultItemType.pdf),
                        subtitle: 'Boletín / Apuntes',
                        onTap: () =>
                            setState(() => selectedType = VaultItemType.pdf),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _TypeSelectCard(
                        selected: selectedType == VaultItemType.book,
                        badge: const TypeBadge(type: VaultItemType.book),
                        subtitle: 'Libro de texto',
                        onTap: () =>
                            setState(() => selectedType = VaultItemType.book),
                      ),
                    ),
                  ],
                ),
                if (folders.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String?>(
                    initialValue: chosenParentId,
                    dropdownColor: AppColors.surfaceHigh,
                    decoration: const InputDecoration(
                      labelText: 'Carpeta destino',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Raíz de Bóveda'),
                      ),
                      for (final f in folders)
                        DropdownMenuItem<String?>(
                          value: f.id,
                          child: Text(
                            buildBreadcrumbPath(allItems, f).isEmpty
                                ? f.title
                                : '${buildBreadcrumbPath(allItems, f)} / ${f.title}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (val) => setState(() => chosenParentId = val),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Importar e Indexar'),
            ),
          ],
        ),
      ),
    );

    final title = titleController.text.trim();
    titleController.dispose();
    if (confirmed != true || title.isEmpty) return null;

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copiando PDF e indexando texto offline...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    return ref.read(vaultItemsProvider.notifier).importPdf(
          sourcePath: filePath,
          title: title,
          type: selectedType,
          parentId: chosenParentId,
        );
  }

  static Future<void> showRenameDialog(
    BuildContext context,
    WidgetRef ref,
    VaultItem item,
  ) async {
    final controller = TextEditingController(text: item.title);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renombrar elemento'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nuevo nombre'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    final nextTitle = controller.text.trim();
    controller.dispose();
    if (confirmed == true && nextTitle.isNotEmpty) {
      await ref
          .read(vaultItemsProvider.notifier)
          .renameItem(item.id, nextTitle);
    }
  }

  static Future<void> showMoveDialog(
    BuildContext context,
    WidgetRef ref,
    VaultItem item,
  ) async {
    final allItems = ref.read(vaultItemsProvider).value ?? [];
    final folders = allItems
        .where((e) => e.type == VaultItemType.folder && e.id != item.id)
        .toList();

    String? selectedParent = item.parentId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Mover "${item.title}"'),
          content: SizedBox(
            width: 380,
            child: DropdownButtonFormField<String?>(
              initialValue: selectedParent,
              dropdownColor: AppColors.surfaceHigh,
              decoration: const InputDecoration(labelText: 'Carpeta destino'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Raíz de Bóveda'),
                ),
                for (final f in folders)
                  DropdownMenuItem<String?>(
                    value: f.id,
                    child: Text(
                      buildBreadcrumbPath(allItems, f).isEmpty
                          ? f.title
                          : '${buildBreadcrumbPath(allItems, f)} / ${f.title}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => selectedParent = v),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mover'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await ref
            .read(vaultItemsProvider.notifier)
            .moveItem(item.id, selectedParent);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString())),
          );
        }
      }
    }
  }

  static Future<bool> showDeleteConfirmDialog(
    BuildContext context,
    WidgetRef ref,
    VaultItem item,
  ) async {
    final isFolder = item.type == VaultItemType.folder;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar de la bóveda'),
        content: Text(
          isFolder
              ? '¿Eliminar "${item.title}" y todo su contenido (subcarpetas, notas y PDFs)? Esta acción no se puede deshacer.'
              : '¿Eliminar "${item.title}" de la bóveda local?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(vaultItemsProvider.notifier).deleteItem(item.id);
      return true;
    }
    return false;
  }

  static Future<void> showVaultSettingsDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => const _VaultSettingsDialog(),
    );
  }

  /// Displays 3 consecutive mandatory confirmation warnings before signing out
  /// and wiping all local vault database rows, PDFs, notes, and highlights.
  static Future<bool> confirmThreeStepSignOut(
    BuildContext context, {
    int pendingCount = 0,
  }) async {
    final pendingNote = pendingCount > 0
        ? '\n\n¡ATENCIÓN! Tienes $pendingCount cambios offline pendientes de sincronizar que se perderán para siempre si no sincronizas antes.'
        : '';

    final step1 = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.bookAmber),
            SizedBox(width: 8),
            Expanded(child: Text('Advertencia 1 de 3: Cerrar sesión')),
          ],
        ),
        content: Text(
          'Al cerrar sesión se desconectará tu cuenta y se BORRARÁN TODOS tus apuntes, carpetas, libros, PDFs y subrayados guardados localmente en este equipo.$pendingNote\n\nPodrás volver a descargarlos iniciando sesión de nuevo más adelante.',
          style: AppTypography.bodyMd,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.bookAmber,
              foregroundColor: AppColors.surfaceLowest,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continuar (1/3)'),
          ),
        ],
      ),
    );
    if (step1 != true || !context.mounted) return false;

    final step2 = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete_sweep_outlined, color: AppColors.error),
            SizedBox(width: 8),
            Expanded(
              child: Text('Advertencia 2 de 3: Borrado local completo'),
            ),
          ],
        ),
        content: const Text(
          'Se eliminará por completo la base de datos local (vault_study.db), toda la carpeta vault_files/ con tus PDFs offline y tus pestañas abiertas.\n\nSi este PC es un ordenador de clase para un examen y aún necesitas tus archivos sin internet, NO continúes.',
          style: AppTypography.bodyMd,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sí, entiendo el borrado (2/3)'),
          ),
        ],
      ),
    );
    if (step2 != true || !context.mounted) return false;

    final step3 = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.gpp_bad_outlined, color: AppColors.error),
            SizedBox(width: 8),
            Expanded(
              child: Text('Advertencia 3 de 3: Confirmación definitiva'),
            ),
          ],
        ),
        content: const Text(
          'Último aviso: ¿confirmas definitivamente cerrar tu sesión en la nube y vaciar toda la bóveda local ahora mismo?',
          style: AppTypography.bodyMd,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('BORRAR TODO Y CERRAR SESIÓN'),
          ),
        ],
      ),
    );

    return step3 == true;
  }
}

class _TypeSelectCard extends StatelessWidget {
  const _TypeSelectCard({
    required this.selected,
    required this.badge,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final Widget badge;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.surfaceHigh
              : AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            badge,
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: AppTypography.bodySm.copyWith(color: AppColors.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

class _VaultSettingsDialog extends ConsumerStatefulWidget {
  const _VaultSettingsDialog();

  @override
  ConsumerState<_VaultSettingsDialog> createState() =>
      _VaultSettingsDialogState();
}

class _VaultSettingsDialogState extends ConsumerState<_VaultSettingsDialog> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isCreateAccount = false;
  bool _obscurePassword = true;
  String? _localFormError;

  String _vaultDir = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadPath();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadPath() async {
    try {
      final dir = await DatabaseHelper.instance.getVaultRootDir();
      if (mounted) setState(() => _vaultDir = dir);
    } catch (_) {
      if (mounted) setState(() => _vaultDir = 'Ruta local por defecto');
    }
  }

  Future<void> _submitCloudAuth() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _localFormError = 'Introduce un correo electrónico válido.');
      return;
    }
    if (_isCreateAccount) {
      final hasLetter = RegExp(r'[A-Za-z]').hasMatch(password);
      final hasDigit = RegExp(r'\d').hasMatch(password);
      if (password.length < 8 || !hasLetter || !hasDigit) {
        setState(
          () => _localFormError =
              'Usa al menos 8 caracteres combinando letras y números.',
        );
        return;
      }
    } else if (password.length < 6) {
      setState(
        () => _localFormError = 'La contraseña debe tener al menos 6 caracteres.',
      );
      return;
    }

    setState(() => _localFormError = null);
    final notifier = ref.read(cloudSyncProvider.notifier);
    final ok = _isCreateAccount
        ? await notifier.signUp(email: email, password: password)
        : await notifier.signIn(email: email, password: password);
    if (ok && mounted) {
      _passwordController.clear();
    }
  }

  Future<void> _handleSignOutWithThreeWarnings(int pendingCount) async {
    final confirmed = await VaultDialogs.confirmThreeStepSignOut(
      context,
      pendingCount: pendingCount,
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(cloudSyncProvider.notifier).signOutAndWipeLocal();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sesión cerrada y bóveda local borrada por seguridad.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportPortable() async {
    final dateTag = DateTime.now().toIso8601String().substring(0, 10);
    setState(() => _busy = true);
    try {
      final bytes = await VaultStorageService.instance.buildVaultPackageBytes();
      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Exportar bóveda portable para examen',
        fileName: 'VaultStudy_$dateTag.vaultpkg',
        bytes: bytes,
      );
      if (savedUri != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Bóveda exportada: ${savedUri.toFilePath(windows: Platform.isWindows)}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al exportar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importPortable() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['vaultpkg', 'zip'],
      dialogTitle: 'Importar paquete portable VaultStudy',
    );
    final path = picked?.path;
    if (path == null) return;

    setState(() => _busy = true);
    try {
      await VaultStorageService.instance.importVaultPackage(path);
      await ref.read(vaultItemsProvider.notifier).refresh();
      ref.read(cloudSyncProvider.notifier).scheduleAutoSync();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bóveda importada correctamente. Lista 100% offline.'),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al importar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickCustomVaultDir() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Elegir carpeta de bóveda (ej. USB o carpeta sincronizada)',
    );
    if (dir == null) return;
    setState(() => _busy = true);
    await DatabaseHelper.instance.setCustomVaultDir(dir);
    await ref.read(vaultItemsProvider.notifier).refresh();
    await _loadPath();
    if (mounted) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ruta de bóveda cambiada a $dir')),
      );
    }
  }

  String _formatSyncTime(DateTime? dt) {
    if (dt == null) return 'Pendiente';
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} $hh:$mm';
  }

  Widget _buildCloudAccountCard(CloudSyncState sync) {
    final busyCloud = _busy || sync.isSyncing;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceLowest,
        borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
        border: Border.all(
          color: sync.isSignedIn
              ? AppColors.primary.withValues(alpha: 0.45)
              : AppColors.secondary.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                sync.isSignedIn
                    ? (sync.isOffline
                        ? Icons.cloud_off_rounded
                        : Icons.cloud_done_outlined)
                    : Icons.cloud_outlined,
                size: 18,
                color: sync.isOffline
                    ? AppColors.bookAmber
                    : (sync.isSignedIn
                        ? AppColors.primary
                        : AppColors.secondary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'CUENTA EN LA NUBE (SUPABASE + OFFLINE)',
                  style: AppTypography.badgeMono.copyWith(
                    color: sync.isSignedIn
                        ? AppColors.primary
                        : AppColors.secondary,
                  ),
                ),
              ),
              if (sync.isSignedIn)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: (sync.isOffline
                            ? AppColors.bookAmber
                            : AppColors.primary)
                        .withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                  ),
                  child: Text(
                    sync.isOffline ? 'OFFLINE' : 'CONECTADA',
                    style: AppTypography.badgeMono.copyWith(
                      color: sync.isOffline
                          ? AppColors.bookAmber
                          : AppColors.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!sync.isSignedIn) ...[
            Text(
              'Inicia sesión para respaldar o descargar tus asignaturas, PDFs y apuntes. Después funciona 100% sin WiFi durante exámenes.',
              style: AppTypography.bodySm,
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: busyCloud
                  ? null
                  : () {
                      setState(() => _localFormError = null);
                      ref.read(cloudSyncProvider.notifier).signInWithGitHub();
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.surfaceLowest,
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              icon: sync.isWaitingOAuth
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.surfaceLowest,
                      ),
                    )
                  : const Icon(Icons.code_rounded, size: 19),
              label: Text(
                sync.isWaitingOAuth
                    ? 'Esperando autorización en GitHub...'
                    : 'Continuar con GitHub',
                style: AppTypography.bodyMd.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.surfaceLowest,
                ),
              ),
            ),
            if (sync.isWaitingOAuth) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () =>
                      ref.read(cloudSyncProvider.notifier).cancelGitHubSignIn(),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Cancelar espera de GitHub'),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'Tip aula de examen: al usar GitHub en un PC compartido, cierra luego tu sesión en Chrome/Edge (o usa correo y contraseña abajo).',
              style: AppTypography.bodySm.copyWith(color: AppColors.outline),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'O CON CORREO Y CONTRASEÑA (RESPALDO)',
                    style: AppTypography.badgeMono.copyWith(
                      color: AppColors.outline,
                    ),
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: const Center(child: Text('Iniciar sesión')),
                    selected: !_isCreateAccount,
                    onSelected: busyCloud
                        ? null
                        : (_) => setState(() {
                              _isCreateAccount = false;
                              _localFormError = null;
                            }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    label: const Center(child: Text('Crear cuenta')),
                    selected: _isCreateAccount,
                    onSelected: busyCloud
                        ? null
                        : (_) => setState(() {
                              _isCreateAccount = true;
                              _localFormError = null;
                            }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _emailController,
              enabled: !busyCloud,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Correo electrónico',
                hintText: 'estudiante@universidad.es',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              enabled: !busyCloud,
              obscureText: _obscurePassword,
              onSubmitted: (_) => _submitCloudAuth(),
              decoration: InputDecoration(
                labelText: 'Contraseña',
                hintText: _isCreateAccount
                    ? 'Mínimo 8 caracteres (letras y números)'
                    : 'Tu contraseña',
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busyCloud ? null : _submitCloudAuth,
              icon: (sync.isSyncing && !sync.isWaitingOAuth)
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _isCreateAccount
                          ? Icons.person_add_alt_1_rounded
                          : Icons.login_rounded,
                      size: 17,
                    ),
              label: Text(
                (sync.isSyncing && !sync.isWaitingOAuth)
                    ? (sync.syncProgressLabel ?? 'Conectando...')
                    : (_isCreateAccount
                        ? 'Crear cuenta con correo'
                        : 'Entrar con correo y descargar'),
              ),
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sync.userEmail ?? 'Cuenta activa',
                        style: AppTypography.bodyMd.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Última sync: ${_formatSyncTime(sync.lastSyncedAt)} • '
                        '${sync.pendingChangesCount > 0 ? '${sync.pendingChangesCount} cambios offline pendientes' : 'Todo al día en la nube'}',
                        style: AppTypography.monoSm.copyWith(
                          color: sync.pendingChangesCount > 0
                              ? AppColors.bookAmber
                              : AppColors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (sync.isSyncing && sync.syncProgressLabel != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sync.syncProgressLabel!,
                      style: AppTypography.monoSm.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: busyCloud
                        ? null
                        : () => ref
                            .read(cloudSyncProvider.notifier)
                            .syncNow(silentIfOffline: false),
                    icon: const Icon(Icons.cloud_sync_outlined, size: 17),
                    label: const Text('Sincronizar ahora'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busyCloud
                        ? null
                        : () => _handleSignOutWithThreeWarnings(
                              sync.pendingChangesCount,
                            ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                      side: BorderSide(
                        color: AppColors.error.withValues(alpha: 0.65),
                      ),
                    ),
                    icon: const Icon(Icons.logout_rounded, size: 17),
                    label: const Text('Cerrar sesión'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Nota de seguridad: cerrar sesión borra los archivos locales de este equipo tras 3 avisos de confirmación.',
              style: AppTypography.bodySm.copyWith(color: AppColors.outline),
            ),
          ],
          if (_localFormError != null || sync.errorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                border: Border.all(
                  color: AppColors.error.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                _localFormError ?? sync.errorMessage!,
                style: AppTypography.bodySm.copyWith(color: AppColors.error),
              ),
            ),
          ],
          if (sync.infoMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                sync.infoMessage!,
                style: AppTypography.bodySm.copyWith(color: AppColors.primary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final readOnlyExam = ref.watch(examReadOnlyProvider).value ?? false;
    final cloudSync = ref.watch(cloudSyncProvider);

    return AlertDialog(
      title: const Text('Bóveda, Nube & Ajustes'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildCloudAccountCard(cloudSync),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLowest,
                  borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
                  border: Border.all(color: AppColors.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'UBICACIÓN LOCAL DE LA BÓVEDA',
                      style: AppTypography.badgeMono.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      _vaultDir.isEmpty ? 'Cargando...' : _vaultDir,
                      style: AppTypography.monoSm.copyWith(
                        color: AppColors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pickCustomVaultDir,
                          icon: const Icon(Icons.folder_open_rounded, size: 16),
                          label: const Text('Cambiar carpeta (USB/Sync)'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  await DatabaseHelper.instance
                                      .setCustomVaultDir(null);
                                  await ref
                                      .read(vaultItemsProvider.notifier)
                                      .refresh();
                                  await _loadPath();
                                },
                          child: const Text('Usar ruta por defecto'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'PAQUETE PORTABLE ALTERNATIVO (.vaultpkg)',
                style: AppTypography.badgeMono.copyWith(color: AppColors.outline),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _exportPortable,
                      icon: const Icon(Icons.upload_file_rounded, size: 17),
                      label: const Text('Exportar Bóveda'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _importPortable,
                      icon: const Icon(Icons.download_rounded, size: 17),
                      label: const Text('Importar Paquete'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SwitchListTile(
                value: readOnlyExam,
                contentPadding: EdgeInsets.zero,
                activeThumbColor: AppColors.primary,
                title: Text(
                  'Modo Solo Lectura de Examen',
                  style: AppTypography.bodyMd.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  'Bloquea ediciones accidentales en notas y subrayados durante la prueba.',
                  style: AppTypography.bodySm,
                ),
                onChanged: (v) =>
                    ref.read(examReadOnlyProvider.notifier).setEnabled(v),
              ),
              const Divider(),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final navigator = Navigator.of(context);
                          setState(() => _busy = true);
                          await ref
                              .read(vaultItemsProvider.notifier)
                              .resetDemoData();
                          if (mounted) {
                            setState(() => _busy = false);
                            navigator.pop();
                          }
                        },
                  icon: const Icon(Icons.restore_rounded, size: 16),
                  label: const Text('Restaurar estructura inicial de ejemplo'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}
