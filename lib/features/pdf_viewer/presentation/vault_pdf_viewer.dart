import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart' hide PdfAnnotation;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants/app_breakpoints.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/pdf/pdf_runtime_initializer.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../cloud_sync/application/cloud_sync_service.dart';
import '../../vault_tree/application/vault_providers.dart';
import '../../vault_tree/domain/vault_item.dart';
import '../../workspace_desktop/application/workspace_state.dart';
import '../application/pdf_highlight_utils.dart';

const _uuid = Uuid();

enum PdfMarkerTool { browse, highlight, erase }

/// Native PDFium viewer (`pdfrx`) with pagination, zoom, rotation,
/// immediate selection highlighting, direct drag-to-highlight marker tool,
/// single-tap eraser, and full Undo/Redo history.
class VaultPdfViewer extends ConsumerStatefulWidget {
  const VaultPdfViewer({
    super.key,
    required this.item,
    this.initialPage = 1,
    this.showTopToolbar = true,
    this.showBottomCapsule = true,
    this.onPageChanged,
    this.onHistoryChanged,
  });

  final VaultItem item;
  final int initialPage;
  final bool showTopToolbar;
  final bool showBottomCapsule;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onHistoryChanged;

  @override
  ConsumerState<VaultPdfViewer> createState() => VaultPdfViewerState();
}

class VaultPdfViewerState extends ConsumerState<VaultPdfViewer> {
  final PdfViewerController _controller = PdfViewerController();
  late PdfTextSearcher _textSearcher;
  final FocusNode _inDocSearchFocus = FocusNode();
  final TextEditingController _inDocSearchController = TextEditingController();

  final AnnotationHistoryStack _history = AnnotationHistoryStack();

  String? _resolvedPath;
  bool _loadingPath = true;
  String? _pathError;

  int _currentPage = 1;
  int _totalPages = 1;
  double _zoom = 1.0;
  int _rotationTurns = 0;

  PdfMarkerTool _toolMode = PdfMarkerTool.browse;
  String _selectedColorHex = PdfHighlightPalette.options.first.hex;
  bool _showSearchBar = false;
  PdfTextSelection? _activeSelection;

  // Embedded PDF outline & persistent page bookmarks
  List<PdfOutlineNode> _outlineNodes = const [];
  List<int> _bookmarkedPages = [];
  bool _showOutlineDrawer = false;
  int _outlineTab = 0; // 0 = PDF TOC, 1 = Bookmarks

