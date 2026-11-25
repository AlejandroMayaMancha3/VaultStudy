import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_breakpoints.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/type_badge.dart';
import '../../../vault_tree/application/vault_providers.dart';
import '../../../vault_tree/domain/vault_item.dart';
import '../../../vault_tree/presentation/vault_dialogs.dart';
import '../../application/workspace_state.dart';

/// Left 260px hierarchical vault explorer with OS & internal drag-and-drop,
/// pinned exam items section, live search filter, and compact creation actions.
class VaultTreeSidebar extends ConsumerStatefulWidget {
  const VaultTreeSidebar({super.key});

  @override
  ConsumerState<VaultTreeSidebar> createState() => _VaultTreeSidebarState();
}

class _VaultTreeSidebarState extends ConsumerState<VaultTreeSidebar> {
  final TextEditingController _filterController = TextEditingController();
  final Map<String, GlobalKey> _folderTileKeys = {};

  String _filterQuery = '';
  bool _showPinnedSection = true;
  bool _isDraggingOsFiles = false;
  String? _hoveredExternalFolderId;
  bool _isDraggingInternal = false;

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  GlobalKey _keyForFolder(String folderId) {
    return _folderTileKeys.putIfAbsent(folderId, GlobalKey.new);
  }

  String? _hitTestFolderAt(Offset globalPos) {
    for (final entry in _folderTileKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final local = box.globalToLocal(globalPos);
      if (box.paintBounds.contains(local)) {
        return entry.key;
      }
    }
    return null;
  }

  Set<String> _computeVisibleIdsForFilter(
    List<VaultItem> items,
    String queryLower,
  ) {
    final byId = {for (final i in items) i.id: i};
    final visible = <String>{};
    for (final item in items) {
      if (item.title.toLowerCase().contains(queryLower)) {
        visible.add(item.id);
        var pid = item.parentId;
        while (pid != null) {
          visible.add(pid);
          pid = byId[pid]?.parentId;
        }
      }
    }
    return visible;
  }

