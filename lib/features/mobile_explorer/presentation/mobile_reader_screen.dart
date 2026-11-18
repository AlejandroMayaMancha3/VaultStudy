import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/type_badge.dart';
import '../../notes_editor/presentation/vault_note_pane.dart';
import '../../pdf_viewer/application/pdf_highlight_utils.dart';
import '../../pdf_viewer/presentation/vault_pdf_viewer.dart';
import '../../vault_tree/application/vault_providers.dart';
import '../../vault_tree/domain/vault_item.dart';
import '../../vault_tree/presentation/vault_dialogs.dart';
import '../../workspace_desktop/application/workspace_persistence.dart';

/// Mobile (< 900px) reader screen with sibling-file chips and floating study capsule.
class MobileReaderScreen extends ConsumerStatefulWidget {
  const MobileReaderScreen({
    super.key,
    required this.initialItemId,
    this.initialPage = 1,
  });

  final String initialItemId;
  final int initialPage;

  @override
  ConsumerState<MobileReaderScreen> createState() => _MobileReaderScreenState();
}

class _MobileReaderScreenState extends ConsumerState<MobileReaderScreen> {
  late String _activeItemId;
  late int _activePage;
  final GlobalKey<VaultPdfViewerState> _pdfKey =
      GlobalKey<VaultPdfViewerState>();

