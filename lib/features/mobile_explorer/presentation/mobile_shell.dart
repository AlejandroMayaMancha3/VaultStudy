import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/type_badge.dart';
import '../../../core/widgets/vault_logo.dart';
import '../../cloud_sync/application/cloud_sync_service.dart';
import '../../global_search/presentation/super_search_dialog.dart';
import '../../vault_tree/application/vault_providers.dart';
import '../../vault_tree/domain/vault_item.dart';
import '../../vault_tree/presentation/vault_dialogs.dart';
import '../../workspace_desktop/application/workspace_persistence.dart';
import 'mobile_reader_screen.dart';

/// Mobile (< 900px) explorer shell with Folders ("Mis Apuntes"), Recents, and Settings.
class MobileShell extends ConsumerStatefulWidget {
  const MobileShell({super.key});

  @override
  ConsumerState<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<MobileShell> {
  late int _tabIndex;
  String _filterQuery = '';
  late Set<String> _expandedSubjectIds;
  bool _restoredReader = false;

  @override
  void initState() {
    super.initState();
    final initial = WorkspacePersistence.cachedMobileState;
    _tabIndex = initial.tabIndex;
    _expandedSubjectIds = Set<String>.from(initial.expandedSubjectIds);
    if (!WorkspacePersistence.hasPreloaded) {
      unawaited(_loadSavedAsync());
    }
  }

  Future<void> _loadSavedAsync() async {
    final loaded = await WorkspacePersistence.loadMobileState();
    if (loaded == null || !mounted) return;
    setState(() {
      _tabIndex = loaded.tabIndex;
      _expandedSubjectIds = Set<String>.from(loaded.expandedSubjectIds);
    });
  }

  void _persistMobile({String? activeReaderItemId, int? activeReaderPage, bool clearReader = false}) {
    final prev = WorkspacePersistence.cachedMobileState;
    final next = prev.copyWith(
      tabIndex: _tabIndex,
      expandedSubjectIds: Set<String>.from(_expandedSubjectIds),
      activeReaderItemId: clearReader
          ? null
          : (activeReaderItemId ?? prev.activeReaderItemId),
      activeReaderPage: clearReader
          ? 1
          : (activeReaderPage ?? prev.activeReaderPage),
    );
    unawaited(WorkspacePersistence.saveMobileState(next));
  }

  Future<void> _openItemReader(VaultItem item, {int page = 1}) async {
    _persistMobile(activeReaderItemId: item.id, activeReaderPage: page);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MobileReaderScreen(
          initialItemId: item.id,
          initialPage: page,
        ),
      ),
    );
    if (mounted) {
      _persistMobile(clearReader: true);
    }
  }

  Future<void> _openGlobalSearch() async {
    final selection = await SuperSearchDialog.show(
      context,
      initialQuery: _filterQuery,
    );
    if (selection == null || !mounted) return;
    _openItemReader(
      selection.result.item,
      page: selection.result.matchedPageNumber ?? 1,
    );
  }

  Future<void> _showFabCreationMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'AÑADIR A LA BÓVEDA',
                style: AppTypography.labelMono.copyWith(
                  color: AppColors.outline,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(
                  Icons.create_new_folder_outlined,
                  color: AppColors.secondary,
                ),
                title: const Text('Nueva Asignatura o Carpeta'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final created = await VaultDialogs.showCreateFolderDialog(
                    context,
                    ref,
                  );
                  if (created != null) {
                    setState(() => _expandedSubjectIds.add(created.id));
                    _persistMobile();
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.note_add_outlined,
                  color: AppColors.primary,
                ),
                title: const Text('Nueva Nota con Código'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final created = await VaultDialogs.showCreateNoteDialog(
                    context,
                    ref,
                  );
                  if (created != null && mounted) _openItemReader(created);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.upload_file_outlined,
                  color: AppColors.error,
                ),
                title: const Text('Importar archivos (PDF, MD, Código...)'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final created = await VaultDialogs.showImportFilesDialog(
                    context,
                    ref,
                  );
                  final target = created
                      .where((e) => e.type != VaultItemType.folder)
                      .firstOrNull;
                  if (target != null && mounted) _openItemReader(target);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.drive_folder_upload_outlined,
                  color: AppColors.secondary,
                ),
                title: const Text('Importar carpeta completa'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final created = await VaultDialogs.showImportDirectoryDialog(
                    context,
                    ref,
                  );
                  if (created.isNotEmpty) {
                    final firstSubject = created
                        .where((e) => e.type == VaultItemType.folder)
                        .firstOrNull;
                    if (firstSubject != null) {
                      setState(() => _expandedSubjectIds.add(firstSubject.id));
                      _persistMobile();
                    }
                    final target = created
                        .where((e) => e.type != VaultItemType.folder)
                        .firstOrNull;
                    if (target != null && mounted) _openItemReader(target);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(vaultItemsProvider);
    final sync = ref.watch(cloudSyncProvider);

    final loadedItems = itemsAsync.value;
    if (!_restoredReader && loadedItems != null) {
      _restoredReader = true;
      final saved = WorkspacePersistence.cachedMobileState;
      if (saved.activeReaderItemId != null) {
        final target = loadedItems
            .where((e) => e.id == saved.activeReaderItemId)
            .firstOrNull;
        if (target != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _openItemReader(target, page: saved.activeReaderPage);
            }
          });
        } else {
          _persistMobile(clearReader: true);
        }
      }
    }

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: SafeArea(
          bottom: false,
          child: Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.92),
              border: Border(
                bottom: BorderSide(
                  color: AppColors.outlineVariant.withValues(alpha: 0.35),
                ),
              ),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: VaultLogo(uppercaseWordmark: false),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: InkWell(
                    onTap: sync.isSignedIn && !sync.isSyncing
                        ? () => ref
                            .read(cloudSyncProvider.notifier)
                            .syncNow(silentIfOffline: false)
                        : () => VaultDialogs.showVaultSettingsDialog(context, ref),
                    borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainer,
                        borderRadius: BorderRadius.circular(
                          AppBreakpoints.radiusSm,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: sync.isOffline
                                  ? AppColors.bookAmber
                                  : (sync.isSyncing
                                      ? AppColors.secondary
                                      : AppColors.primaryContainer),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Icon(
                            sync.isOffline
                                ? Icons.cloud_off_rounded
                                : Icons.cloud_done_outlined,
                            size: 15,
                            color: sync.isOffline
                                ? AppColors.bookAmber
                                : AppColors.primaryContainer,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              sync.isSyncing
                                  ? 'SINCRONIZANDO'
                                  : (sync.isSignedIn
                                      ? (sync.isOffline
                                          ? 'OFFLINE'
                                          : 'NUBE LISTA')
                                      : 'SYNC OFFLINE'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.badgeMono.copyWith(
                                color: sync.isOffline
                                    ? AppColors.bookAmber
                                    : AppColors.primaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Exportar / Importar Bóveda',
                  icon: const Icon(
                    Icons.inventory_2_outlined,
                    size: 20,
                    color: AppColors.onSurfaceVariant,
                  ),
                  onPressed: () =>
                      VaultDialogs.showVaultSettingsDialog(context, ref),
                ),
              ],
            ),
          ),
        ),
      ),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) => switch (_tabIndex) {
          0 => _buildFoldersTab(items),
          1 => _buildRecentsTab(items),
          _ => _buildSettingsTab(),
        },
      ),
      floatingActionButton: _tabIndex == 2
          ? null
          : FloatingActionButton(
              onPressed: _showFabCreationMenu,
              backgroundColor: AppColors.primaryContainer,
              foregroundColor: AppColors.surfaceLowest,
              shape: const CircleBorder(),
              child: const Icon(Icons.add_rounded, size: 28),
            ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceLowest,
          border: Border(
            top: BorderSide(
              color: AppColors.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
        child: NavigationBar(
          height: 64,
          backgroundColor: AppColors.surfaceLowest,
          indicatorColor: AppColors.surfaceHigh,
          selectedIndex: _tabIndex,
          onDestinationSelected: (idx) {
            setState(() => _tabIndex = idx);
            _persistMobile();
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder_rounded, color: AppColors.primary),
              label: 'Carpetas',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_rounded),
              selectedIcon: Icon(Icons.history_rounded, color: AppColors.primary),
              label: 'Recientes',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings_rounded, color: AppColors.primary),
              label: 'Ajustes',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFoldersTab(List<VaultItem> allItems) {
    final pinned = ref.watch(pinnedItemsProvider);
    final subjects = allItems
        .where(
          (e) => e.parentId == null && e.type == VaultItemType.folder,
        )
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final rootFiles = allItems
        .where(
          (e) => e.parentId == null && e.type != VaultItemType.folder,
        )
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    final q = _filterQuery.trim().toLowerCase();
    final filteredRootFiles = q.isEmpty
        ? rootFiles
        : rootFiles.where((e) => e.title.toLowerCase().contains(q)).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Mis Apuntes',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.headlineLg,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.surfaceLow,
                borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                '#VAULT-LOCAL',
                style: AppTypography.monoSm.copyWith(fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Baúl de Estudio Offline',
          style: AppTypography.bodySm,
        ),
        const SizedBox(height: 12),
        // Search Input + Global Super-Search trigger
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            border: Border.all(
              color: AppColors.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.search_rounded,
                size: 20,
                color: AppColors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  style: AppTypography.bodyMd,
                  decoration: const InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: 'Filtrar asignaturas o buscar en PDFs...',
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  onChanged: (v) => setState(() => _filterQuery = v),
                ),
              ),
              IconButton(
                tooltip: 'Búsqueda profunda en PDFs y código',
                icon: const Icon(
                  Icons.manage_search_rounded,
                  color: AppColors.secondary,
                ),
                onPressed: _openGlobalSearch,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Horizontal Pinned Carousel
        if (pinned.isNotEmpty) ...[
          Row(
            children: [
              const Icon(
                Icons.push_pin_rounded,
                size: 17,
                color: AppColors.secondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'FIJADOS PARA EXAMEN',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.headlineSm.copyWith(fontSize: 14.5),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${pinned.length} ACTIVOS',
                style: AppTypography.badgeMono.copyWith(
                  color: AppColors.secondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 146,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: pinned.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, idx) {
                final item = pinned[idx];
                final path = buildBreadcrumbPath(allItems, item);
                return InkWell(
                  onTap: () => _openItemReader(item),
                  borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
                  child: Container(
                    width: 228,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainer,
                      borderRadius: BorderRadius.circular(
                        AppBreakpoints.radiusMd,
                      ),
                      border: Border.all(
                        color: AppColors.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TypeBadge(type: item.type),
                                const Icon(
                                  Icons.bookmark_rounded,
                                  size: 16,
                                  color: AppColors.primary,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.headlineSm.copyWith(
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              path.isEmpty ? 'Bóveda' : path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.bodySm,
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceLow,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                item.type.isDocument
                                    ? item.formattedSize
                                    : 'Apunte local',
                                style: AppTypography.badgeMono.copyWith(
                                  color: AppColors.primary,
                                ),
                              ),
                              const Icon(
                                Icons.download_done_rounded,
                                size: 15,
                                color: AppColors.primary,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 22),
        ],
        // Subjects Accordions
        Row(
          children: [
            Expanded(
              child: Text(
                'ASIGNATURAS DE BÓVEDA',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.headlineSm.copyWith(fontSize: 14.5),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${subjects.length} MATERIAS',
              style: AppTypography.badgeMono.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final subject in subjects)
          if (q.isEmpty || _subtreeMatches(allItems, subject, q)) ...[
            _SubjectAccordionCard(
              subject: subject,
              allItems: allItems,
              expanded: _expandedSubjectIds.contains(subject.id) || q.isNotEmpty,
              onToggle: () {
                setState(() {
                  if (_expandedSubjectIds.contains(subject.id)) {
                    _expandedSubjectIds.remove(subject.id);
                  } else {
                    _expandedSubjectIds.add(subject.id);
                  }
                });
                _persistMobile();
              },
              onOpenItem: _openItemReader,
            ),
            const SizedBox(height: 10),
          ],
        if (filteredRootFiles.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'ARCHIVOS EN RAÍZ (${filteredRootFiles.length})',
            style: AppTypography.headlineSm.copyWith(fontSize: 14.5),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceLow,
              borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
              border: Border.all(
                color: AppColors.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: Column(
              children: [
                for (final file in filteredRootFiles)
                  _MobileResourceRow(
                    item: file,
                    onTap: () => _openItemReader(file),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  bool _subtreeMatches(
    List<VaultItem> allItems,
    VaultItem node,
    String qLower,
  ) {
    if (node.title.toLowerCase().contains(qLower)) return true;
    for (final child in allItems.where((e) => e.parentId == node.id)) {
      if (_subtreeMatches(allItems, child, qLower)) return true;
    }
    return false;
  }

  Widget _buildRecentsTab(List<VaultItem> allItems) {
    final recents = ref.watch(recentItemsProvider);
    if (recents.isEmpty) {
      return const Center(child: Text('No hay archivos recientes.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: recents.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, idx) {
        final item = recents[idx];
        final path = buildBreadcrumbPath(allItems, item);
        return InkWell(
          onTap: () => _openItemReader(item),
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
              border: Border.all(
                color: AppColors.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              children: [
                TypeBadge(type: item.type),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style: AppTypography.bodyMd.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        path.isEmpty ? 'Raíz' : path,
                        style: AppTypography.monoSm,
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.outline,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsTab() {
    final readOnlyExam = ref.watch(examReadOnlyProvider).value ?? false;
    final sync = ref.watch(cloudSyncProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Ajustes de Bóveda', style: AppTypography.headlineMd),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            border: Border.all(color: AppColors.outlineVariant),
          ),
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  sync.isSignedIn
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_outlined,
                  color: sync.isOffline
                      ? AppColors.bookAmber
                      : AppColors.primary,
                ),
                title: Text(
                  sync.isSignedIn
                      ? (sync.userEmail ?? 'Cuenta conectada')
                      : 'Iniciar sesión en la nube (Supabase)',
                ),
                subtitle: Text(
                  sync.isSignedIn
                      ? '${sync.pendingChangesCount} cambios pendientes • Funciona 100% offline'
                      : 'Descarga y sincroniza tus PDFs y notas en todos tus dispositivos',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => VaultDialogs.showVaultSettingsDialog(context, ref),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.inventory_2_outlined,
                  color: AppColors.secondary,
                ),
                title: const Text('Exportar / Importar paquete portable'),
                subtitle: const Text('Paquete .vaultpkg 100% offline para USB o PC'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => VaultDialogs.showVaultSettingsDialog(context, ref),
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: readOnlyExam,
                activeThumbColor: AppColors.primary,
                title: const Text('Modo Solo Lectura de Examen'),
                subtitle: const Text(
                  'Protege notas y subrayados frente a toques accidentales.',
                ),
                onChanged: (v) =>
                    ref.read(examReadOnlyProvider.notifier).setEnabled(v),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SubjectAccordionCard extends ConsumerWidget {
  const _SubjectAccordionCard({
    required this.subject,
    required this.allItems,
    required this.expanded,
    required this.onToggle,
    required this.onOpenItem,
  });

  final VaultItem subject;
  final List<VaultItem> allItems;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(VaultItem item, {int page}) onOpenItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = allItems
        .where((e) => e.parentId == subject.id)
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    final topicsCount =
        children.where((e) => e.type == VaultItemType.folder).length;
    final totalResources = _countDescendants(allItems, subject.id);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceLow,
        borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Container(
              padding: const EdgeInsets.all(14),
              color: AppColors.surfaceContainer,
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHighest,
                      borderRadius: BorderRadius.circular(
                        AppBreakpoints.radiusSm,
                      ),
                    ),
                    child: const Icon(
                      Icons.folder_special_outlined,
                      size: 20,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          subject.title,
                          style: AppTypography.headlineSm.copyWith(fontSize: 15),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$topicsCount Temas • $totalResources Archivos',
                          style: AppTypography.badgeMono.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: AppColors.onSurfaceVariant,
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: AppColors.onSurfaceVariant,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    onSelected: (value) async {
                      if (value == 'new_folder') {
                        await VaultDialogs.showCreateFolderDialog(
                          context,
                          ref,
                          parentId: subject.id,
                          parentTitle: subject.title,
                        );
                      } else if (value == 'new_note') {
                        final created = await VaultDialogs.showCreateNoteDialog(
                          context,
                          ref,
                          parentId: subject.id,
                          parentTitle: subject.title,
                        );
                        if (created != null) onOpenItem(created);
                      } else if (value == 'import_files') {
                        final created =
                            await VaultDialogs.showImportFilesDialog(
                          context,
                          ref,
                          parentId: subject.id,
                        );
                        final first = created
                            .where((e) => e.type != VaultItemType.folder)
                            .firstOrNull;
                        if (first != null) onOpenItem(first);
                      } else if (value == 'rename') {
                        await VaultDialogs.showRenameDialog(
                          context,
                          ref,
                          subject,
                        );
                      } else if (value == 'delete') {
                        await VaultDialogs.showDeleteConfirmDialog(
                          context,
                          ref,
                          subject,
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'new_folder',
                        child: Text('Nueva subcarpeta'),
                      ),
                      PopupMenuItem(
                        value: 'new_note',
                        child: Text('Nueva nota aquí'),
                      ),
                      PopupMenuItem(
                        value: 'import_files',
                        child: Text('Importar archivos aquí'),
                      ),
                      PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'rename',
                        child: Text('Renombrar'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          'Eliminar',
                          style: TextStyle(color: AppColors.error),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  for (final child in children)
                    if (child.type == VaultItemType.folder)
                      _TopicSection(
                        topic: child,
                        allItems: allItems,
                        onOpenItem: onOpenItem,
                      )
                    else
                      _MobileResourceRow(
                        item: child,
                        onTap: () => onOpenItem(child),
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  int _countDescendants(List<VaultItem> all, String folderId) {
    var count = 0;
    for (final item in all.where((e) => e.parentId == folderId)) {
      if (item.type == VaultItemType.folder) {
        count += _countDescendants(all, item.id);
      } else {
        count++;
      }
    }
    return count;
  }
}

class _TopicSection extends StatelessWidget {
  const _TopicSection({
    required this.topic,
    required this.allItems,
    required this.onOpenItem,
  });

  final VaultItem topic;
  final List<VaultItem> allItems;
  final void Function(VaultItem item, {int page}) onOpenItem;

  @override
  Widget build(BuildContext context) {
    final children = allItems
        .where((e) => e.parentId == topic.id)
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            color: AppColors.surfaceHigh,
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 14,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    topic.title,
                    style: AppTypography.headlineSm.copyWith(fontSize: 13.5),
                  ),
                ),
                Text(
                  '[${children.length} RECURSOS]',
                  style: AppTypography.badgeMono.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
          for (final item in children)
            if (item.type == VaultItemType.folder)
              Padding(
                padding: const EdgeInsets.only(left: 10, top: 6),
                child: _TopicSection(
                  topic: item,
                  allItems: allItems,
                  onOpenItem: onOpenItem,
                ),
              )
            else
              _MobileResourceRow(
                item: item,
                onTap: () => onOpenItem(item),
              ),
        ],
      ),
    );
  }
}

class _MobileResourceRow extends ConsumerWidget {
  const _MobileResourceRow({required this.item, required this.onTap});

  final VaultItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            TypeBadge(type: item.type),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMd.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.type.isDocument
                        ? '${item.formattedSize} • Disponible offline'
                        : 'Apunte local • Tocar para leer',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodySm,
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.check_circle_outline_rounded,
              size: 16,
              color: AppColors.primary,
            ),
            PopupMenuButton<String>(
              icon: const Icon(
                Icons.more_vert_rounded,
                size: 18,
                color: AppColors.onSurfaceVariant,
              ),
              onSelected: (value) async {
                if (value == 'pin') {
                  await ref
                      .read(vaultItemsProvider.notifier)
                      .togglePin(item.id, !item.isPinned);
                } else if (value == 'rename') {
                  await VaultDialogs.showRenameDialog(context, ref, item);
                } else if (value == 'move') {
                  await VaultDialogs.showMoveDialog(context, ref, item);
                } else if (value == 'delete') {
                  await VaultDialogs.showDeleteConfirmDialog(
                    context,
                    ref,
                    item,
                  );
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'pin',
                  child: Text(
                    item.isPinned
                        ? 'Quitar de fijados'
                        : 'Fijar para examen',
                  ),
                ),
                const PopupMenuItem(
                  value: 'rename',
                  child: Text('Renombrar'),
                ),
                const PopupMenuItem(
                  value: 'move',
                  child: Text('Mover a...'),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'Eliminar',
                    style: TextStyle(color: AppColors.error),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