  bool _canDropInternalItem(
    List<VaultItem> allItems,
    VaultItem dragged,
    String? targetFolderId,
  ) {
    if (dragged.id == targetFolderId) return false;
    if (dragged.parentId == targetFolderId) return false;
    if (targetFolderId == null) return true;
    final byId = {for (final i in allItems) i.id: i};
    String? cursor = targetFolderId;
    while (cursor != null) {
      if (cursor == dragged.id) return false;
      cursor = byId[cursor]?.parentId;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(vaultItemsProvider);
    final pinnedItems = ref.watch(pinnedItemsProvider);
    final structureLocked = ref.watch(structureLockedProvider).value ?? true;
    final ws = ref.watch(workspaceProvider);
    final wsNotifier = ref.read(workspaceProvider.notifier);

    return Container(
      width: AppBreakpoints.desktopSidebarWidth,
      decoration: BoxDecoration(
        color: AppColors.surfaceLowest,
        border: Border(
          right: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Column(
        children: [
          // Tree header + compact action buttons
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppColors.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'ÁRBOL DE BÓVEDA',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.labelMono.copyWith(
                      color: AppColors.outline,
                      fontSize: 10.5,
                    ),
                  ),
                ),
                _HeaderIconButton(
                  icon: structureLocked
                      ? Icons.lock_rounded
                      : Icons.lock_open_rounded,
                  tooltip: structureLocked
                      ? 'Seguro activo: evita mover archivos por accidente (clic para desbloquear)'
                      : 'Seguro desactivado: puedes arrastrar archivos (clic para bloquear)',
                  accentColor: structureLocked
                      ? AppColors.bookAmber
                      : AppColors.primary,
                  onTap: () {
                    final nextLocked = !structureLocked;
                    if (nextLocked && _isDraggingInternal) {
                      setState(() => _isDraggingInternal = false);
                    }
                    ref
                        .read(structureLockedProvider.notifier)
                        .setLocked(nextLocked);
                  },
                ),
                _HeaderIconButton(
                  icon: Icons.create_new_folder_outlined,
                  tooltip: 'Nueva Carpeta / Asignatura',
                  onTap: () => _handleCreateFolder(context, ref, ws),
                ),
                _HeaderIconButton(
                  icon: Icons.note_add_outlined,
                  tooltip: 'Nueva Nota',
                  onTap: () => _handleCreateNote(context, ref, ws),
                ),
                _HeaderIconButton(
                  icon: Icons.upload_file_outlined,
                  tooltip: 'Importar archivos (PDF, MD, TXT, Código)',
                  accentColor: AppColors.primary,
                  onTap: () => _handleImportFiles(context, ref, ws),
                ),
                _HeaderIconButton(
                  icon: Icons.drive_folder_upload_outlined,
                  tooltip: 'Importar carpeta completa',
                  accentColor: AppColors.secondary,
                  onTap: () => _handleImportFolder(context, ref, ws),
                ),
              ],
            ),
          ),
          if (!structureLocked)
            Container(
              margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.open_with_rounded,
                    size: 13,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Modo reorganizar (arrastre activo)',
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.badgeMono.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => ref
                        .read(structureLockedProvider.notifier)
                        .setLocked(true),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Bloquear',
                        style: AppTypography.badgeMono.copyWith(
                          color: AppColors.bookAmber,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Live tree search filter
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: TextField(
              controller: _filterController,
              onChanged: (val) => setState(() => _filterQuery = val.trim()),
              style: AppTypography.monoSm.copyWith(
                fontSize: 11.5,
                color: AppColors.onSurface,
              ),
              decoration: InputDecoration(
                hintText: 'Filtrar archivos o temas...',
                hintStyle: AppTypography.monoSm.copyWith(
                  fontSize: 11,
                  color: AppColors.outline,
                ),
                prefixIcon: const Icon(
                  Icons.filter_list_rounded,
                  size: 15,
                  color: AppColors.outline,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 30,
                  minHeight: 28,
                ),
                suffixIcon: _filterQuery.isNotEmpty
                    ? IconButton(
                        tooltip: 'Limpiar filtro',
                        icon: const Icon(Icons.close_rounded, size: 14),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filterQuery = '');
                        },
                      )
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 7,
                ),
              ),
            ),
          ),
          // External OS Drag & Drop target + Recursive Tree
          Expanded(
            child: DropTarget(
              onDragEntered: (details) {
                setState(() {
                  _isDraggingOsFiles = true;
                  _hoveredExternalFolderId =
                      _hitTestFolderAt(details.globalPosition);
                });
              },
              onDragUpdated: (details) {
                final hit = _hitTestFolderAt(details.globalPosition);
                if (hit != _hoveredExternalFolderId) {
                  setState(() => _hoveredExternalFolderId = hit);
                }
              },
              onDragExited: (_) {
                setState(() {
                  _isDraggingOsFiles = false;
                  _hoveredExternalFolderId = null;
                });
              },
              onDragDone: (details) async {
                final targetFolder =
                    _hoveredExternalFolderId ?? ws.selectedFolderId;
                setState(() {
                  _isDraggingOsFiles = false;
                  _hoveredExternalFolderId = null;
                });
                final paths = details.files.map((f) => f.path).toList();
                if (paths.isEmpty || !mounted) return;
                final created = await VaultDialogs.confirmAndRunBatchImport(
                  context,
                  ref,
                  paths: paths,
                  parentId: targetFolder,
                );
                if (created.isNotEmpty) {
                  if (targetFolder != null) {
                    wsNotifier.expandFolder(targetFolder);
                  }
                  final firstNonFolder = created
                      .where((e) => e.type != VaultItemType.folder)
                      .firstOrNull;
                  if (firstNonFolder != null) {
                    wsNotifier.openItem(firstNonFolder);
                  }
                }
              },
              child: Stack(
                children: [
                  itemsAsync.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (err, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child:
                          Text('Error SQLite: $err', style: AppTypography.bodySm),
                    ),
                    data: (items) {
                      final activeIds = _folderTileKeys.keys.toList();
                      final validFolderIds = items
                          .where((e) => e.type == VaultItemType.folder)
                          .map((e) => e.id)
                          .toSet();
                      for (final id in activeIds) {
                        if (!validFolderIds.contains(id)) {
                          _folderTileKeys.remove(id);
                        }
                      }

                      final qLower = _filterQuery.toLowerCase();
                      final Set<String>? visibleFilterIds = qLower.isEmpty
                          ? null
                          : _computeVisibleIdsForFilter(items, qLower);

                      final roots = items
                          .where(
                            (e) =>
                                e.parentId == null &&
                                (visibleFilterIds == null ||
                                    visibleFilterIds.contains(e.id)),
                          )
                          .toList()
                        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

                      if (items.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.upload_file_outlined,
                                  size: 28,
                                  color: AppColors.primary.withValues(alpha: 0.7),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Bóveda vacía.\nArrastra archivos o carpetas aquí, o usa los botones superiores.',
                                  textAlign: TextAlign.center,
                                  style: AppTypography.bodySm,
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      return Column(
                        children: [
                          if (!structureLocked && _isDraggingInternal)
                            DragTarget<VaultItem>(
                              onWillAcceptWithDetails: (d) =>
                                  !structureLocked &&
                                  _canDropInternalItem(items, d.data, null),
                              onAcceptWithDetails: (d) async {
                                await VaultDialogs.moveItemWithUndoSnackBar(
                                  context,
                                  ref,
                                  item: d.data,
                                  targetParentId: null,
                                  allItems: items,
                                );
                              },
                              builder: (ctx, candidates, _) {
                                final active = candidates.isNotEmpty;
                                return Container(
                                  margin: const EdgeInsets.fromLTRB(
                                    8,
                                    4,
                                    8,
                                    2,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                    horizontal: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: active
                                        ? AppColors.primary
                                            .withValues(alpha: 0.18)
                                        : AppColors.surfaceContainer,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: active
                                          ? AppColors.primary
                                          : AppColors.outlineVariant
                                              .withValues(alpha: 0.6),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.drive_file_move_rtl_outlined,
                                        size: 14,
                                        color: active
                                            ? AppColors.primary
                                            : AppColors.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Soltar para mover a Raíz',
                                        style: AppTypography.badgeMono.copyWith(
                                          color: active
                                              ? AppColors.primary
                                              : AppColors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                              children: [
                                // Collapsible Pinned Exam Items Section
                                if (pinnedItems.isNotEmpty && qLower.isEmpty) ...[
                                  InkWell(
                                    onTap: () => setState(
                                      () => _showPinnedSection =
                                          !_showPinnedSection,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 5,
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.push_pin_rounded,
                                            size: 12.5,
                                            color: AppColors.secondary,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              'FIJADOS EXAMEN (${pinnedItems.length})',
                                              style: AppTypography.labelMono
                                                  .copyWith(
                                                fontSize: 10,
                                                color: AppColors.secondary,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          Icon(
                                            _showPinnedSection
                                                ? Icons.expand_less_rounded
                                                : Icons.expand_more_rounded,
                                            size: 15,
                                            color: AppColors.outline,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (_showPinnedSection) ...[
                                    for (final pinned in pinnedItems)
                                      _PinnedQuickTile(
                                        item: pinned,
                                        isActive: ws.leftItemId == pinned.id ||
                                            ws.rightItemId == pinned.id,
                                        onTap: () =>
                                            wsNotifier.openItem(pinned),
                                      ),
                                  ],
                                  Divider(
                                    height: 12,
                                    color: AppColors.outlineVariant
                                        .withValues(alpha: 0.35),
                                  ),
                                ],
                                if (roots.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      'Sin coincidencias para "$_filterQuery".',
                                      textAlign: TextAlign.center,
                                      style: AppTypography.bodySm.copyWith(
                                        color: AppColors.outline,
                                      ),
                                    ),
                                  )
                                else
                                  for (final root in roots)
                                    _TreeNodeTile(
                                      item: root,
                                      allItems: items,
                                      visibleFilterIds: visibleFilterIds,
                                      depth: 0,
                                      ws: ws,
                                      wsNotifier: wsNotifier,
                                      keyForFolder: _keyForFolder,
                                      hoveredExternalFolderId:
                                          _hoveredExternalFolderId,
                                      canDropInternal: (dragged, targetId) =>
                                          !structureLocked &&
                                          _canDropInternalItem(
                                            items,
                                            dragged,
                                            targetId,
                                          ),
                                      structureLocked: structureLocked,
                                      onInternalDragChanged: (dragging) {
                                        if (_isDraggingInternal != dragging &&
                                            mounted) {
                                          setState(() =>
                                              _isDraggingInternal = dragging);
                                        }
                                      },
                                    ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (_isDraggingOsFiles)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          margin: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppColors.primary,
                              width: 1.5,
                            ),
                          ),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              margin: const EdgeInsets.all(10),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceHigh,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color:
                                      AppColors.primary.withValues(alpha: 0.5),
                                ),
                              ),
                              child: Text(
                                _hoveredExternalFolderId != null
                                    ? 'Soltar para importar en esta carpeta'
                                    : 'Soltar para importar archivos / carpeta',
                                textAlign: TextAlign.center,
                                style: AppTypography.badgeMono.copyWith(
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Bottom Offline Telemetry & Settings
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surfaceLow.withValues(alpha: 0.6),
              border: Border(
                top: BorderSide(
                  color: AppColors.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Modo Examen 100% Offline',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.monoSm.copyWith(
                          color: AppColors.primary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'LISTO',
                      style: AppTypography.badgeMono.copyWith(
                        color: AppColors.primaryFixed,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      VaultDialogs.showVaultSettingsDialog(context, ref),
                  icon: const Icon(Icons.settings_outlined, size: 15),
                  label: const Text('Configuración Bóveda'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.onSurfaceVariant,
                    backgroundColor: AppColors.surfaceContainer,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleCreateFolder(
    BuildContext context,
    WidgetRef ref,
    WorkspaceState ws,
  ) async {
    final items = ref.read(vaultItemsProvider).value ?? [];
    final parent = items
        .where(
          (e) =>
              e.id == ws.selectedFolderId && e.type == VaultItemType.folder,
        )
        .firstOrNull;
    String? targetParentId;
    String? targetTitle;
    if (parent != null) {
      targetParentId = await showDialog<String?>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ubicación de la carpeta'),
          content: Text(
            '¿Crear como asignatura en la raíz o dentro de "${parent.title}"?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, '__ROOT__'),
              child: const Text('En Raíz (Asignatura)'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, parent.id),
              child: Text('Dentro de "${parent.title}"'),
            ),
          ],
        ),
      );
      if (targetParentId == null) return;
      if (targetParentId == '__ROOT__') {
        targetParentId = null;
      } else {
        targetTitle = parent.title;
      }
    }
    if (!context.mounted) return;
    final created = await VaultDialogs.showCreateFolderDialog(
      context,
      ref,
      parentId: targetParentId,
      parentTitle: targetTitle,
    );
    if (created != null) {
      final wsNotifier = ref.read(workspaceProvider.notifier);
      if (targetParentId != null) {
        wsNotifier.expandFolder(targetParentId);
      }
      wsNotifier.expandFolder(created.id);
    }
  }

  Future<void> _handleCreateNote(
    BuildContext context,
    WidgetRef ref,
    WorkspaceState ws,
  ) async {
    final items = ref.read(vaultItemsProvider).value ?? [];
    final parent = items
        .where(
          (e) =>
              e.id == ws.selectedFolderId && e.type == VaultItemType.folder,
        )
        .firstOrNull;
    final created = await VaultDialogs.showCreateNoteDialog(
      context,
      ref,
      parentId: parent?.id,
      parentTitle: parent?.title,
    );
    if (created != null) {
      ref.read(workspaceProvider.notifier).openItem(created);
    }
  }

  Future<void> _handleImportFiles(
    BuildContext context,
    WidgetRef ref,
    WorkspaceState ws,
  ) async {
    final items = ref.read(vaultItemsProvider).value ?? [];
    final parent = items
        .where(
          (e) =>
              e.id == ws.selectedFolderId && e.type == VaultItemType.folder,
        )
        .firstOrNull;
    final created = await VaultDialogs.showImportFilesDialog(
      context,
      ref,
      parentId: parent?.id,
    );
    if (created.isNotEmpty) {
      final target = created
          .where((e) => e.type != VaultItemType.folder)
          .firstOrNull;
      if (target != null) {
        ref.read(workspaceProvider.notifier).openItem(target);
      }
    }
  }

  Future<void> _handleImportFolder(
    BuildContext context,
    WidgetRef ref,
    WorkspaceState ws,
  ) async {
    final items = ref.read(vaultItemsProvider).value ?? [];
    final parent = items
        .where(
          (e) =>
              e.id == ws.selectedFolderId && e.type == VaultItemType.folder,
        )
        .firstOrNull;
    final created = await VaultDialogs.showImportDirectoryDialog(
      context,
      ref,
      parentId: parent?.id,
    );
    if (created.isNotEmpty) {
      final firstFolder =
          created.where((e) => e.type == VaultItemType.folder).firstOrNull;
      if (firstFolder != null) {
        ref.read(workspaceProvider.notifier).expandFolder(firstFolder.id);
      }
      final target = created
          .where((e) => e.type != VaultItemType.folder)
          .firstOrNull;
      if (target != null) {
        ref.read(workspaceProvider.notifier).openItem(target);
      }
    }
  }
}

class _PinnedQuickTile extends StatelessWidget {
  const _PinnedQuickTile({
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  final VaultItem item;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isActive
              ? AppColors.surfaceHigh
              : AppColors.surfaceLow.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
        ),
        child: Row(
          children: [
            TypeBadge(type: item.type),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.monoSm.copyWith(
                  fontSize: 11.5,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: isActive ? AppColors.primary : AppColors.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.accentColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(26, 26),
        padding: const EdgeInsets.all(4),
      ),
      icon: Icon(
        icon,
        size: 16.5,
        color: accentColor ?? AppColors.onSurfaceVariant,
      ),
    );
  }
}

class _TreeNodeTile extends ConsumerWidget {
  const _TreeNodeTile({
    required this.item,
    required this.allItems,
    required this.visibleFilterIds,
    required this.depth,
    required this.ws,
    required this.wsNotifier,
    required this.keyForFolder,
    required this.hoveredExternalFolderId,
    required this.canDropInternal,
    required this.structureLocked,
    required this.onInternalDragChanged,
  });

  final VaultItem item;
  final List<VaultItem> allItems;
  final Set<String>? visibleFilterIds;
  final int depth;
  final WorkspaceState ws;
  final WorkspaceNotifier wsNotifier;
  final GlobalKey Function(String folderId) keyForFolder;
  final String? hoveredExternalFolderId;
  final bool Function(VaultItem dragged, String? targetId) canDropInternal;
  final bool structureLocked;
  final ValueChanged<bool> onInternalDragChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFolder = item.type == VaultItemType.folder;
    final isFiltered = visibleFilterIds != null;
    final isExpanded = isFiltered || ws.expandedFolderIds.contains(item.id);
    final isSelectedLeft = ws.leftItemId == item.id;
    final isSelectedRight = ws.rightItemId == item.id;
    final isActive = isSelectedLeft || isSelectedRight;
    final isSelectedFolder = isFolder && ws.selectedFolderId == item.id;
    final isExtHoverTarget = isFolder && hoveredExternalFolderId == item.id;

    final children = allItems
        .where(
          (e) =>
              e.parentId == item.id &&
              (visibleFilterIds == null || visibleFilterIds!.contains(e.id)),
        )
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    Widget buildTileContent({required bool isInternalDropHover}) {
      return GestureDetector(
        onSecondaryTapUp: (details) =>
            _showContextMenu(context, ref, details.globalPosition),
        child: InkWell(
          onTap: () => wsNotifier.openItem(item),
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
          child: Container(
            key: isFolder ? keyForFolder(item.id) : null,
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: EdgeInsets.fromLTRB(8.0 + depth * 12.0, 6, 4, 6),
            decoration: BoxDecoration(
              color: (isInternalDropHover || isExtHoverTarget)
                  ? AppColors.primary.withValues(alpha: 0.16)
                  : isActive
                      ? AppColors.surfaceHigh
                      : isSelectedFolder
                          ? AppColors.surfaceContainer.withValues(alpha: 0.7)
                          : Colors.transparent,
              borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
              border: (isInternalDropHover || isExtHoverTarget)
                  ? Border.all(color: AppColors.primary, width: 1.2)
                  : isActive
                      ? const Border(
                          left: BorderSide(color: AppColors.primary, width: 2.5),
                        )
                      : null,
            ),
            child: Row(
              children: [
                if (isFolder) ...[
                  Icon(
                    isExpanded
                        ? Icons.folder_open_rounded
                        : Icons.folder_rounded,
                    size: 16,
                    color: depth == 0
                        ? AppColors.secondary
                        : (isExpanded
                            ? AppColors.primaryFixed
                            : AppColors.outline),
                  ),
                  const SizedBox(width: 7),
                ] else ...[
                  TypeBadge(type: item.type),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.monoSm.copyWith(
                      fontSize: isFolder && depth == 0 ? 12.5 : 11.5,
                      fontWeight: isActive || (isFolder && depth == 0)
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: isActive
                          ? AppColors.primary
                          : isFolder
                              ? AppColors.onSurface
                              : AppColors.onSurfaceVariant,
                    ),
                  ),
                ),
                if (item.isPinned)
                  const Padding(
                    padding: EdgeInsets.only(right: 2),
                    child: Icon(
                      Icons.push_pin_rounded,
                      size: 12,
                      color: AppColors.secondary,
                    ),
                  ),
                Builder(
                  builder: (btnContext) => InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () {
                      final box = btnContext.findRenderObject() as RenderBox;
                      final pos = box.localToGlobal(
                        Offset(box.size.width, box.size.height),
                      );
                      _showContextMenu(context, ref, pos);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.more_horiz_rounded,
                        size: 14,
                        color: AppColors.outline.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final Widget wrappedTarget = isFolder && !structureLocked
        ? DragTarget<VaultItem>(
            onWillAcceptWithDetails: (details) =>
                !structureLocked && canDropInternal(details.data, item.id),
            onAcceptWithDetails: (details) async {
              await VaultDialogs.moveItemWithUndoSnackBar(
                context,
                ref,
                item: details.data,
                targetParentId: item.id,
                allItems: allItems,
              );
              wsNotifier.expandFolder(item.id);
            },
            builder: (ctx, candidateData, _) => buildTileContent(
              isInternalDropHover: candidateData.isNotEmpty,
            ),
          )
        : buildTileContent(isInternalDropHover: false);

    final Widget draggableTile = Draggable<VaultItem>(
      data: item,
      maxSimultaneousDrags: structureLocked ? 0 : 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => onInternalDragChanged(true),
      onDragEnd: (_) => onInternalDragChanged(false),
      onDraggableCanceled: (_, _) => onInternalDragChanged(false),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.primary, width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isFolder)
                const Icon(
                  Icons.folder_rounded,
                  size: 15,
                  color: AppColors.secondary,
                )
              else
                TypeBadge(type: item.type),
              const SizedBox(width: 6),
              Text(
                item.title,
                style: AppTypography.monoSm.copyWith(
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: wrappedTarget),
      child: wrappedTarget,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        draggableTile,
        if (isFolder && isExpanded && children.isNotEmpty)
          Container(
            margin: EdgeInsets.only(left: 14.0 + depth * 12.0),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: AppColors.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final child in children)
                  _TreeNodeTile(
                    item: child,
                    allItems: allItems,
                    visibleFilterIds: visibleFilterIds,
                    depth: 0,
                    ws: ws,
                    wsNotifier: wsNotifier,
                    keyForFolder: keyForFolder,
                    hoveredExternalFolderId: hoveredExternalFolderId,
                    canDropInternal: canDropInternal,
                    structureLocked: structureLocked,
                    onInternalDragChanged: onInternalDragChanged,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (item.type == VaultItemType.folder) ...[
          const PopupMenuItem(
            value: 'new_folder',
            child: Text('Nueva subcarpeta'),
          ),
          const PopupMenuItem(
            value: 'new_note',
            child: Text('Nueva nota aquí'),
          ),
          const PopupMenuItem(
            value: 'import_files',
            child: Text('Importar archivos / PDFs aquí'),
          ),
          const PopupMenuItem(
            value: 'import_folder',
            child: Text('Importar carpeta completa aquí'),
          ),
          const PopupMenuDivider(),
        ] else ...[
          const PopupMenuItem(
            value: 'open_left',
            child: Text('Abrir en panel izquierdo'),
          ),
          const PopupMenuItem(
            value: 'open_right',
            child: Text('Abrir en panel derecho'),
          ),
          const PopupMenuItem(
            value: 'pin',
            child: Text('Fijar / Desfijar para examen'),
          ),
          if (item.type.isDocument)
            PopupMenuItem(
              value: 'toggle_book',
              child: Text(
                item.type == VaultItemType.book
                    ? 'Cambiar distintivo a PDF'
                    : 'Marcar como LIBRO (ámbar)',
              ),
            ),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(value: 'rename', child: Text('Renombrar')),
        PopupMenuItem(
          value: 'move',
          child: Text(
            structureLocked ? 'Mover a... (bloqueado)' : 'Mover a...',
          ),
        ),
        PopupMenuItem(
          value: 'up',
          enabled: !structureLocked,
          child: const Text('Subir orden'),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: !structureLocked,
          child: const Text('Bajar orden'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            'Eliminar',
            style: TextStyle(color: AppColors.error),
          ),
        ),
      ],
    );

    if (selected == null || !context.mounted) return;
    switch (selected) {
      case 'new_folder':
        final created = await VaultDialogs.showCreateFolderDialog(
          context,
          ref,
          parentId: item.id,
          parentTitle: item.title,
        );
        if (created != null) wsNotifier.expandFolder(item.id);
      case 'new_note':
        final created = await VaultDialogs.showCreateNoteDialog(
          context,
          ref,
          parentId: item.id,
          parentTitle: item.title,
        );
        if (created != null) wsNotifier.openItem(created);
      case 'import_files':
        final created = await VaultDialogs.showImportFilesDialog(
          context,
          ref,
          parentId: item.id,
        );
        if (created.isNotEmpty) {
          wsNotifier.expandFolder(item.id);
          final target = created
              .where((e) => e.type != VaultItemType.folder)
              .firstOrNull;
          if (target != null) wsNotifier.openItem(target);
        }
      case 'import_folder':
        final created = await VaultDialogs.showImportDirectoryDialog(
          context,
          ref,
          parentId: item.id,
        );
        if (created.isNotEmpty) {
          wsNotifier.expandFolder(item.id);
          final target = created
              .where((e) => e.type != VaultItemType.folder)
              .firstOrNull;
          if (target != null) wsNotifier.openItem(target);
        }
      case 'open_left':
        wsNotifier.openItem(item, pane: TargetPane.left, forceSplit: true);
      case 'open_right':
        wsNotifier.openItem(item, pane: TargetPane.right, forceSplit: true);
      case 'pin':
        await ref
            .read(vaultItemsProvider.notifier)
            .togglePin(item.id, !item.isPinned);
      case 'toggle_book':
        final next = item.type == VaultItemType.book
            ? VaultItemType.pdf
            : VaultItemType.book;
        await ref
            .read(vaultItemsProvider.notifier)
            .toggleDocumentType(item.id, next);
      case 'rename':
        await VaultDialogs.showRenameDialog(context, ref, item);
      case 'move':
        await VaultDialogs.showMoveDialog(context, ref, item);
      case 'up':
        await ref
            .read(vaultItemsProvider.notifier)
            .reorderSibling(item.id, -1);
      case 'down':
        await ref
            .read(vaultItemsProvider.notifier)
            .reorderSibling(item.id, 1);
      case 'delete':
        final deleted =
            await VaultDialogs.showDeleteConfirmDialog(context, ref, item);
        if (deleted) wsNotifier.closeTab(item.id);
    }
  }
}