  // Live stroke state while dragging in PdfMarkerTool.highlight
  int? _dragPageNumber;
  List<Offset> _dragPoints = [];

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;
  PdfMarkerTool get toolMode => _toolMode;
  String get _bookmarksPrefsKey => 'vaultstudy_pdf_bookmarks_${widget.item.id}';

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _textSearcher = PdfTextSearcher(_controller)
      ..addListener(() {
        if (mounted) setState(() {});
      });
    _controller.addListener(_onControllerChanged);
    _resolveFile();
    _loadBookmarks();
  }

  @override
  void didUpdateWidget(covariant VaultPdfViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.filePath != widget.item.filePath) {
      _currentPage = widget.initialPage;
      _rotationTurns = 0;
      _activeSelection = null;
      _outlineNodes = const [];
      _bookmarkedPages = [];
      _dragPageNumber = null;
      _dragPoints = [];
      _history.clear();
      _notifyHistory();
      _resolveFile();
      _loadBookmarks();
    } else if (oldWidget.initialPage != widget.initialPage &&
        widget.initialPage != _currentPage &&
        _controller.isReady) {
      _controller.goToPage(pageNumber: widget.initialPage);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _textSearcher.dispose();
    _inDocSearchController.dispose();
    _inDocSearchFocus.dispose();
    super.dispose();
  }

  void _notifyHistory() {
    widget.onHistoryChanged?.call();
  }

  void _onControllerChanged() {
    if (!mounted || !_controller.isReady) return;
    final nextZoom = _controller.currentZoom;
    if ((nextZoom - _zoom).abs() > 0.01) {
      setState(() => _zoom = nextZoom);
    }
  }

  Future<void> _resolveFile() async {
    setState(() {
      _loadingPath = true;
      _pathError = null;
    });
    final stored = widget.item.filePath;
    if (stored == null || stored.isEmpty) {
      setState(() {
        _loadingPath = false;
        _pathError = 'Este documento no tiene un archivo PDF asociado.';
      });
      return;
    }
    try {
      final results = await Future.wait<Object?>([
        DatabaseHelper.instance.resolveVaultFilePath(stored),
        PdfRuntimeInitializer.ensureInitialized(),
      ]);
      final path = results[0]! as String;
      if (!mounted) return;
      setState(() {
        _resolvedPath = path;
        _loadingPath = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPath = false;
        _pathError = 'No se pudo localizar el archivo: $e';
      });
    }
  }

  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_bookmarksPrefsKey) ?? const <String>[];
    final pages = raw
        .map(int.tryParse)
        .whereType<int>()
        .where((p) => p >= 1)
        .toSet()
        .toList()
      ..sort();
    if (mounted) {
      setState(() => _bookmarkedPages = pages);
    }
  }

  Future<void> _persistBookmarks(List<int> pages) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _bookmarksPrefsKey,
      pages.map((p) => p.toString()).toList(),
    );
  }

  Future<void> toggleBookmarkCurrentPage() async {
    final page = _currentPage;
    final next = List<int>.of(_bookmarkedPages);
    final added = !next.contains(page);
    if (added) {
      next.add(page);
      next.sort();
    } else {
      next.remove(page);
    }
    setState(() => _bookmarkedPages = next);
    await _persistBookmarks(next);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added
                ? 'Marcador guardado en página $page'
                : 'Marcador quitado de página $page',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _removeBookmarkPage(int page) async {
    final next = _bookmarkedPages.where((p) => p != page).toList();
    setState(() => _bookmarkedPages = next);
    await _persistBookmarks(next);
  }

  void toggleOutlinePanel() {
    setState(() => _showOutlineDrawer = !_showOutlineDrawer);
  }

  void openInDocSearch() {
    setState(() => _showSearchBar = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inDocSearchFocus.requestFocus();
    });
  }

  void toggleInDocSearch() {
    setState(() {
      _showSearchBar = !_showSearchBar;
      if (!_showSearchBar) {
        _textSearcher.resetTextSearch();
        _inDocSearchController.clear();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _inDocSearchFocus.requestFocus();
        });
      }
    });
  }

  Future<bool> _ensureWritable() async {
    final readOnly = ref.read(examReadOnlyProvider).value ?? false;
    if (readOnly) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Modo Solo Lectura de examen activo.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return false;
    }
    return true;
  }

  bool get _hasLiveSelection {
    if (_controller.isReady && _controller.textSelectionDelegate.hasSelectedText) {
      return true;
    }
    return _activeSelection?.hasSelectedText ?? false;
  }

  /// Immediately highlights any active text selection (bypassing pdfrx's 300ms
  /// selection-change debounce), or toggles direct drag-to-highlight mode.
  Future<void> triggerHighlightAction() async {
    if (_hasLiveSelection) {
      final delegate = _controller.isReady
          ? _controller.textSelectionDelegate
          : _activeSelection!;
      await _saveCurrentSelectionAsHighlight(delegate);
      return;
    }

    if (!await _ensureWritable()) return;

    setState(() {
      _toolMode = _toolMode == PdfMarkerTool.highlight
          ? PdfMarkerTool.browse
          : PdfMarkerTool.highlight;
      _dragPageNumber = null;
      _dragPoints = [];
    });
    _notifyHistory();
  }

  void setToolMode(PdfMarkerTool mode) {
    setState(() {
      _toolMode = mode;
      _dragPageNumber = null;
      _dragPoints = [];
    });
    _notifyHistory();
  }

  Future<void> _saveCurrentSelectionAsHighlight(
    PdfTextSelection selection,
  ) async {
    if (!await _ensureWritable()) return;

    final ranges = await selection.getSelectedTextRanges();
    if (ranges.isEmpty) return;

    final repo = ref.read(vaultRepositoryProvider);
    final pages = _controller.isReady ? _controller.pages : <PdfPage>[];
    final created = <PdfAnnotation>[];

    for (final range in ranges) {
      final pageIdx = range.pageNumber - 1;
      if (pageIdx < 0 || pageIdx >= pages.length) continue;
      final page = pages[pageIdx];

      final rawPdfRects = range.pageText.fragments.isEmpty
          ? [range.bounds]
          : range
              .enumerateFragmentBoundingRects()
              .map((f) => f.bounds)
              .toList();

      final normalizedRaw = rawPdfRects.map((pdfRect) {
        final r = pdfRect.toRect(
          page: page,
          scaledPageSize: const Size(1.0, 1.0),
        );
        return NormalizedRect(
          left: r.left.clamp(0.0, 1.0),
          top: r.top.clamp(0.0, 1.0),
          right: r.right.clamp(0.0, 1.0),
          bottom: r.bottom.clamp(0.0, 1.0),
        );
      }).toList();

      final merged = mergeLineRects(normalizedRaw);
      if (merged.isEmpty) continue;

      final annotation = PdfAnnotation(
        id: _uuid.v4(),
        itemId: widget.item.id,
        pageNumber: range.pageNumber,
        rects: merged,
        selectedText: range.text.trim(),
        colorHex: _selectedColorHex,
        createdAt: DateTime.now(),
      );
      await repo.addAnnotation(annotation);
      created.add(annotation);
    }

    if (created.isEmpty) return;
    _history.recordAdd(created);
    if (_controller.isReady) {
      await _controller.textSelectionDelegate.clearTextSelection();
    }
    ref.invalidate(pdfAnnotationsProvider(widget.item.id));
    ref.read(cloudSyncProvider.notifier).scheduleAutoSync();
    if (mounted) {
      setState(() => _activeSelection = null);
      _notifyHistory();
    }
  }

  Future<void> _finishStrokeHighlight(PdfPage page, List<Offset> points) async {
    if (points.isEmpty) return;
    if (!await _ensureWritable()) return;

    final rawStrokeRects = strokeToNormalizedRects(points);
    if (rawStrokeRects.isEmpty) return;

    // Attempt smart snap to selectable PDF characters/fragments under the stroke.
    var finalRects = rawStrokeRects;
    var capturedText = '';
    try {
      final pageText = await page.loadStructuredText();
      if (pageText.fragments.isNotEmpty) {
        final matchedRects = <NormalizedRect>[];
        final textBuf = StringBuffer();

        bool intersectsStroke(Rect r) {
          const vPad = 0.004;
          for (final s in rawStrokeRects) {
            final overlapX =
                math.min(r.right, s.right) - math.max(r.left, s.left);
            final overlapY =
                math.min(r.bottom, s.bottom + vPad) -
                math.max(r.top, s.top - vPad);
            if (overlapX > 0.002 && overlapY > 0.002) {
              return true;
            }
          }
          return false;
        }

        for (final frag in pageText.fragments) {
          final fragRect = frag.bounds.toRect(
            page: page,
            scaledPageSize: const Size(1.0, 1.0),
          );
          if (!intersectsStroke(fragRect)) continue;

          final fragText = frag.text;
          if (frag.charRects.length == fragText.length) {
            final charsBuf = StringBuffer();
            for (var i = 0; i < frag.charRects.length; i++) {
              final ch = fragText[i];
              if (ch.trim().isEmpty) {
                if (charsBuf.isNotEmpty) charsBuf.write(' ');
                continue;
              }
              final cr = frag.charRects[i].toRect(
                page: page,
                scaledPageSize: const Size(1.0, 1.0),
              );
              if (intersectsStroke(cr)) {
                charsBuf.write(ch);
                matchedRects.add(
                  NormalizedRect(
                    left: cr.left.clamp(0.0, 1.0),
                    top: cr.top.clamp(0.0, 1.0),
                    right: cr.right.clamp(0.0, 1.0),
                    bottom: cr.bottom.clamp(0.0, 1.0),
                  ),
                );
              }
            }
            final slice = charsBuf.toString().trim();
            if (slice.isNotEmpty) {
              if (textBuf.isNotEmpty) textBuf.write(' ');
              textBuf.write(slice);
            }
          } else {
            final cleaned = fragText.trim();
            if (cleaned.isNotEmpty) {
              if (textBuf.isNotEmpty) textBuf.write(' ');
              textBuf.write(cleaned);
              matchedRects.add(
                NormalizedRect(
                  left: fragRect.left.clamp(0.0, 1.0),
                  top: fragRect.top.clamp(0.0, 1.0),
                  right: fragRect.right.clamp(0.0, 1.0),
                  bottom: fragRect.bottom.clamp(0.0, 1.0),
                ),
              );
            }
          }
        }

        final snapped = mergeLineRects(matchedRects);
        if (snapped.isNotEmpty) {
          finalRects = snapped;
          capturedText = textBuf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
        }
      }
    } catch (_) {
      // Fallback cleanly to exact painted stroke rects for scanned/diagram pages.
    }

    final annotation = PdfAnnotation(
      id: _uuid.v4(),
      itemId: widget.item.id,
      pageNumber: page.pageNumber,
      rects: finalRects,
      selectedText: capturedText,
      colorHex: _selectedColorHex,
      createdAt: DateTime.now(),
    );

    await ref.read(vaultRepositoryProvider).addAnnotation(annotation);
    _history.recordAdd([annotation]);
    ref.invalidate(pdfAnnotationsProvider(widget.item.id));
    ref.read(cloudSyncProvider.notifier).scheduleAutoSync();
    if (mounted) {
      setState(() {});
      _notifyHistory();
    }
  }

  Future<void> _deleteSingleAnnotation(PdfAnnotation ann) async {
    if (!await _ensureWritable()) return;
    await ref.read(vaultRepositoryProvider).deleteAnnotation(ann.id);
    _history.recordDelete([ann]);
    ref.invalidate(pdfAnnotationsProvider(widget.item.id));
    ref.read(cloudSyncProvider.notifier).scheduleAutoSync();
    if (mounted) {
      setState(() {});
      _notifyHistory();
    }
  }

  Future<void> undo() async {
    if (!_history.canUndo) return;
    if (!await _ensureWritable()) return;

    final action = _history.popUndo();
    if (action == null) return;

    final repo = ref.read(vaultRepositoryProvider);
    for (final ann in action.annotations) {
      if (action.kind == AnnotationActionKind.add) {
        await repo.deleteAnnotation(ann.id);
      } else {
        await repo.addAnnotation(ann);
      }
    }

    ref.invalidate(pdfAnnotationsProvider(widget.item.id));
    ref.read(cloudSyncProvider.notifier).scheduleAutoSync();
    if (mounted) {
      setState(() {});
      _notifyHistory();
    }
  }

  Future<void> redo() async {
    if (!_history.canRedo) return;
    if (!await _ensureWritable()) return;

    final action = _history.popRedo();
    if (action == null) return;

    final repo = ref.read(vaultRepositoryProvider);
    for (final ann in action.annotations) {
      if (action.kind == AnnotationActionKind.add) {
        await repo.addAnnotation(ann);
      } else {
        await repo.deleteAnnotation(ann.id);
      }
    }

    ref.invalidate(pdfAnnotationsProvider(widget.item.id));
    ref.read(cloudSyncProvider.notifier).scheduleAutoSync();
    if (mounted) {
      setState(() {});
      _notifyHistory();
    }
  }

  Future<void> _showAnnotationsSheet(List<PdfAnnotation> annotations) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.format_color_fill_rounded,
                      color: AppColors.primary,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Subrayados en ${widget.item.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.headlineSm,
                      ),
                    ),
                    if (_history.canUndo)
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          undo();
                        },
                        icon: const Icon(Icons.undo_rounded, size: 16),
                        label: const Text('Deshacer'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (annotations.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'No hay subrayados guardados todavía. Activa "Marcador" y arrastra sobre el PDF, o selecciona texto y pulsa "Subrayar".',
                      style: AppTypography.bodySm,
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: annotations.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, idx) {
                        final ann = annotations[idx];
                        final annColor =
                            PdfHighlightPalette.colorFromHex(ann.colorHex);
                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainer,
                            borderRadius: BorderRadius.circular(
                              AppBreakpoints.radiusMd,
                            ),
                            border: Border.all(
                              color: annColor.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 4,
                                height: 34,
                                margin: const EdgeInsets.only(right: 10),
                                decoration: BoxDecoration(
                                  color: annColor,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              Expanded(
                                child: InkWell(
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    if (_controller.isReady) {
                                      _controller.goToPage(
                                        pageNumber: ann.pageNumber,
                                      );
                                    }
                                  },
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Pág ${ann.pageNumber}',
                                        style: AppTypography.badgeMono.copyWith(
                                          color: annColor,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        ann.selectedText.isEmpty
                                            ? 'Región subrayada con marcador'
                                            : ann.selectedText,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTypography.bodySm.copyWith(
                                          color: AppColors.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Eliminar subrayado',
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                  color: AppColors.error,
                                ),
                                onPressed: () async {
                                  await _deleteSingleAnnotation(ann);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHighlightRibbon() {
    final isErase = _toolMode == PdfMarkerTool.erase;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        border: Border(
          bottom: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Icon(
              isErase ? Icons.auto_fix_off_rounded : Icons.draw_rounded,
              size: 15,
              color: isErase
                  ? AppColors.error
                  : PdfHighlightPalette.colorFromHex(_selectedColorHex),
            ),
            const SizedBox(width: 6),
            Text(
              isErase
                  ? 'BORRADOR: toca un subrayado para quitarlo'
                  : 'MARCADOR: arrastra sobre el PDF',
              style: AppTypography.badgeMono.copyWith(
                color: isErase ? AppColors.error : AppColors.onSurface,
              ),
            ),
            const SizedBox(width: 10),
            for (final opt in PdfHighlightPalette.options)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: () => setState(() {
                    _selectedColorHex = opt.hex;
                    _toolMode = PdfMarkerTool.highlight;
                  }),
                  borderRadius: BorderRadius.circular(999),
                  child: Tooltip(
                    message: opt.label,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: opt.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: (!isErase && _selectedColorHex == opt.hex)
                              ? AppColors.onSurface
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 4),
            _RibbonToggleChip(
              icon: Icons.auto_fix_normal_rounded,
              label: 'Borrador',
              active: isErase,
              activeColor: AppColors.error,
              onTap: () => setToolMode(
                isErase ? PdfMarkerTool.highlight : PdfMarkerTool.erase,
              ),
            ),
            const SizedBox(width: 6),
            _RibbonToggleChip(
              icon: Icons.undo_rounded,
              label: 'Deshacer',
              active: _history.canUndo,
              activeColor: AppColors.secondary,
              enabled: _history.canUndo,
              onTap: undo,
            ),
            const SizedBox(width: 4),
            _RibbonToggleChip(
              icon: Icons.redo_rounded,
              label: 'Rehacer',
              active: _history.canRedo,
              activeColor: AppColors.secondary,
              enabled: _history.canRedo,
              onTap: redo,
            ),
            const SizedBox(width: 6),
            _RibbonToggleChip(
              icon: Icons.check_rounded,
              label: 'Listo',
              active: true,
              activeColor: AppColors.primary,
              onTap: () => setToolMode(PdfMarkerTool.browse),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final annotations =
        ref.watch(pdfAnnotationsProvider(widget.item.id)).value ?? [];
    final hasSelection = _hasLiveSelection;
    final showRibbon = _toolMode != PdfMarkerTool.browse;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
          if (!_inDocSearchFocus.hasFocus) undo();
        },
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () {
          if (!_inDocSearchFocus.hasFocus) undo();
        },
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): () {
          if (!_inDocSearchFocus.hasFocus) redo();
        },
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): () {
          if (!_inDocSearchFocus.hasFocus) redo();
        },
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          meta: true,
          shift: true,
        ): () {
          if (!_inDocSearchFocus.hasFocus) redo();
        },
      },
      child: Container(
        color: AppColors.surfaceLowest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showTopToolbar)
              Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLow,
                  border: Border(
                    bottom: BorderSide(
                      color: AppColors.outlineVariant.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      widget.item.type == VaultItemType.book
                          ? 'LIBRO // VISOR'
                          : 'DOC_VIEWER // PDF',
                      style: AppTypography.badgeMono.copyWith(
                        color: widget.item.type == VaultItemType.book
                            ? AppColors.bookAmber
                            : AppColors.error,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('|', style: AppTypography.monoSm),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.item.title,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.monoSm.copyWith(
                          color: AppColors.onSurface,
                        ),
                      ),
                    ),
                    if (hasSelection)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InkWell(
                          onTap: triggerHighlightAction,
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: PdfHighlightPalette.colorFromHex(
                                _selectedColorHex,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'SUBRAYAR',
                              style: AppTypography.badgeMono.copyWith(
                                color: AppColors.onPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Deshacer subrayado (Ctrl+Z)',
                      icon: Icon(
                        Icons.undo_rounded,
                        size: 16,
                        color: _history.canUndo
                            ? AppColors.secondary
                            : AppColors.outlineVariant,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      onPressed: _history.canUndo ? undo : null,
                    ),
                    IconButton(
                      tooltip: 'Rehacer subrayado (Ctrl+Y)',
                      icon: Icon(
                        Icons.redo_rounded,
                        size: 16,
                        color: _history.canRedo
                            ? AppColors.secondary
                            : AppColors.outlineVariant,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      onPressed: _history.canRedo ? redo : null,
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => _showAnnotationsSheet(annotations),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${annotations.length} SUBRAYADOS',
                          style: AppTypography.badgeMono.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: _bookmarkedPages.contains(_currentPage)
                          ? 'Quitar marcador de pág $_currentPage'
                          : 'Guardar marcador en pág $_currentPage',
                      icon: Icon(
                        _bookmarkedPages.contains(_currentPage)
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        size: 17,
                        color: _bookmarkedPages.contains(_currentPage)
                            ? AppColors.bookAmber
                            : AppColors.onSurfaceVariant,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: toggleBookmarkCurrentPage,
                    ),
                    IconButton(
                      tooltip: 'Índice PDF y Marcadores',
                      icon: Icon(
                        Icons.toc_rounded,
                        size: 17,
                        color: _showOutlineDrawer
                            ? AppColors.primary
                            : AppColors.onSurfaceVariant,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: toggleOutlinePanel,
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      tooltip: 'Buscar en este PDF (Ctrl+F)',
                      icon: Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: _showSearchBar
                            ? AppColors.secondary
                            : AppColors.onSurfaceVariant,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: toggleInDocSearch,
                    ),
                  ],
                ),
              ),
            if (showRibbon) _buildHighlightRibbon(),
            if (_showSearchBar)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                        controller: _inDocSearchController,
                        focusNode: _inDocSearchFocus,
                        autofocus: true,
                        style: AppTypography.monoSm.copyWith(
                          color: AppColors.onSurface,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Buscar texto dentro del documento...',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                        ),
                        onChanged: (value) {
                          _textSearcher.startTextSearch(value);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_textSearcher.hasMatches)
                      Text(
                        '${(_textSearcher.currentIndex ?? 0) + 1}/${_textSearcher.matches.length}',
                        style: AppTypography.monoSm.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    IconButton(
                      tooltip: 'Anterior coincidencia',
                      icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                      onPressed: () => _textSearcher.goToPrevMatch(),
                    ),
                    IconButton(
                      tooltip: 'Siguiente coincidencia',
                      icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                      onPressed: () => _textSearcher.goToNextMatch(),
                    ),
                    IconButton(
                      tooltip: 'Cerrar búsqueda',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: toggleInDocSearch,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  if (_showOutlineDrawer) _buildPdfOutlinePanel(),
                  Expanded(
                    child: Stack(
                      children: [
                  if (_loadingPath)
                    const Center(child: CircularProgressIndicator())
                  else if (_pathError != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.picture_as_pdf_outlined,
                              color: AppColors.error,
                              size: 40,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _pathError!,
                              textAlign: TextAlign.center,
                              style: AppTypography.bodyMd,
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: widget.showBottomCapsule ? 64 : 0,
                      ),
                      child: RotatedBox(
                        quarterTurns: _rotationTurns,
                        child: PdfViewer.file(
                          _resolvedPath!,
                          controller: _controller,
                          initialPageNumber: widget.initialPage,
                          params: PdfViewerParams(
                            backgroundColor: AppColors.surfaceLowest,
                            margin: 16,
                            scrollByMouseWheel: 0.25,
                            enableKeyboardNavigation: true,
                            pagePaintCallbacks: [
                              _textSearcher.pageTextMatchPaintCallback,
                            ],
                            customizeContextMenuItems: (params, items) {
                              if (params.textSelectionDelegate.hasSelectedText) {
                                items.insert(
                                  0,
                                  ContextMenuButtonItem(
                                    label: 'Subrayar',
                                    onPressed: () {
                                      params.dismissContextMenu();
                                      _saveCurrentSelectionAsHighlight(
                                        params.textSelectionDelegate,
                                      );
                                    },
                                  ),
                                );
                              }
                            },
                            textSelectionParams: PdfTextSelectionParams(
                              enabled: _toolMode == PdfMarkerTool.browse,
                              onTextSelectionChange: (sel) {
                                if (mounted) {
                                  setState(() => _activeSelection = sel);
                                }
                              },
                            ),
                            onViewerReady: (document, controller) {
                              if (!mounted) return;
                              final page =
                                  controller.pageNumber ?? widget.initialPage;
                              setState(() {
                                _totalPages = document.pages.length;
                                _currentPage = page;
                                _zoom = controller.currentZoom;
                              });
                              document.loadOutline().then((nodes) {
                                if (mounted) {
                                  setState(() => _outlineNodes = nodes);
                                }
                              }).catchError((_) {});
                            },
                            onPageChanged: (pageNumber) {
                              if (!mounted || pageNumber == null) return;
                              setState(() => _currentPage = pageNumber);
                              ref
                                  .read(workspaceProvider.notifier)
                                  .updateTabPage(widget.item.id, pageNumber);
                              widget.onPageChanged?.call(pageNumber);
                            },
                            pageOverlaysBuilder: (context, pageRect, page) {
                              final pageAnns = annotations
                                  .where(
                                    (a) => a.pageNumber == page.pageNumber,
                                  )
                                  .toList();
                              final isDrawingHere =
                                  _toolMode == PdfMarkerTool.highlight &&
                                  _dragPageNumber == page.pageNumber &&
                                  _dragPoints.isNotEmpty;
                              final liveStrokeRects = isDrawingHere
                                  ? strokeToNormalizedRects(_dragPoints)
                                  : const <NormalizedRect>[];
                              final activeColor = PdfHighlightPalette
                                  .colorFromHex(_selectedColorHex);

                              return [
                                // Saved persistent highlights
                                for (final ann in pageAnns)
                                  for (final r in ann.rects)
                                    Positioned(
                                      left: r.left * pageRect.width,
                                      top: r.top * pageRect.height,
                                      width: ((r.right - r.left) *
                                              pageRect.width)
                                          .clamp(4.0, pageRect.width),
                                      height: ((r.bottom - r.top) *
                                              pageRect.height)
                                          .clamp(4.0, pageRect.height),
                                      child: _toolMode == PdfMarkerTool.erase
                                          ? MouseRegion(
                                              cursor:
                                                  SystemMouseCursors.click,
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: () =>
                                                    _deleteSingleAnnotation(
                                                      ann,
                                                    ),
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: PdfHighlightPalette
                                                        .colorFromHex(
                                                          ann.colorHex,
                                                        )
                                                        .withValues(
                                                          alpha: 0.34,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          3,
                                                        ),
                                                    border: Border.all(
                                                      color: AppColors.error
                                                          .withValues(
                                                            alpha: 0.75,
                                                          ),
                                                      width: 1,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            )
                                          : IgnorePointer(
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: PdfHighlightPalette
                                                      .colorFromHex(
                                                        ann.colorHex,
                                                      )
                                                      .withValues(alpha: 0.30),
                                                  borderRadius:
                                                      BorderRadius.circular(3),
                                                ),
                                              ),
                                            ),
                                    ),
                                // Live drag preview stroke
                                for (final r in liveStrokeRects)
                                  Positioned(
                                    left: r.left * pageRect.width,
                                    top: r.top * pageRect.height,
                                    width: ((r.right - r.left) * pageRect.width)
                                        .clamp(4.0, pageRect.width),
                                    height:
                                        ((r.bottom - r.top) * pageRect.height)
                                            .clamp(4.0, pageRect.height),
                                    child: IgnorePointer(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: activeColor.withValues(
                                            alpha: 0.42,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(3),
                                        ),
                                      ),
                                    ),
                                  ),
                                // Interactive drag surface when Marcador tool is active
                                if (_toolMode == PdfMarkerTool.highlight)
                                  Positioned.fill(
                                    child: Listener(
                                      onPointerSignal:
                                          _controller.handlePointerSignalEvent,
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.precise,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onPanStart: (details) {
                                            if (pageRect.width <= 0 ||
                                                pageRect.height <= 0) {
                                              return;
                                            }
                                            final norm = Offset(
                                              (details.localPosition.dx /
                                                      pageRect.width)
                                                  .clamp(0.0, 1.0),
                                              (details.localPosition.dy /
                                                      pageRect.height)
                                                  .clamp(0.0, 1.0),
                                            );
                                            setState(() {
                                              _dragPageNumber = page.pageNumber;
                                              _dragPoints = [norm];
                                            });
                                          },
                                          onPanUpdate: (details) {
                                            if (_dragPageNumber !=
                                                    page.pageNumber ||
                                                pageRect.width <= 0 ||
                                                pageRect.height <= 0) {
                                              return;
                                            }
                                            final norm = Offset(
                                              (details.localPosition.dx /
                                                      pageRect.width)
                                                  .clamp(0.0, 1.0),
                                              (details.localPosition.dy /
                                                      pageRect.height)
                                                  .clamp(0.0, 1.0),
                                            );
                                            setState(() {
                                              _dragPoints = [
                                                ..._dragPoints,
                                                norm,
                                              ];
                                            });
                                          },
                                          onPanEnd: (_) {
                                            if (_dragPageNumber !=
                                                page.pageNumber) {
                                              return;
                                            }
                                            final points =
                                                List<Offset>.of(_dragPoints);
                                            setState(() {
                                              _dragPageNumber = null;
                                              _dragPoints = [];
                                            });
                                            _finishStrokeHighlight(
                                              page,
                                              points,
                                            );
                                          },
                                          onPanCancel: () {
                                            if (_dragPageNumber ==
                                                page.pageNumber) {
                                              setState(() {
                                                _dragPageNumber = null;
                                                _dragPoints = [];
                                              });
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                              ];
                            },
                          ),
                        ),
                      ),
                    ),
                  // Minimalist floating capsule controls (Bottom Centered)
                  if (widget.showBottomCapsule &&
                      !_loadingPath &&
                      _pathError == null)
                    Positioned(
                      bottom: 14,
                      left: 16,
                      right: 16,
                      child: Center(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHigh.withValues(
                                alpha: 0.96,
                              ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: AppColors.outlineVariant.withValues(
                                  alpha: 0.8,
                                ),
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
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _CapsuleIconBtn(
                                  icon: Icons.chevron_left_rounded,
                                  tooltip: 'Página anterior',
                                  onTap: _currentPage > 1
                                      ? () => _controller.goToPage(
                                            pageNumber: _currentPage - 1,
                                          )
                                      : null,
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  child: Text(
                                    'Pág $_currentPage / $_totalPages',
                                    style: AppTypography.monoSm.copyWith(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                _CapsuleIconBtn(
                                  icon: Icons.chevron_right_rounded,
                                  tooltip: 'Página siguiente',
                                  onTap: _currentPage < _totalPages
                                      ? () => _controller.goToPage(
                                            pageNumber: _currentPage + 1,
                                          )
                                      : null,
                                ),
                                _CapsuleDivider(),
                                _CapsuleIconBtn(
                                  icon: Icons.remove_rounded,
                                  tooltip: 'Reducir zoom',
                                  onTap: () => _controller.zoomDown(),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: Text(
                                    '${(_zoom * 100).round()}%',
                                    style: AppTypography.monoSm.copyWith(
                                      color: AppColors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                _CapsuleIconBtn(
                                  icon: Icons.add_rounded,
                                  tooltip: 'Aumentar zoom',
                                  onTap: () => _controller.zoomUp(),
                                ),
                                _CapsuleDivider(),
                                InkWell(
                                  onTap: triggerHighlightAction,
                                  borderRadius: BorderRadius.circular(999),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: (_toolMode ==
                                                  PdfMarkerTool.highlight ||
                                              hasSelection)
                                          ? PdfHighlightPalette.colorFromHex(
                                              _selectedColorHex,
                                            )
                                          : AppColors.surfaceContainer,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.draw_rounded,
                                          size: 14,
                                          color: (_toolMode ==
                                                      PdfMarkerTool.highlight ||
                                                  hasSelection)
                                              ? AppColors.onPrimary
                                              : AppColors.primary,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          hasSelection
                                              ? 'Subrayar'
                                              : 'Marcador',
                                          style:
                                              AppTypography.badgeMono.copyWith(
                                            color: (_toolMode ==
                                                        PdfMarkerTool
                                                            .highlight ||
                                                    hasSelection)
                                                ? AppColors.onPrimary
                                                : AppColors.onSurface,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                _CapsuleIconBtn(
                                  icon: Icons.undo_rounded,
                                  tooltip: 'Deshacer subrayado (Ctrl+Z)',
                                  onTap: _history.canUndo ? undo : null,
                                ),
                                _CapsuleIconBtn(
                                  icon: Icons.fit_screen_rounded,
                                  tooltip: 'Ajustar al ancho',
                                  onTap: () {
                                    if (!_controller.isReady) return;
                                    final m = _controller
                                        .calcMatrixFitWidthForPage(
                                      pageNumber: _currentPage,
                                    );
                                    if (m != null) _controller.goTo(m);
                                  },
                                ),
                                _CapsuleIconBtn(
                                  icon: Icons.rotate_right_rounded,
                                  tooltip: 'Rotar 90°',
                                  onTap: () => setState(
                                    () => _rotationTurns =
                                        (_rotationTurns + 1) % 4,
                                  ),
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPdfOutlinePanel() {
    return Container(
      width: 245,
      decoration: BoxDecoration(
        color: AppColors.surfaceLow,
        border: Border(
          right: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            child: Row(
              children: [
                _OutlineTabChip(
                  label: 'Índice (${_outlineNodes.length})',
                  selected: _outlineTab == 0,
                  onTap: () => setState(() => _outlineTab = 0),
                ),
                const SizedBox(width: 6),
                _OutlineTabChip(
                  label: 'Marcadores (${_bookmarkedPages.length})',
                  selected: _outlineTab == 1,
                  onTap: () => setState(() => _outlineTab = 1),
                ),
                const Spacer(),
                IconButton(
                  onPressed: toggleOutlinePanel,
                  icon: const Icon(Icons.close_rounded, size: 15),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _outlineTab == 0
                ? _outlineNodes.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Este PDF no incluye tabla de contenidos integrada.',
                            textAlign: TextAlign.center,
                            style: AppTypography.bodySm.copyWith(
                              color: AppColors.outline,
                            ),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 6,
                        ),
                        children: _buildOutlineNodesWidgets(_outlineNodes, 0),
                      )
                : _bookmarkedPages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Pulsa el icono de marcador arriba para guardar páginas clave.',
                            textAlign: TextAlign.center,
                            style: AppTypography.bodySm.copyWith(
                              color: AppColors.outline,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 8,
                        ),
                        itemCount: _bookmarkedPages.length,
                        itemBuilder: (ctx, idx) {
                          final page = _bookmarkedPages[idx];
                          final active = page == _currentPage;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: active
                                  ? AppColors.surfaceHighest
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () {
                                      if (_controller.isReady) {
                                        _controller.goToPage(pageNumber: page);
                                      }
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.bookmark_rounded,
                                            size: 14,
                                            color: AppColors.bookAmber,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Página $page',
                                            style: AppTypography.bodyMd.copyWith(
                                              fontSize: 13,
                                              fontWeight: active
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Quitar marcador',
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 14,
                                    color: AppColors.outline,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _removeBookmarkPage(page),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildOutlineNodesWidgets(
    List<PdfOutlineNode> nodes,
    int depth,
  ) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      widgets.add(
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: node.dest == null
              ? null
              : () {
                  if (_controller.isReady) {
                    _controller.goToDest(node.dest);
                  }
                },
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              8.0 + (depth.clamp(0, 4) * 10.0),
              6,
              8,
              6,
            ),
            child: Row(
              children: [
                if (node.dest?.pageNumber != null)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${node.dest!.pageNumber}',
                      style: AppTypography.badgeMono.copyWith(
                        fontSize: 9.5,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    node.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMd.copyWith(
                      fontSize: depth == 0 ? 12.5 : 12,
                      fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.w400,
                      color: depth == 0
                          ? AppColors.onSurface
                          : AppColors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (node.children.isNotEmpty) {
        widgets.addAll(_buildOutlineNodesWidgets(node.children, depth + 1));
      }
    }
    return widgets;
  }
}

class _OutlineTabChip extends StatelessWidget {
  const _OutlineTabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceHighest : AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.5)
                : AppColors.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Text(
          label,
          style: AppTypography.badgeMono.copyWith(
            fontSize: 10,
            color: selected ? AppColors.primary : AppColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _RibbonToggleChip extends StatelessWidget {
  const _RibbonToggleChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? activeColor.withValues(alpha: 0.18)
              : AppColors.surfaceLow,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active
                ? activeColor.withValues(alpha: 0.65)
                : AppColors.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: !enabled
                  ? AppColors.outline
                  : active
                      ? activeColor
                      : AppColors.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: AppTypography.badgeMono.copyWith(
                color: !enabled
                    ? AppColors.outline
                    : active
                        ? activeColor
                        : AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CapsuleDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: AppColors.outlineVariant.withValues(alpha: 0.7),
    );
  }
}

class _CapsuleIconBtn extends StatelessWidget {
  const _CapsuleIconBtn({
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(
        icon,
        size: 18,
        color: onTap == null ? AppColors.outlineVariant : AppColors.onSurface,
      ),
      onPressed: onTap,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }
}
