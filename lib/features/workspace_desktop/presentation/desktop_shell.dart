import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:vaultstudy/core/constants/app_breakpoints.dart';
import 'package:vaultstudy/core/theme/app_colors.dart';
import 'package:vaultstudy/core/theme/app_typography.dart';
import 'package:vaultstudy/core/widgets/type_badge.dart';
import 'package:vaultstudy/core/widgets/vault_logo.dart';
import 'package:vaultstudy/features/cloud_sync/application/cloud_sync_service.dart';
import 'package:vaultstudy/features/global_search/presentation/super_search_dialog.dart';
import 'package:vaultstudy/features/notes_editor/presentation/vault_note_pane.dart';
import 'package:vaultstudy/features/pdf_viewer/presentation/vault_pdf_viewer.dart';
import 'package:vaultstudy/features/vault_tree/application/vault_providers.dart';
import 'package:vaultstudy/features/vault_tree/domain/vault_item.dart';
import 'package:vaultstudy/features/vault_tree/presentation/vault_dialogs.dart';
import 'package:vaultstudy/features/workspace_desktop/application/workspace_state.dart';
import 'widgets/vault_tree_sidebar.dart';

/// Desktop (>= 900px) shell with fixed header, collapsible 260px sidebar,
/// Split/Single panes, Exam Fullscreen mode, Drag & Drop, and keyboard shortcuts.
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  final GlobalKey<VaultPdfViewerState> _leftPdfKey = GlobalKey();
  final GlobalKey<VaultPdfViewerState> _rightPdfKey = GlobalKey();
  final GlobalKey<VaultPdfViewerState> _singlePdfKey = GlobalKey();
  final GlobalKey<VaultNotePaneState> _leftNoteKey = GlobalKey();
  final GlobalKey<VaultNotePaneState> _rightNoteKey = GlobalKey();
  final GlobalKey<VaultNotePaneState> _singleNoteKey = GlobalKey();

  Future<void> _openSuperSearch(BuildContext context) async {
    final selection = await SuperSearchDialog.show(context);
    if (selection == null) return;

    final allItems = ref.read(vaultItemsProvider).value ?? [];
    final wsNotifier = ref.read(workspaceProvider.notifier);
    final targetItem = selection.result.item;
    wsNotifier.expandAncestors(allItems, targetItem);
    wsNotifier.openItem(
      targetItem,
      page: selection.result.matchedPageNumber ?? 1,
      forceSplit: selection.openInSplit ? true : null,
    );
  }

  void _cycleActiveNoteMode() {
    final ws = ref.read(workspaceProvider);
    if (!ws.isSplitMode) {
      _singleNoteKey.currentState?.cycleViewMode();
      return;
    }
    (_rightNoteKey.currentState ?? _leftNoteKey.currentState)?.cycleViewMode();
  }

  void _openActivePdfSearch() {
    final ws = ref.read(workspaceProvider);
    if (!ws.isSplitMode) {
      _singlePdfKey.currentState?.openInDocSearch();
      return;
    }
    (_leftPdfKey.currentState ?? _rightPdfKey.currentState)?.openInDocSearch();
  }

  @override
  Widget build(BuildContext context) {
    final allItems = ref.watch(vaultItemsProvider).value ?? [];
    final ws = ref.watch(workspaceProvider);
    final wsNotifier = ref.read(workspaceProvider.notifier);

    final byId = {for (final i in allItems) i.id: i};
    final leftItem = ws.leftItemId != null ? byId[ws.leftItemId] : null;
    final rightItem = ws.rightItemId != null ? byId[ws.rightItemId] : null;
    final activeItem =
        (ws.activeSingleItemId != null ? byId[ws.activeSingleItemId] : null) ??
        rightItem ??
        leftItem;

    final breadcrumbText = activeItem != null
        ? '${buildBreadcrumbPath(allItems, activeItem)} / ${activeItem.title}'
        : 'BÓVEDA / MODO ESTUDIO';

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            _openSuperSearch(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            _openSuperSearch(context),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            wsNotifier.toggleSidebar(),
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            wsNotifier.toggleSidebar(),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
            wsNotifier.closeActiveTab(),
        const SingleActivator(
          LogicalKeyboardKey.keyT,
          control: true,
          shift: true,
        ): () =>
            wsNotifier.reopenLastClosedTab(),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true):
            _cycleActiveNoteMode,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _openActivePdfSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (ws.isExamFullscreen) {
            wsNotifier.setExamFullscreen(false);
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppColors.surface,
          body: Column(
            children: [
              // Fixed 56px Top Command Header
              if (!ws.isExamFullscreen)
                _DesktopHeader(
                  breadcrumb: breadcrumbText,
                  isSidebarVisible: ws.isSidebarVisible,
                  onToggleSidebar: wsNotifier.toggleSidebar,
                  onOpenSearch: () => _openSuperSearch(context),
                  onOpenVaultSettings: () =>
                      VaultDialogs.showVaultSettingsDialog(context, ref),
                ),
              // Main Area: Collapsible Left Sidebar + Center Workspace
              Expanded(
                child: Row(
                  children: [
                    if (!ws.isExamFullscreen && ws.isSidebarVisible)
                      const VaultTreeSidebar(),
                    Expanded(
                      child: Column(
                        children: [
                          // Tabs + Split/Single + Exam Fullscreen bar
                          _WorkspaceTabsBar(
                            ws: ws,
                            byId: byId,
                            onSelectTab: (item) => wsNotifier.openItem(item),
                            onCloseTab: (id) => wsNotifier.closeTab(id),
                            onToggleSplit: (split) =>
                                wsNotifier.setSplitMode(split),
                            onToggleExamFullscreen: () =>
                                wsNotifier.toggleExamFullscreen(),
                            onReopenSidebar: (!ws.isExamFullscreen &&
                                    !ws.isSidebarVisible)
                                ? wsNotifier.toggleSidebar
                                : null,
                          ),
                          // Panes Area
                          Expanded(
                            child: _buildWorkspacePanes(
                              context: context,
                              ws: ws,
                              wsNotifier: wsNotifier,
                              leftItem: leftItem,
                              rightItem: rightItem,
                              singleItem: activeItem,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspacePanes({
    required BuildContext context,
    required WorkspaceState ws,
    required WorkspaceNotifier wsNotifier,
    required VaultItem? leftItem,
    required VaultItem? rightItem,
    required VaultItem? singleItem,
  }) {
    if (!ws.isSplitMode) {
      final Widget paneChild = singleItem == null
          ? const _EmptyPanePlaceholder(
              title: 'Sin archivo activo',
              subtitle:
                  'Selecciona un boletín PDF, libro o apunte desde el árbol izquierdo, arrastra archivos aquí o pulsa Ctrl+K.',
            )
          : _renderItemPane(
              singleItem,
              ws.targetPageFor(singleItem.id),
              pdfKey: _singlePdfKey,
              noteKey: _singleNoteKey,
            );
      return _wrapPaneDropZone(
        context: context,
        pane: TargetPane.left,
        item: singleItem,
        ws: ws,
        wsNotifier: wsNotifier,
        child: paneChild,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final leftWidth =
            (totalWidth * ws.splitRatio).clamp(280.0, totalWidth - 280.0);
        return Row(
          children: [
            SizedBox(
              width: totalWidth < 600 ? totalWidth / 2 : leftWidth,
              child: _wrapPaneDropZone(
                context: context,
                pane: TargetPane.left,
                item: leftItem,
                ws: ws,
                wsNotifier: wsNotifier,
                child: leftItem != null
                    ? _renderItemPane(
                        leftItem,
                        ws.targetPageFor(leftItem.id),
                        pdfKey: _leftPdfKey,
                        noteKey: _leftNoteKey,
                      )
                    : const _EmptyPanePlaceholder(
                        title: 'Panel Izquierdo (PDF / Libro)',
                        subtitle:
                            'Haz clic o arrastra cualquier PDF, libro o archivo aquí.',
                      ),
              ),
            ),
            // Draggable vertical divider
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (details) {
                  if (totalWidth <= 0) return;
                  wsNotifier.setSplitRatio(
                    (leftWidth + details.delta.dx) / totalWidth,
                  );
                },
                child: Container(
                  width: 5,
                  color: AppColors.surfaceLowest,
                  child: Center(
                    child: Container(
                      width: 1,
                      color: AppColors.outlineVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _wrapPaneDropZone(
                context: context,
                pane: TargetPane.right,
                item: rightItem,
                ws: ws,
                wsNotifier: wsNotifier,
                child: rightItem != null
                    ? _renderItemPane(
                        rightItem,
                        ws.targetPageFor(rightItem.id),
                        pdfKey: _rightPdfKey,
                        noteKey: _rightNoteKey,
                      )
                    : const _EmptyPanePlaceholder(
                        title: 'Panel Derecho (Apuntes)',
                        subtitle:
                            'Abre, crea o arrastra un apunte aquí para estudiar en paralelo.',
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _wrapPaneDropZone({
    required BuildContext context,
    required TargetPane pane,
    required VaultItem? item,
    required WorkspaceState ws,
    required WorkspaceNotifier wsNotifier,
    required Widget child,
  }) {
    final Widget withInternalTarget = DragTarget<VaultItem>(
      onWillAcceptWithDetails: (d) => d.data.type != VaultItemType.folder,
      onAcceptWithDetails: (d) {
        wsNotifier.openItem(
          d.data,
          pane: pane,
          forceSplit: ws.isSplitMode ? true : null,
        );
      },
      builder: (ctx, candidates, _) {
        final isHovered = candidates.isNotEmpty;
        return Stack(
          children: [
            child,
            if (isHovered)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.08),
                      border: Border.all(
                        color: AppColors.primary,
                        width: 2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.primary),
                      ),
                      child: Text(
                        pane == TargetPane.left
                            ? 'Soltar para abrir en Panel Izquierdo'
                            : 'Soltar para abrir en Panel Derecho',
                        style: AppTypography.badgeMono.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );

    // VaultNotePane owns its own non-overlapping DropTarget (image insert + batch import).
    if (item != null && !item.type.isDocument) {
      return withInternalTarget;
    }

    return DropTarget(
      onDragDone: (details) async {
        final paths = details.files.map((f) => f.path).toList();
        if (paths.isEmpty || !mounted) return;
        final created = await VaultDialogs.confirmAndRunBatchImport(
          context,
          ref,
          paths: paths,
          parentId: ws.selectedFolderId,
        );
        final firstFile =
            created.where((e) => e.type != VaultItemType.folder).firstOrNull;
        if (firstFile != null) {
          wsNotifier.openItem(
            firstFile,
            pane: pane,
            forceSplit: ws.isSplitMode ? true : null,
          );
        }
      },
      child: withInternalTarget,
    );
  }

  Widget _renderItemPane(
    VaultItem item,
    int targetPage, {
    required GlobalKey<VaultPdfViewerState> pdfKey,
    required GlobalKey<VaultNotePaneState> noteKey,
  }) {
    if (item.type.isDocument) {
      return VaultPdfViewer(
        key: pdfKey,
        item: item,
        initialPage: targetPage,
      );
    }
    return VaultNotePane(
      key: noteKey,
      item: item,
    );
  }
}

class _DesktopHeader extends ConsumerWidget {
  const _DesktopHeader({
    required this.breadcrumb,
    required this.isSidebarVisible,
    required this.onToggleSidebar,
    required this.onOpenSearch,
    required this.onOpenVaultSettings,
  });

  final String breadcrumb;
  final bool isSidebarVisible;
  final VoidCallback onToggleSidebar;
  final VoidCallback onOpenSearch;
  final VoidCallback onOpenVaultSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(cloudSyncProvider);
    final Color statusColor;
    final String statusText;
    if (sync.isSyncing) {
      statusColor = AppColors.secondary;
      statusText = 'SINCRONIZANDO NUBE...';
    } else if (sync.isSignedIn && sync.isOffline) {
      statusColor = AppColors.bookAmber;
      statusText = sync.pendingChangesCount > 0
          ? 'MODO OFFLINE • ${sync.pendingChangesCount} PEND.'
          : 'MODO EXAMEN: OFFLINE 100% LISTO';
    } else if (sync.isSignedIn) {
      statusColor = AppColors.primary;
      statusText = sync.pendingChangesCount > 0
          ? 'NUBE ACTIVA • ${sync.pendingChangesCount} PEND.'
          : 'NUBE & OFFLINE LISTO';
    } else {
      statusColor = AppColors.primary;
      statusText = 'MODO EXAMEN: OFFLINE 100% LISTO';
    }

    return Container(
      height: AppBreakpoints.desktopHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceLowest,
        border: Border(
          bottom: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: isSidebarVisible
                ? 'Ocultar árbol lateral (Ctrl+B)'
                : 'Mostrar árbol lateral (Ctrl+B)',
            onPressed: onToggleSidebar,
            icon: Icon(
              isSidebarVisible
                  ? Icons.menu_open_rounded
                  : Icons.view_sidebar_outlined,
              size: 19,
              color: isSidebarVisible
                  ? AppColors.onSurfaceVariant
                  : AppColors.primary,
            ),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          ),
          const SizedBox(width: 6),
          const VaultLogo(),
          Container(
            height: 18,
            width: 1,
            margin: const EdgeInsets.symmetric(horizontal: 14),
            color: AppColors.outlineVariant,
          ),
          Expanded(
            child: Text(
              breadcrumb,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.monoSm.copyWith(color: AppColors.secondary),
            ),
          ),
          const SizedBox(width: 12),
          // Exam / Cloud Offline Badge
          InkWell(
            onTap: sync.isSignedIn && !sync.isSyncing
                ? () => ref
                    .read(cloudSyncProvider.notifier)
                    .syncNow(silentIfOffline: false)
                : onOpenVaultSettings,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                border: Border.all(
                  color: statusColor.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    statusText,
                    style: AppTypography.badgeMono.copyWith(
                      color: statusColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Ctrl+K Global Search Button
          InkWell(
            onTap: onOpenSearch,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surfaceLow,
                borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.8),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: AppColors.secondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Buscar o comando...',
                    style: AppTypography.monoSm.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHighest,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppColors.outlineVariant),
                    ),
                    child: Text(
                      'Ctrl+K',
                      style: AppTypography.badgeMono.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            height: 18,
            width: 1,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            color: AppColors.outlineVariant,
          ),
          OutlinedButton.icon(
            onPressed: onOpenVaultSettings,
            icon: Icon(
              sync.isSignedIn
                  ? Icons.cloud_done_outlined
                  : Icons.inventory_2_outlined,
              size: 15,
              color: sync.isSignedIn ? AppColors.primary : AppColors.secondary,
            ),
            label: Text(sync.isSignedIn ? 'Bóveda • Cuenta' : 'Bóveda'),
            style: OutlinedButton.styleFrom(
              backgroundColor: AppColors.surfaceContainer,
              foregroundColor: AppColors.onSurface,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceTabsBar extends StatelessWidget {
  const _WorkspaceTabsBar({
    required this.ws,
    required this.byId,
    required this.onSelectTab,
    required this.onCloseTab,
    required this.onToggleSplit,
    required this.onToggleExamFullscreen,
    this.onReopenSidebar,
  });

  final WorkspaceState ws;
  final Map<String, VaultItem> byId;
  final void Function(VaultItem) onSelectTab;
  final void Function(String) onCloseTab;
  final void Function(bool) onToggleSplit;
  final VoidCallback onToggleExamFullscreen;
  final VoidCallback? onReopenSidebar;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceLowest,
        border: Border(
          bottom: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
      ),
      child: Row(
        children: [
          if (onReopenSidebar != null) ...[
            IconButton(
              tooltip: 'Mostrar árbol lateral (Ctrl+B)',
              onPressed: onReopenSidebar,
              icon: const Icon(
                Icons.view_sidebar_outlined,
                size: 16,
                color: AppColors.primary,
              ),
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final tab in ws.tabs)
                  if (byId[tab.itemId] != null)
                    _TabChip(
                      item: byId[tab.itemId]!,
                      isFocused: ws.isSplitMode
                          ? (ws.leftItemId == tab.itemId ||
                              ws.rightItemId == tab.itemId)
                          : ws.activeSingleItemId == tab.itemId,
                      onTap: () => onSelectTab(byId[tab.itemId]!),
                      onClose: () => onCloseTab(tab.itemId),
                    ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Split / Single Toggle
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: AppColors.surfaceLow,
              borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
              border: Border.all(
                color: AppColors.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LayoutModeButton(
                  icon: Icons.vertical_split_rounded,
                  label: 'Split',
                  selected: ws.isSplitMode,
                  onTap: () => onToggleSplit(true),
                ),
                _LayoutModeButton(
                  icon: Icons.crop_square_rounded,
                  label: 'Single',
                  selected: !ws.isSplitMode,
                  onTap: () => onToggleSplit(false),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: onToggleExamFullscreen,
            icon: Icon(
              ws.isExamFullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              size: 16,
            ),
            label: Text(
              ws.isExamFullscreen ? 'Salir Examen' : 'Pantalla Completa Examen',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryContainer,
              foregroundColor: AppColors.onPrimaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.item,
    required this.isFocused,
    required this.onTap,
    required this.onClose,
  });

  final VaultItem item;
  final bool isFocused;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
        child: Container(
          height: 32,
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: isFocused
                ? AppColors.surfaceHigh
                : AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
            border: Border.all(
              color: isFocused
                  ? AppColors.primary.withValues(alpha: 0.45)
                  : AppColors.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TypeBadge(type: item.type),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  item.title,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.monoSm.copyWith(
                    color: isFocused ? AppColors.primary : AppColors.onSurface,
                    fontWeight: isFocused ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(4),
                child: const Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: AppColors.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LayoutModeButton extends StatelessWidget {
  const _LayoutModeButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceHighest : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: selected ? AppColors.primary : AppColors.outline,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: AppTypography.badgeMono.copyWith(
                color: selected ? AppColors.primary : AppColors.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPanePlaceholder extends StatelessWidget {
  const _EmptyPanePlaceholder({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.terminal_rounded,
                size: 40,
                color: AppColors.outlineVariant,
              ),
              const SizedBox(height: 12),
              Text(title, style: AppTypography.headlineSm),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: AppTypography.bodySm,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