  bool _showNoteSearch = false;
  String _noteSearchQuery = '';
  final TextEditingController _noteSearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _activeItemId = widget.initialItemId;
    _activePage = widget.initialPage;
  }

  void _saveMobileLocation(String itemId, int page) {
    final next = WorkspacePersistence.cachedMobileState.copyWith(
      activeReaderItemId: itemId,
      activeReaderPage: page,
    );
    unawaited(WorkspacePersistence.saveMobileState(next));
  }

  @override
  void dispose() {
    _noteSearchController.dispose();
    super.dispose();
  }

  Future<void> _openMobilePageJumpDialog() async {
    final pdfState = _pdfKey.currentState;
    if (pdfState == null || pdfState.totalPages <= 0) return;
    final total = pdfState.totalPages;
    final currentText = '${pdfState.currentPage}';
    final controller = TextEditingController(text: currentText)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: currentText.length,
      );

    final rawValue = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceLow,
        title: const Text('Ir a página'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(5),
          ],
          decoration: InputDecoration(
            hintText: 'Ej: 15',
            suffixText: '/ $total',
            helperText: 'Introduce un número entre 1 y $total',
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Ir'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (rawValue == null) return;
    final target = parsePdfPageInput(rawValue, totalPages: total);
    if (target == null) return;
    await pdfState.goToPageNumber(target);
  }

  Future<void> _openMobileZoomDialog() async {
    final pdfState = _pdfKey.currentState;
    if (pdfState == null) return;
    final currentPct = '${(pdfState.currentZoom * 100).round()}';
    final controller = TextEditingController(text: currentPct)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: currentPct.length,
      );

    final rawValue = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceLow,
        title: const Text('Zoom del PDF (%)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,%]')),
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(
                hintText: 'Ej: 120',
                suffixText: '%',
                helperText: 'Rango permitido: 25% – 500%',
              ),
              onSubmitted: (value) => Navigator.pop(ctx, value),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ActionChip(
                  label: const Text('100%'),
                  onPressed: () => Navigator.pop(ctx, '__100__'),
                ),
                ActionChip(
                  label: const Text('Al ancho'),
                  onPressed: () => Navigator.pop(ctx, '__fit_width__'),
                ),
                ActionChip(
                  label: const Text('Página completa'),
                  onPressed: () => Navigator.pop(ctx, '__fit_page__'),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (rawValue == null) return;
    if (rawValue == '__100__') {
      await pdfState.setZoomPercent(100);
      return;
    }
    if (rawValue == '__fit_width__') {
      await pdfState.fitPageWidth();
      return;
    }
    if (rawValue == '__fit_page__') {
      await pdfState.fitFullPage();
      return;
    }
    final parsedScale = parsePdfZoomPercent(rawValue);
    if (parsedScale == null) return;
    await pdfState.setZoomPercent(parsedScale * 100.0);
  }

  Future<void> _openQuickNoteSheet(
    List<VaultItem> allItems,
    VaultItem currentItem,
  ) async {
    final readOnly = ref.read(examReadOnlyProvider).value ?? false;
    if (readOnly) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Modo Solo Lectura de examen activo.'),
        ),
      );
      return;
    }

    final siblingNote = allItems
        .where(
          (e) =>
              e.parentId == currentItem.parentId &&
              e.type == VaultItemType.note,
        )
        .firstOrNull;

    final noteController = TextEditingController();
    final isCodeController = ValueNotifier<bool>(false);

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: ValueListenableBuilder<bool>(
          valueListenable: isCodeController,
          builder: (_, isCode, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.edit_note_rounded,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      siblingNote != null
                          ? 'Añadir a "${siblingNote.title}"'
                          : 'Crear Nota Rápida en este tema',
                      style: AppTypography.headlineSm,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                autofocus: true,
                maxLines: 4,
                style: isCode ? AppTypography.monoMd : AppTypography.bodyMd,
                decoration: InputDecoration(
                  hintText: isCode
                      ? 'Pega aquí código o consulta SQL...'
                      : 'Escribe una duda, fórmula o apunte rápido...',
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilterChip(
                    selected: isCode,
                    label: const Text('Bloque código'),
                    onSelected: (v) => isCodeController.value = v,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Guardar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final text = noteController.text.trim();
    final asCode = isCodeController.value;
    noteController.dispose();
    isCodeController.dispose();

    if (confirmed != true || text.isEmpty) return;

    final formatted = asCode
        ? '\n```sql\n$text\n```\n'
        : '\n> [!TIP]\n> **Nota rápida:** $text\n';

    if (siblingNote != null) {
      await ref.read(vaultItemsProvider.notifier).updateNoteContent(
            id: siblingNote.id,
            title: siblingNote.title,
            contentMd: '${siblingNote.contentMd}$formatted',
          );
    } else {
      await ref.read(vaultItemsProvider.notifier).createNote(
            title: 'Notas rápidas',
            parentId: currentItem.parentId,
            initialContent: '## Notas rápidas\n$formatted',
          );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nota rápida guardada en la bóveda local.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final allItems = ref.watch(vaultItemsProvider).value ?? [];
    final item = allItems.where((e) => e.id == _activeItemId).firstOrNull;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Archivo no encontrado')),
        body: const Center(child: Text('Este elemento ya no existe.')),
      );
    }

    final siblings = allItems
        .where(
          (e) => e.parentId == item.parentId && e.type != VaultItemType.folder,
        )
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    final parent = item.parentId != null
        ? allItems.where((e) => e.id == item.parentId).firstOrNull
        : null;
    final grandParent = parent?.parentId != null
        ? allItems.where((e) => e.id == parent!.parentId).firstOrNull
        : null;

    final contextBreadcrumb = [
      if (parent != null) parent.title,
      if (grandParent != null) grandParent.title,
    ].join(' / ');

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Single unified mobile reader header
                Container(
                  height: 60,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: 0.94),
                    border: Border(
                      bottom: BorderSide(
                        color: AppColors.outlineVariant.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      InkWell(
                        onTap: () => Navigator.pop(context),
                        borderRadius: BorderRadius.circular(
                          AppBreakpoints.radiusSm,
                        ),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainer,
                            borderRadius: BorderRadius.circular(
                              AppBreakpoints.radiusSm,
                            ),
                          ),
                          child: const Icon(
                            Icons.arrow_back_rounded,
                            size: 20,
                            color: AppColors.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (contextBreadcrumb.isNotEmpty)
                              Text(
                                contextBreadcrumb.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.badgeMono.copyWith(
                                  color: AppColors.primary,
                                ),
                              ),
                            const SizedBox(height: 2),
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.headlineSm.copyWith(
                                fontSize: 15.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (item.type.isDocument) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: InkWell(
                            onTap: _openMobilePageJumpDialog,
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceContainer,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: AppColors.outlineVariant.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              child: Text(
                                '${_pdfKey.currentState?.currentPage ?? _activePage}/${_pdfKey.currentState?.totalPages ?? 1}',
                                style: AppTypography.monoSm.copyWith(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: InkWell(
                            onTap: _openMobileZoomDialog,
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceContainer,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: AppColors.outlineVariant.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              child: Text(
                                '${((_pdfKey.currentState?.currentZoom ?? 1.0) * 100).round()}%',
                                style: AppTypography.monoSm.copyWith(
                                  color: AppColors.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      IconButton(
                        tooltip: item.isPinned
                            ? 'Desfijar de examen'
                            : 'Fijar para examen',
                        icon: Icon(
                          item.isPinned
                              ? Icons.push_pin_rounded
                              : Icons.push_pin_outlined,
                          size: 20,
                          color: item.isPinned
                              ? AppColors.secondary
                              : AppColors.onSurfaceVariant,
                        ),
                        onPressed: () => ref
                            .read(vaultItemsProvider.notifier)
                            .togglePin(item.id, !item.isPinned),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(
                          Icons.more_vert_rounded,
                          color: AppColors.onSurfaceVariant,
                        ),
                        onSelected: (value) async {
                          if (value == 'rename') {
                            await VaultDialogs.showRenameDialog(
                              context,
                              ref,
                              item,
                            );
                          } else if (value == 'toggle_book' &&
                              item.type.isDocument) {
                            await ref
                                .read(vaultItemsProvider.notifier)
                                .toggleDocumentType(
                                  item.id,
                                  item.type == VaultItemType.book
                                      ? VaultItemType.pdf
                                      : VaultItemType.book,
                                );
                          } else if (value == 'delete') {
                            final deleted =
                                await VaultDialogs.showDeleteConfirmDialog(
                              context,
                              ref,
                              item,
                            );
                            if (deleted && context.mounted) {
                              Navigator.pop(context);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Renombrar'),
                          ),
                          if (item.type.isDocument)
                            PopupMenuItem(
                              value: 'toggle_book',
                              child: Text(
                                item.type == VaultItemType.book
                                    ? 'Marcar como PDF'
                                    : 'Marcar como LIBRO',
                              ),
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
                // Sibling switcher chips
                if (siblings.length > 1)
                  Container(
                    height: 46,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      itemCount: siblings.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, idx) {
                        final sib = siblings[idx];
                        final active = sib.id == item.id;
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _activeItemId = sib.id;
                              _activePage = 1;
                              _showNoteSearch = false;
                              _noteSearchQuery = '';
                            });
                            _saveMobileLocation(sib.id, 1);
                          },
                          borderRadius: BorderRadius.circular(
                            AppBreakpoints.radiusSm,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: active
                                  ? AppColors.primary
                                  : AppColors.surfaceLow,
                              borderRadius: BorderRadius.circular(
                                AppBreakpoints.radiusSm,
                              ),
                              border: Border.all(
                                color: active
                                    ? AppColors.primary
                                    : AppColors.outlineVariant.withValues(
                                        alpha: 0.4,
                                      ),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TypeBadge(type: sib.type, inverted: active),
                                const SizedBox(width: 6),
                                Text(
                                  sib.title,
                                  style: AppTypography.monoSm.copyWith(
                                    color: active
                                        ? AppColors.surfaceLowest
                                        : AppColors.onSurfaceVariant,
                                    fontWeight: active
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (_showNoteSearch && item.type == VaultItemType.note)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    color: AppColors.surfaceContainer,
                    child: Row(
                      children: [
                        const Icon(
                          Icons.search_rounded,
                          size: 16,
                          color: AppColors.secondary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _noteSearchController,
                            autofocus: true,
                            decoration: const InputDecoration(
                              hintText: 'Resaltar palabra en el apunte...',
                              isDense: true,
                            ),
                            onChanged: (v) =>
                                setState(() => _noteSearchQuery = v),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() {
                            _showNoteSearch = false;
                            _noteSearchQuery = '';
                            _noteSearchController.clear();
                          }),
                        ),
                      ],
                    ),
                  ),
                // Main Document or Note Content
                Expanded(
                  child: item.type.isDocument
                      ? VaultPdfViewer(
                          key: _pdfKey,
                          item: item,
                          initialPage: _activePage,
                          showTopToolbar: false,
                          showBottomCapsule: false,
                          onPageChanged: (page) {
                            _activePage = page;
                            _saveMobileLocation(item.id, page);
                          },
                          onHistoryChanged: () {
                            if (mounted) setState(() {});
                          },
                        )
                      : VaultNotePane(
                          key: ValueKey('mobile_note_${item.id}'),
                          item: item,
                          showTopBar: false,
                          searchHighlight: _noteSearchQuery,
                        ),
                ),
              ],
            ),
            // Floating bottom capsule (Buscar, Subrayar, Nota rápida)
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHighest.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(
                        AppBreakpoints.radiusMd,
                      ),
                      border: Border.all(
                        color: AppColors.outlineVariant.withValues(alpha: 0.7),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _BottomToolButton(
                          icon: Icons.search_rounded,
                          label: 'Buscar',
                          color: AppColors.onSurface,
                          onTap: () {
                            if (item.type.isDocument) {
                              _pdfKey.currentState?.toggleInDocSearch();
                            } else {
                              setState(
                                () => _showNoteSearch = !_showNoteSearch,
                              );
                            }
                          },
                        ),
                        if (item.type.isDocument &&
                            (_pdfKey.currentState?.hasSelection ?? false)) ...[
                          _VerticalSep(),
                          _BottomToolButton(
                            icon: Icons.content_copy_rounded,
                            label: 'Copiar',
                            color: AppColors.secondary,
                            onTap: () =>
                                _pdfKey.currentState?.copySelectedText(),
                          ),
                        ],
                        _VerticalSep(),
                        _BottomToolButton(
                          icon: Icons.highlight_rounded,
                          label: 'Marcador',
                          color: (_pdfKey.currentState?.toolMode ==
                                  PdfMarkerTool.highlight)
                              ? AppColors.primary
                              : AppColors.secondary,
                          onTap: () {
                            if (item.type.isDocument) {
                              _pdfKey.currentState?.triggerHighlightAction();
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Usa "Nota rápida" para añadir un bloque destacado en esta nota.',
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                        if (item.type.isDocument &&
                            (_pdfKey.currentState?.canUndo ?? false)) ...[
                          _VerticalSep(),
                          _BottomToolButton(
                            icon: Icons.undo_rounded,
                            label: 'Deshacer',
                            color: AppColors.secondary,
                            onTap: () => _pdfKey.currentState?.undo(),
                          ),
                        ],
                        _VerticalSep(),
                        _BottomToolButton(
                          icon: Icons.edit_note_rounded,
                          label: 'Nota rápida',
                          color: AppColors.primary,
                          onTap: () => _openQuickNoteSheet(allItems, item),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerticalSep extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      color: AppColors.outlineVariant.withValues(alpha: 0.5),
    );
  }
}

class _BottomToolButton extends StatelessWidget {
  const _BottomToolButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: AppTypography.badgeMono.copyWith(
                color: AppColors.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
