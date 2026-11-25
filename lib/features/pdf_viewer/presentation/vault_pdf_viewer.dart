import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
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

class VaultPdfViewerState extends ConsumerState<VaultPdfViewer>
    with SingleTickerProviderStateMixin {
  final PdfViewerController _controller = PdfViewerController();
  late PdfTextSearcher _textSearcher;
  final FocusNode _inDocSearchFocus = FocusNode();
  final TextEditingController _inDocSearchController = TextEditingController();
  final FocusNode _zoomEditFocus = FocusNode();
  final TextEditingController _zoomEditController = TextEditingController();
  final FocusNode _pageEditFocus = FocusNode();
  final TextEditingController _pageEditController = TextEditingController();

  final AnnotationHistoryStack _history = AnnotationHistoryStack();

  String? _resolvedPath;
  bool _loadingPath = true;
  String? _pathError;

  int _currentPage = 1;
  int _totalPages = 1;
  double _zoom = 1.0;
  bool _isEditingZoom = false;
  bool _isEditingPage = false;
  int _rotationTurns = 0;

  PdfMarkerTool _toolMode = PdfMarkerTool.browse;
  String _selectedColorHex = PdfHighlightPalette.options.first.hex;
  bool _showSearchBar = false;
  PdfTextSelection? _activeSelection;
  final ValueNotifier<bool> _hasSelectionNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<Offset?> _floatingMenuAnchor =
      ValueNotifier<Offset?>(null);
  final GlobalKey _viewerStackKey = GlobalKey();
  bool _useTouchInput =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  final Map<int, PdfPageText> _pageTextCache = {};
  final Map<int, List<PdfCharBounds>> _pageCharBoundsCache = {};
  final Map<int, Future<PdfPageText?>> _pendingTextLoads = {};

  DateTime? _lastDoubleTapAt;
  Offset? _lastDoubleTapDocPos;
  DateTime? _lastDragFinishedAt;
  Offset? _mouseDownGlobal;
  bool _didDragSelect = false;
  bool _isMousePanningLeft = false;
  bool _isMousePanningMiddle = false;
  bool _didMousePanMove = false;
  bool _isDraggingScrollThumb = false;
  bool _isTouchpadPanning = false;
  Offset? _lastPanGlobal;
  Offset _panAccumulatedPos = Offset.zero;
  VelocityTracker? _panVelocityTracker;
  Ticker? _panInertiaTicker;
  Offset _panVelocityPerSec = Offset.zero;
  Duration? _lastInertiaElapsed;
  final ValueNotifier<MouseCursor> _viewerCursorNotifier =
      ValueNotifier<MouseCursor>(MouseCursor.defer);
  PdfTextSelectionPoint? _mouseSelectionAnchor;
  PdfTextSelectionPoint? _lastAppliedStart;
  PdfTextSelectionPoint? _lastAppliedEnd;
  Offset? _pendingDragGlobalPos;
  bool _dragFrameScheduled = false;

  // Embedded PDF outline & persistent page bookmarks
  List<PdfOutlineNode> _outlineNodes = const [];
  final Set<String> _expandedOutlinePaths = {};
  List<int> _bookmarkedPages = [];
  bool _showOutlineDrawer = false;
  int _outlineTab = 0; // 0 = PDF TOC, 1 = Bookmarks

  // Live stroke state while dragging in PdfMarkerTool.highlight
  int? _dragPageNumber;
  List<Offset> _dragPoints = [];

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;
  bool get hasSelection => _hasLiveSelection;
  double get currentZoom => _zoom;
  int get currentPage => _currentPage;
  int get totalPages => _totalPages;
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
    _panInertiaTicker = createTicker(_onInertiaTick);
    _resolveFile();
    _loadBookmarks();
  }

  @override
  void didUpdateWidget(covariant VaultPdfViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.filePath != widget.item.filePath) {
      _stopPanInertia();
      _currentPage = widget.initialPage;
      _rotationTurns = 0;
      _activeSelection = null;
      _hasSelectionNotifier.value = false;
      _floatingMenuAnchor.value = null;
      _pageTextCache.clear();
      _pageCharBoundsCache.clear();
      _pendingTextLoads.clear();
      _outlineNodes = const [];
      _expandedOutlinePaths.clear();
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
    _panInertiaTicker?.dispose();
    _viewerCursorNotifier.dispose();
    _controller.removeListener(_onControllerChanged);
    _textSearcher.dispose();
    _inDocSearchController.dispose();
    _inDocSearchFocus.dispose();
    _zoomEditController.dispose();
    _zoomEditFocus.dispose();
    _pageEditController.dispose();
    _pageEditFocus.dispose();
    _hasSelectionNotifier.dispose();
    _floatingMenuAnchor.dispose();
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
      _notifyHistory();
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

  /// Copies the active PDF text selection to the system clipboard cleanly.
  Future<bool> copySelectedText([PdfTextSelection? selection]) async {
    final PdfTextSelection? target = selection ??
        (_controller.isReady &&
                _controller.textSelectionDelegate.hasSelectedText
            ? _controller.textSelectionDelegate
            : _activeSelection);
    if (target == null || !target.hasSelectedText) return false;

    if (!target.isCopyAllowed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Este PDF restringe la copia de texto.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return false;
    }

    String selectedText = '';
    try {
      selectedText = await target.getSelectedText();
    } catch (_) {}

    var copied = false;
    if (selectedText.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: selectedText));
      copied = true;
    } else if (target is PdfTextSelectionDelegate) {
      copied = await target.copyTextSelection();
    }

    if (copied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Texto copiado al portapapeles'),
          duration: Duration(milliseconds: 1500),
        ),
      );
    }
    return copied;
  }

  /// Applies a manual zoom percentage (e.g. `120` for `120%`) centered on view.
  Future<void> setZoomPercent(double percent) async {
    if (!_controller.isReady) return;
    final minZ = _controller.minScale.clamp(0.1, 1.0);
    final maxZ = _controller.maxScale.clamp(1.0, 8.0);
    final targetScale = (percent / 100.0).clamp(minZ, maxZ);
    await _controller.setZoom(_controller.centerPosition, targetScale);
    if (mounted) {
      setState(() => _zoom = _controller.currentZoom);
      _notifyHistory();
    }
  }

  void _startZoomEdit() {
    if (!_controller.isReady) return;
    final currentPct = '${(_zoom * 100).round()}';
    _zoomEditController.value = TextEditingValue(
      text: currentPct,
      selection: TextSelection(baseOffset: 0, extentOffset: currentPct.length),
    );
    setState(() => _isEditingZoom = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _zoomEditFocus.requestFocus();
      _zoomEditController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _zoomEditController.text.length,
      );
    });
  }

  void _cancelZoomEdit() {
    if (!_isEditingZoom) return;
    setState(() => _isEditingZoom = false);
  }

  Future<void> _commitZoomEdit() async {
    if (!_isEditingZoom) return;
    final parsedScale = parsePdfZoomPercent(_zoomEditController.text);
    setState(() => _isEditingZoom = false);
    if (parsedScale == null || !_controller.isReady) return;
    await setZoomPercent(parsedScale * 100.0);
  }

  /// Jumps cleanly to a 1-based page number inside the document.
  Future<void> goToPageNumber(int pageNumber) async {
    if (!_controller.isReady || _totalPages <= 0) return;
    final clamped = pageNumber.clamp(1, _totalPages);
    await _controller.goToPage(pageNumber: clamped);
  }

  /// Fits the entire current page inside the viewport (width & height).
  Future<void> fitFullPage() async {
    if (!_controller.isReady) return;
    final m = _controller.calcMatrixForFit(pageNumber: _currentPage);
    if (m != null) {
      await _controller.goTo(m);
    }
  }

  /// Fits the current page width inside the viewport.
  Future<void> fitPageWidth() async {
    if (!_controller.isReady) return;
    final m = _controller.calcMatrixFitWidthForPage(pageNumber: _currentPage);
    if (m != null) {
      await _controller.goTo(m);
    }
  }

  void _startPageEdit() {
    if (!_controller.isReady || _totalPages <= 0) return;
    final currentText = '$_currentPage';
    _pageEditController.value = TextEditingValue(
      text: currentText,
      selection: TextSelection(baseOffset: 0, extentOffset: currentText.length),
    );
    setState(() => _isEditingPage = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pageEditFocus.requestFocus();
      _pageEditController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _pageEditController.text.length,
      );
    });
  }

  void _cancelPageEdit() {
    if (!_isEditingPage) return;
    setState(() => _isEditingPage = false);
  }

  Future<void> _commitPageEdit() async {
    if (!_isEditingPage) return;
    final targetPage = parsePdfPageInput(
      _pageEditController.text,
      totalPages: _totalPages,
    );
    setState(() => _isEditingPage = false);
    if (targetPage == null || !_controller.isReady) return;
    await goToPageNumber(targetPage);
  }

  Future<PdfPageText?> _getOrLoadPageText(int pageNumber) async {
    final existing = _pageTextCache[pageNumber];
    if (existing != null) return existing;

    final pending = _pendingTextLoads[pageNumber];
    if (pending != null) return pending;

    if (!_controller.isReady ||
        pageNumber < 1 ||
        pageNumber > _controller.pages.length) {
      return null;
    }

    final page = _controller.pages[pageNumber - 1];
    final Future<PdfPageText?> future =
        page.loadStructuredText(ensureLoaded: true).then<PdfPageText?>((loaded) {
      _pendingTextLoads.remove(pageNumber);
      if (!mounted || loaded.charRects.isEmpty) return null;
      _pageTextCache[pageNumber] = loaded;
      _pageCharBoundsCache[pageNumber] = [
        for (final r in loaded.charRects)
          PdfCharBounds(
            left: r.left,
            top: r.top,
            right: r.right,
            bottom: r.bottom,
          ),
      ];
      if (_didDragSelect) {
        _scheduleDragSelectionUpdate();
      }
      return loaded;
    }).catchError((Object _) {
      _pendingTextLoads.remove(pageNumber);
      return null;
    });
    return _pendingTextLoads[pageNumber] = future;
  }

  void _warmupAroundPage(int pageNumber) {
    if (!_controller.isReady) return;
    final total = _controller.pages.length;
    for (final p in [pageNumber, pageNumber - 1, pageNumber + 1]) {
      if (p >= 1 && p <= total && !_pageTextCache.containsKey(p)) {
        unawaited(_getOrLoadPageText(p));
      }
    }
  }

  int? _findClosestPageIndex(Offset docPos, {required double maxMargin}) {
    if (!_controller.isReady) return null;
    final layouts = _controller.layout.pageLayouts;
    if (layouts.isEmpty) return null;

    int? bestIdx;
    var bestDist2 = double.infinity;
    final maxDist2 = maxMargin.isFinite ? maxMargin * maxMargin : double.infinity;

    for (var i = 0; i < layouts.length; i++) {
      final rect = layouts[i];
      if (rect.contains(docPos)) return i;
      final dx = docPos.dx < rect.left
          ? rect.left - docPos.dx
          : (docPos.dx > rect.right ? docPos.dx - rect.right : 0.0);
      final dy = docPos.dy < rect.top
          ? rect.top - docPos.dy
          : (docPos.dy > rect.bottom ? docPos.dy - rect.bottom : 0.0);
      final dist2 = dx * dx + dy * dy;
      if (dist2 <= maxDist2 && dist2 < bestDist2) {
        bestDist2 = dist2;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  PdfTextSelectionPoint? _findPointInCachedPage(
    int pageIdx,
    Offset docPos, {
    required double maxMargin,
  }) {
    final pageNumber = pageIdx + 1;
    final pageText = _pageTextCache[pageNumber];
    final bounds = _pageCharBoundsCache[pageNumber];
    if (pageText == null || bounds == null || bounds.isEmpty) {
      unawaited(_getOrLoadPageText(pageNumber));
      return null;
    }

    final page = _controller.pages[pageIdx];
    final pageRect = _controller.layout.pageLayouts[pageIdx];
    final pt = docPos
        .translate(-pageRect.left, -pageRect.top)
        .toPdfPoint(page: page, scaledPageSize: pageRect.size);

    final idx = findClosestCharIndex(
      bounds,
      pt.x,
      pt.y,
      maxMargin: maxMargin,
    );
    if (idx == null) return null;
    return PdfTextSelectionPoint(pageText, idx);
  }

  PdfTextSelectionPoint? _findPointNearDocument(
    Offset docPos, {
    required double maxMargin,
  }) {
    final pageIdx = _findClosestPageIndex(docPos, maxMargin: maxMargin);
    if (pageIdx == null) return null;
    return _findPointInCachedPage(pageIdx, docPos, maxMargin: maxMargin);
  }

  Future<PdfTextSelectionPoint?> _findOrLoadPointNearDocument(
    Offset docPos, {
    required double maxMargin,
  }) async {
    final pageIdx = _findClosestPageIndex(docPos, maxMargin: maxMargin);
    if (pageIdx == null) return null;
    await _getOrLoadPageText(pageIdx + 1);
    if (!mounted || !_controller.isReady) return null;
    return _findPointInCachedPage(pageIdx, docPos, maxMargin: maxMargin);
  }

  PdfTextSelectionPoint? _findPointNearGlobal(
    Offset globalPos, {
    required double maxMargin,
  }) {
    if (!_controller.isReady) return null;
    final docPos = _controller.globalToDocument(globalPos);
    if (docPos == null) return null;
    return _findPointNearDocument(docPos, maxMargin: maxMargin);
  }

  void _showFloatingMenuAtGlobal(Offset globalPos) {
    final stackBox =
        _viewerStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;
    final local = stackBox.globalToLocal(globalPos);
    _floatingMenuAnchor.value = local;
  }

  void _showFloatingMenuAtDocument(Offset docPos) {
    if (!_controller.isReady) return;
    final globalPos = _controller.documentToGlobal(docPos);
    if (globalPos == null) return;
    _showFloatingMenuAtGlobal(globalPos);
  }

  Future<void> _applySelectionPoints(
    PdfTextSelectionPoint anchor,
    PdfTextSelectionPoint end,
  ) async {
    if (!_controller.isReady) return;
    final ordered = PdfTextSelectionRange.fromPoints(anchor, end);
    if (_lastAppliedStart?.text.pageNumber == ordered.start.text.pageNumber &&
        _lastAppliedStart?.index == ordered.start.index &&
        _lastAppliedEnd?.text.pageNumber == ordered.end.text.pageNumber &&
        _lastAppliedEnd?.index == ordered.end.index) {
      return;
    }
    _lastAppliedStart = ordered.start;
    _lastAppliedEnd = ordered.end;
    await _controller.textSelectionDelegate.setTextSelectionPointRange(ordered);
    if (!_hasSelectionNotifier.value) {
      _hasSelectionNotifier.value = true;
      _notifyHistory();
    }
  }

  void _flushDragSelectionAt(Offset targetGlobal) {
    if (!mounted || !_controller.isReady) return;
    _mouseSelectionAnchor ??=
        (_mouseDownGlobal != null
            ? _findPointNearGlobal(_mouseDownGlobal!, maxMargin: 48.0)
            : null) ??
        _findPointNearGlobal(targetGlobal, maxMargin: 48.0);
    final anchor = _mouseSelectionAnchor;
    if (anchor == null) return;

    final endPt = _findPointNearGlobal(
      targetGlobal,
      maxMargin: double.infinity,
    );
    if (endPt == null) return;
    unawaited(_applySelectionPoints(anchor, endPt));
  }

  void _scheduleDragSelectionUpdate() {
    if (_dragFrameScheduled) return;
    _dragFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _dragFrameScheduled = false;
      if (!mounted || !_didDragSelect || !_controller.isReady) return;
      final targetGlobal = _pendingDragGlobalPos;
      if (targetGlobal == null) return;
      _flushDragSelectionAt(targetGlobal);
    });
  }

  void _stopPanInertia() {
    if (_panInertiaTicker?.isActive ?? false) {
      _panInertiaTicker?.stop();
    }
    _panVelocityPerSec = Offset.zero;
    _lastInertiaElapsed = null;
  }

  void _startPanInertia(Offset screenVelocityPerSec) {
    final speed = screenVelocityPerSec.distance;
    if (!mounted || !_controller.isReady || speed < 140.0) {
      _stopPanInertia();
      return;
    }
    const maxSpeed = 2800.0;
    _panVelocityPerSec = speed > maxSpeed
        ? screenVelocityPerSec * (maxSpeed / speed)
        : screenVelocityPerSec;
    _lastInertiaElapsed = null;
    if (!(_panInertiaTicker?.isActive ?? false)) {
      _panInertiaTicker?.start();
    }
  }

  void _onInertiaTick(Duration elapsed) {
    if (!mounted || !_controller.isReady) {
      _stopPanInertia();
      return;
    }
    final prev = _lastInertiaElapsed;
    _lastInertiaElapsed = elapsed;
    if (prev == null) return;

    final dt = ((elapsed - prev).inMicroseconds / 1e6).clamp(0.0, 0.05);
    if (dt <= 0) return;

    _panByScreenDelta(_panVelocityPerSec * dt);
    _panVelocityPerSec *= math.exp(-7.2 * dt);
    if (_panVelocityPerSec.distance < 18.0) {
      _stopPanInertia();
    }
  }

  void _panByScreenDelta(Offset screenDelta) {
    if (!_controller.isReady || screenDelta == Offset.zero) return;
    final deltaDoc = rotateScreenDeltaToDocument(
      screenDelta,
      zoom: _controller.currentZoom,
      quarterTurns: _rotationTurns,
    );
    final nextCenter = _controller.centerPosition - deltaDoc;
    _controller.value = _controller.calcMatrixFor(nextCenter);
  }

  bool _isGlobalPosInsideAnyPage(Offset globalPos) {
    if (!_controller.isReady) return true;
    final docPos = _controller.globalToDocument(globalPos);
    if (docPos == null) return false;
    return isPointInsideAnyRect(docPos, _controller.layout.pageLayouts);
  }

  void _updateHoverCursor(Offset globalPos) {
    if (_useTouchInput) return;
    if (_isMousePanningLeft || _isMousePanningMiddle) {
      if (_viewerCursorNotifier.value != SystemMouseCursors.grabbing) {
        _viewerCursorNotifier.value = SystemMouseCursors.grabbing;
      }
      return;
    }
    if (_isDraggingScrollThumb) {
      if (_viewerCursorNotifier.value != SystemMouseCursors.click) {
        _viewerCursorNotifier.value = SystemMouseCursors.click;
      }
      return;
    }
    final insidePage = _isGlobalPosInsideAnyPage(globalPos);
    final nextCursor =
        insidePage ? MouseCursor.defer : SystemMouseCursors.grab;
    if (_viewerCursorNotifier.value != nextCursor) {
      _viewerCursorNotifier.value = nextCursor;
    }
  }

  void _handleViewerPointerDown(PointerDownEvent event) {
    _stopPanInertia();
    if (_isDraggingScrollThumb) return;

    if (event.kind == PointerDeviceKind.touch) {
      if (!_useTouchInput) {
        setState(() => _useTouchInput = true);
      }
      _floatingMenuAnchor.value = null;
      return;
    }
    if (event.kind != PointerDeviceKind.mouse) return;
    if (_useTouchInput) {
      setState(() => _useTouchInput = false);
    }

    _floatingMenuAnchor.value = null;

    if ((event.buttons & kMiddleMouseButton) != 0) {
      _isMousePanningMiddle = true;
      _didMousePanMove = false;
      _lastPanGlobal = event.position;
      _panAccumulatedPos = Offset.zero;
      _panVelocityTracker = VelocityTracker.withKind(PointerDeviceKind.mouse);
      _viewerCursorNotifier.value = SystemMouseCursors.grabbing;
      return;
    }

    if ((event.buttons & kPrimaryMouseButton) != 0) {
      // Holding left click outside any PDF page imitates touchpad/grab scrolling.
      if (!_isGlobalPosInsideAnyPage(event.position)) {
        _isMousePanningLeft = true;
        _didMousePanMove = false;
        _mouseDownGlobal = event.position;
        _lastPanGlobal = event.position;
        _didDragSelect = false;
        _mouseSelectionAnchor = null;
        _panAccumulatedPos = Offset.zero;
        _panVelocityTracker =
            VelocityTracker.withKind(PointerDeviceKind.mouse);
        _viewerCursorNotifier.value = SystemMouseCursors.grabbing;
        return;
      }

      if (_toolMode != PdfMarkerTool.browse) return;
      _mouseDownGlobal = event.position;
      _didDragSelect = false;
      _lastAppliedStart = null;
      _lastAppliedEnd = null;
      _mouseSelectionAnchor =
          _findPointNearGlobal(event.position, maxMargin: 48.0);
    }
  }

  void _handleViewerPointerMove(PointerMoveEvent event) {
    if ((_isMousePanningMiddle || _isMousePanningLeft) &&
        _controller.isReady) {
      final prev = _lastPanGlobal;
      _lastPanGlobal = event.position;
      if (prev != null) {
        final delta = event.position - prev;
        if (delta != Offset.zero) {
          if (!_didMousePanMove &&
              _mouseDownGlobal != null &&
              (event.position - _mouseDownGlobal!).distance >= 3.0) {
            _didMousePanMove = true;
          }
          _panByScreenDelta(delta);
          _panAccumulatedPos += delta;
          _panVelocityTracker?.addPosition(event.timeStamp, _panAccumulatedPos);
        }
      }
      return;
    }

    if (_toolMode != PdfMarkerTool.browse || _useTouchInput) return;
    final downPos = _mouseDownGlobal;
    if (downPos == null || (event.buttons & kPrimaryMouseButton) == 0) return;

    if (!_didDragSelect) {
      if ((event.position - downPos).distance < 4.0) return;
      _didDragSelect = true;
      _lastDoubleTapAt = null;
    }

    _pendingDragGlobalPos = event.position;
    _scheduleDragSelectionUpdate();
  }

  void _handleViewerPointerUpOrCancel(PointerEvent event) {
    if (_isMousePanningMiddle || _isMousePanningLeft) {
      final didMove = _didMousePanMove;
      final velocity =
          _panVelocityTracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
      _isMousePanningMiddle = false;
      _isMousePanningLeft = false;
      _didMousePanMove = false;
      _lastPanGlobal = null;
      _mouseDownGlobal = null;
      _panVelocityTracker = null;
      _updateHoverCursor(event.position);
      if (didMove) {
        _lastDragFinishedAt = DateTime.now();
        _startPanInertia(velocity);
      }
      return;
    }
    _isDraggingScrollThumb = false;
    if (_didDragSelect) {
      _flushDragSelectionAt(event.position);
      final hasSel = _lastAppliedStart != null && _lastAppliedEnd != null;
      _didDragSelect = false;
      _mouseDownGlobal = null;
      _lastDragFinishedAt = DateTime.now();
      if (hasSel && !_useTouchInput) {
        _showFloatingMenuAtGlobal(event.position);
      }
      return;
    }
    _mouseDownGlobal = null;
  }

  void _handleViewerPointerPanZoomStart(PointerPanZoomStartEvent event) {
    _stopPanInertia();
    _floatingMenuAnchor.value = null;
    _mouseDownGlobal = null;
    _didDragSelect = false;
    _isTouchpadPanning = false;
    _panAccumulatedPos = Offset.zero;
    _panVelocityTracker = VelocityTracker.withKind(PointerDeviceKind.trackpad);
  }

  void _handleViewerPointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (!_controller.isReady) return;
    // Let InteractiveViewer handle 2-finger pinch-zoom natively.
    if ((event.scale - 1.0).abs() >= 0.02) {
      _isTouchpadPanning = false;
      return;
    }
    if (_useTouchInput) return;
    _isTouchpadPanning = true;
    if (event.panDelta != Offset.zero) {
      _panByScreenDelta(event.panDelta);
      _panAccumulatedPos += event.panDelta;
      _panVelocityTracker?.addPosition(event.timeStamp, _panAccumulatedPos);
    }
  }

  void _handleViewerPointerPanZoomEnd(PointerPanZoomEndEvent event) {
    if (_isTouchpadPanning) {
      _isTouchpadPanning = false;
      final vel =
          _panVelocityTracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
      _startPanInertia(vel);
    }
    _panVelocityTracker = null;
  }

  void _handleViewerPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (_floatingMenuAnchor.value != null) {
        _floatingMenuAnchor.value = null;
      }
      if (!_useTouchInput &&
          event.kind == PointerDeviceKind.trackpad &&
          _controller.isReady &&
          !HardwareKeyboard.instance.isControlPressed) {
        _stopPanInertia();
        _panByScreenDelta(-event.scrollDelta);
      }
    }
  }

  /// Handles double-click word selection and triple-click line selection at [documentPosition].
  Future<void> _selectWordOrLineAt(
    PdfViewerController controller,
    Offset documentPosition, {
    required bool lineOnly,
  }) async {
    final hitPoint = await _findOrLoadPointNearDocument(
      documentPosition,
      maxMargin: 44.0,
    );
    if (!mounted || hitPoint == null) return;

    final pageText = hitPoint.text;
    final fullText = pageText.fullText;
    if (fullText.isEmpty || pageText.charRects.isEmpty) return;

    final target = lineOnly
        ? findLineRangeAt(fullText, hitPoint.index)
        : findWordRangeAt(fullText, hitPoint.index);
    if (target == null) return;

    final startPt = PdfTextSelectionPoint(pageText, target.start);
    final endPt = PdfTextSelectionPoint(pageText, target.end);
    _lastAppliedStart = startPt;
    _lastAppliedEnd = endPt;
    await controller.textSelectionDelegate.setTextSelectionPointRange(
      PdfTextSelectionRange.fromPoints(startPt, endPt),
    );
    if (!mounted) return;
    _hasSelectionNotifier.value = true;
    _notifyHistory();
    if (!_useTouchInput) {
      _showFloatingMenuAtDocument(documentPosition);
    }
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

    _floatingMenuAnchor.value = null;
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
    _floatingMenuAnchor.value = null;
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
      _activeSelection = null;
      _lastAppliedStart = null;
      _lastAppliedEnd = null;
      _hasSelectionNotifier.value = false;
      _floatingMenuAnchor.value = null;
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
    final showRibbon = _toolMode != PdfMarkerTool.browse;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () {
          if (!_inDocSearchFocus.hasFocus &&
              !_zoomEditFocus.hasFocus &&
              !_pageEditFocus.hasFocus &&
              _hasLiveSelection) {
            unawaited(copySelectedText());
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () {
          if (!_inDocSearchFocus.hasFocus &&
              !_zoomEditFocus.hasFocus &&
              !_pageEditFocus.hasFocus &&
              _hasLiveSelection) {
            unawaited(copySelectedText());
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyG, control: true): () {
          if (!_inDocSearchFocus.hasFocus && !_zoomEditFocus.hasFocus) {
            _startPageEdit();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true): () {
          if (!_inDocSearchFocus.hasFocus && !_zoomEditFocus.hasFocus) {
            _startPageEdit();
          }
        },
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () {
          if (!_inDocSearchFocus.hasFocus &&
              !_zoomEditFocus.hasFocus &&
              !_pageEditFocus.hasFocus) {
            unawaited(setZoomPercent(100));
          }
        },
        const SingleActivator(LogicalKeyboardKey.numpad0, control: true): () {
          if (!_inDocSearchFocus.hasFocus &&
              !_zoomEditFocus.hasFocus &&
              !_pageEditFocus.hasFocus) {
            unawaited(setZoomPercent(100));
          }
        },
        const SingleActivator(LogicalKeyboardKey.digit0, meta: true): () {
          if (!_inDocSearchFocus.hasFocus &&
              !_zoomEditFocus.hasFocus &&
              !_pageEditFocus.hasFocus) {
            unawaited(setZoomPercent(100));
          }
        },
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
                    ValueListenableBuilder<bool>(
                      valueListenable: _hasSelectionNotifier,
                      builder: (_, hasSel, _) {
                        if (!hasSel) return const SizedBox.shrink();
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: InkWell(
                                onTap: () {
                                  _floatingMenuAnchor.value = null;
                                  unawaited(copySelectedText());
                                },
                                borderRadius: BorderRadius.circular(4),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.surfaceContainer,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: AppColors.secondary.withValues(
                                        alpha: 0.55,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.content_copy_rounded,
                                        size: 12,
                                        color: AppColors.secondary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'COPIAR',
                                        style: AppTypography.badgeMono.copyWith(
                                          color: AppColors.secondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
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
                          ],
                        );
                      },
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
                      key: _viewerStackKey,
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
                    ValueListenableBuilder<MouseCursor>(
                      valueListenable: _viewerCursorNotifier,
                      builder: (_, cursor, child) => MouseRegion(
                        cursor: cursor,
                        onHover: (e) => _updateHoverCursor(e.position),
                        child: child,
                      ),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: _handleViewerPointerDown,
                        onPointerMove: _handleViewerPointerMove,
                        onPointerUp: _handleViewerPointerUpOrCancel,
                        onPointerCancel: _handleViewerPointerUpOrCancel,
                        onPointerPanZoomStart: _handleViewerPointerPanZoomStart,
                        onPointerPanZoomUpdate:
                            _handleViewerPointerPanZoomUpdate,
                        onPointerPanZoomEnd: _handleViewerPointerPanZoomEnd,
                        onPointerSignal: _handleViewerPointerSignal,
                        child: Padding(
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
                                margin: 22,
                                scrollByMouseWheel: 0.55,
                                panEnabled: _useTouchInput,
                                scaleEnabled: true,
                                enableKeyboardNavigation: true,
                                sizeDelegateProvider:
                                    const PdfViewerSizeDelegateProviderLegacy(
                                  minScale: 0.25,
                                  maxScale: 5.0,
                                  useAlternativeFitScaleAsMinScale: false,
                                ),
                                viewerOverlayBuilder:
                                    (context, size, handleLinkTap) => [
                                  PdfViewerScrollThumb(
                                    controller: _controller,
                                    orientation: ScrollbarOrientation.right,
                                    margin: 4,
                                    thumbSize: const Size(26, 36),
                                    thumbBuilder: (ctx, thumbSize, pageNumber,
                                            controller) =>
                                        Listener(
                                      behavior: HitTestBehavior.opaque,
                                      onPointerDown: (_) {
                                        _isDraggingScrollThumb = true;
                                        _viewerCursorNotifier.value =
                                            SystemMouseCursors.click;
                                      },
                                      onPointerUp: (_) =>
                                          _isDraggingScrollThumb = false,
                                      onPointerCancel: (_) =>
                                          _isDraggingScrollThumb = false,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: AppColors.surfaceHigh
                                              .withValues(alpha: 0.92),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: Border.all(
                                            color: AppColors.outlineVariant
                                                .withValues(alpha: 0.7),
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black45,
                                              blurRadius: 6,
                                              offset: Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(
                                          pageNumber != null
                                              ? '$pageNumber'
                                              : '',
                                          style: AppTypography.badgeMono
                                              .copyWith(
                                            color: AppColors.primary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                pagePaintCallbacks: [
                                _textSearcher.pageTextMatchPaintCallback,
                              ],
                              customizeContextMenuItems: (params, items) {
                                for (var i = 0; i < items.length; i++) {
                                  final item = items[i];
                                  if (item.type == ContextMenuButtonType.copy) {
                                    items[i] = ContextMenuButtonItem(
                                      label: 'Copiar',
                                      type: ContextMenuButtonType.copy,
                                      onPressed: () {
                                        params.dismissContextMenu();
                                        unawaited(
                                          copySelectedText(
                                            params.textSelectionDelegate,
                                          ),
                                        );
                                      },
                                    );
                                  } else if (item.type ==
                                      ContextMenuButtonType.selectAll) {
                                    items[i] = item.copyWith(
                                      label: 'Seleccionar todo',
                                    );
                                  }
                                }
                                if (params.textSelectionDelegate.hasSelectedText) {
                                  items.add(
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
                                enableSelectionHandles:
                                    _useTouchInput ? null : true,
                                buildSelectionHandle: _useTouchInput
                                    ? null
                                    : (_, _, _) => null,
                                magnifier: _useTouchInput
                                    ? const PdfViewerSelectionMagnifierParams()
                                    : const PdfViewerSelectionMagnifierParams(
                                        enabled: false,
                                      ),
                                showContextMenuAutomatically: _useTouchInput,
                                onTextSelectionChange: (sel) {
                                  if (!mounted) return;
                                  _activeSelection = sel;
                                  final nextHasSel = sel.hasSelectedText;
                                  if (!nextHasSel) {
                                    _lastAppliedStart = null;
                                    _lastAppliedEnd = null;
                                    _floatingMenuAnchor.value = null;
                                  }
                                  if (_hasSelectionNotifier.value != nextHasSel) {
                                    _hasSelectionNotifier.value = nextHasSel;
                                    _notifyHistory();
                                  }
                                },
                              ),
                              onGeneralTap: (context, controller, details) {
                                if (_toolMode != PdfMarkerTool.browse) {
                                  return false;
                                }
                                if (details.type ==
                                    PdfViewerGeneralTapType.doubleTap) {
                                  _lastDoubleTapAt = DateTime.now();
                                  _lastDoubleTapDocPos =
                                      details.documentPosition;
                                  unawaited(
                                    _selectWordOrLineAt(
                                      controller,
                                      details.documentPosition,
                                      lineOnly: false,
                                    ),
                                  );
                                  return true;
                                }
                                if (details.type ==
                                        PdfViewerGeneralTapType.tap &&
                                    _lastDoubleTapAt != null &&
                                    _lastDoubleTapDocPos != null &&
                                    DateTime.now()
                                            .difference(_lastDoubleTapAt!)
                                            .inMilliseconds <=
                                        450 &&
                                    (details.documentPosition -
                                                _lastDoubleTapDocPos!)
                                            .distance <=
                                        20) {
                                  _lastDoubleTapAt = null;
                                  unawaited(
                                    _selectWordOrLineAt(
                                      controller,
                                      details.documentPosition,
                                      lineOnly: true,
                                    ),
                                  );
                                  return true;
                                }
                                if (details.type ==
                                    PdfViewerGeneralTapType.tap) {
                                  if (_lastDragFinishedAt != null &&
                                      DateTime.now()
                                              .difference(_lastDragFinishedAt!)
                                              .inMilliseconds <=
                                          300) {
                                    _lastDragFinishedAt = null;
                                    return true;
                                  }
                                  _lastDoubleTapAt = null;
                                  _lastAppliedStart = null;
                                  _lastAppliedEnd = null;
                                  _floatingMenuAnchor.value = null;
                                  if (_hasSelectionNotifier.value) {
                                    _hasSelectionNotifier.value = false;
                                    _notifyHistory();
                                  }
                                }
                                return false;
                              },
                              onViewerReady: (document, controller) {
                                if (!mounted) return;
                                final page =
                                    controller.pageNumber ?? widget.initialPage;
                                setState(() {
                                  _totalPages = document.pages.length;
                                  _currentPage = page;
                                  _zoom = controller.currentZoom;
                                });
                                _warmupAroundPage(page);
                                _notifyHistory();
                                document.loadOutline().then((nodes) {
                                  if (mounted) {
                                    setState(() => _outlineNodes = nodes);
                                  }
                                }).catchError((_) {});
                              },
                              onPageChanged: (pageNumber) {
                                if (!mounted || pageNumber == null) return;
                                setState(() => _currentPage = pageNumber);
                                _warmupAroundPage(pageNumber);
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
                                _buildPageIndicator(),
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
                                  tooltip: 'Reducir zoom (Ctrl + Rueda)',
                                  onTap: () => _controller.zoomDown(),
                                ),
                                _buildZoomIndicator(),
                                _CapsuleIconBtn(
                                  icon: Icons.add_rounded,
                                  tooltip: 'Aumentar zoom (Ctrl + Rueda)',
                                  onTap: () => _controller.zoomUp(),
                                ),
                                const SizedBox(width: 4),
                                _buildZoom100Button(),
                                _CapsuleDivider(),
                                ValueListenableBuilder<bool>(
                                  valueListenable: _hasSelectionNotifier,
                                  builder: (_, hasSel, _) => Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (hasSel) ...[
                                        InkWell(
                                          onTap: () {
                                            _floatingMenuAnchor.value = null;
                                            unawaited(copySelectedText());
                                          },
                                          borderRadius:
                                              BorderRadius.circular(999),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.secondary,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.content_copy_rounded,
                                                  size: 14,
                                                  color: AppColors.onSecondary,
                                                ),
                                                const SizedBox(width: 5),
                                                Text(
                                                  'Copiar',
                                                  style: AppTypography.badgeMono
                                                      .copyWith(
                                                    color:
                                                        AppColors.onSecondary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                      ],
                                      InkWell(
                                        onTap: triggerHighlightAction,
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: (_toolMode ==
                                                        PdfMarkerTool
                                                            .highlight ||
                                                    hasSel)
                                                ? PdfHighlightPalette
                                                    .colorFromHex(
                                                    _selectedColorHex,
                                                  )
                                                : AppColors.surfaceContainer,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.draw_rounded,
                                                size: 14,
                                                color: (_toolMode ==
                                                            PdfMarkerTool
                                                                .highlight ||
                                                        hasSel)
                                                    ? AppColors.onPrimary
                                                    : AppColors.primary,
                                              ),
                                              const SizedBox(width: 5),
                                              Text(
                                                hasSel
                                                    ? 'Subrayar'
                                                    : 'Marcador',
                                                style: AppTypography.badgeMono
                                                    .copyWith(
                                                  color: (_toolMode ==
                                                              PdfMarkerTool
                                                                  .highlight ||
                                                          hasSel)
                                                      ? AppColors.onPrimary
                                                      : AppColors.onSurface,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
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
                                  onTap: fitPageWidth,
                                ),
                                _CapsuleIconBtn(
                                  icon: Icons.crop_free_rounded,
                                  tooltip: 'Ajustar página completa',
                                  onTap: fitFullPage,
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
                  _buildFloatingSelectionPill(),
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

  Widget _buildFloatingSelectionPill() {
    return ValueListenableBuilder<Offset?>(
      valueListenable: _floatingMenuAnchor,
      builder: (_, anchor, _) {
        if (anchor == null || !_hasSelectionNotifier.value) {
          return const SizedBox.shrink();
        }
        final stackBox =
            _viewerStackKey.currentContext?.findRenderObject() as RenderBox?;
        final stackWidth = stackBox?.hasSize == true ? stackBox!.size.width : 800.0;
        final stackHeight =
            stackBox?.hasSize == true ? stackBox!.size.height : 600.0;

        final left = (anchor.dx - 110.0)
            .clamp(10.0, math.max(10.0, stackWidth - 250.0))
            .toDouble();
        final top = (anchor.dy > 62
                ? (anchor.dy - 48)
                    .clamp(8.0, math.max(8.0, stackHeight - 96.0))
                : (anchor.dy + 14)
                    .clamp(8.0, math.max(8.0, stackHeight - 96.0)))
            .toDouble();

        return Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh.withValues(alpha: 0.98),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.85),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _FloatingSelectionBtn(
                    icon: Icons.content_copy_rounded,
                    label: 'Copiar',
                    color: AppColors.secondary,
                    onTap: () {
                      _floatingMenuAnchor.value = null;
                      unawaited(copySelectedText());
                    },
                  ),
                  const SizedBox(width: 4),
                  _FloatingSelectionBtn(
                    icon: Icons.draw_rounded,
                    label: 'Subrayar',
                    color: PdfHighlightPalette.colorFromHex(_selectedColorHex),
                    onTap: () {
                      _floatingMenuAnchor.value = null;
                      unawaited(triggerHighlightAction());
                    },
                  ),
                  const SizedBox(width: 4),
                  _FloatingSelectionBtn(
                    icon: Icons.select_all_rounded,
                    label: 'Todo',
                    color: AppColors.onSurfaceVariant,
                    onTap: () {
                      _floatingMenuAnchor.value = null;
                      if (_controller.isReady) {
                        unawaited(
                          _controller.textSelectionDelegate.selectAllText(),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPageIndicator() {
    if (_isEditingPage) {
      return TapRegion(
        onTapOutside: (_) => _commitPageEdit(),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _cancelPageEdit,
          },
          child: SizedBox(
            width: 86,
            height: 26,
            child: TextField(
              controller: _pageEditController,
              focusNode: _pageEditFocus,
              autofocus: true,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(5),
              ],
              style: AppTypography.monoSm.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                suffixText: '/$_totalPages',
                suffixStyle: AppTypography.monoSm.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 10.5,
                ),
                filled: true,
                fillColor: AppColors.surfaceLowest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppColors.primary),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.primary,
                    width: 1.4,
                  ),
                ),
              ),
              onSubmitted: (_) => _commitPageEdit(),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: 'Clic para ir a una página (Ctrl+G)',
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          child: InkWell(
            onTap: _startPageEdit,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Text(
                'Pág $_currentPage / $_totalPages',
                style: AppTypography.monoSm.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildZoom100Button() {
    final is100 = (_zoom * 100).round() == 100;
    return Tooltip(
      message: 'Restablecer zoom al 100% (Ctrl+0)',
      child: InkWell(
        onTap: () => setZoomPercent(100),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: is100
                ? AppColors.primary.withValues(alpha: 0.18)
                : AppColors.surfaceContainer.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: is100
                  ? AppColors.primary.withValues(alpha: 0.6)
                  : AppColors.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Text(
            '1:1',
            style: AppTypography.badgeMono.copyWith(
              color: is100 ? AppColors.primary : AppColors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildZoomIndicator() {
    if (_isEditingZoom) {
      return TapRegion(
        onTapOutside: (_) => _commitZoomEdit(),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _cancelZoomEdit,
          },
          child: SizedBox(
            width: 68,
            height: 26,
            child: TextField(
              controller: _zoomEditController,
              focusNode: _zoomEditFocus,
              autofocus: true,
              textAlign: TextAlign.center,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              textInputAction: TextInputAction.done,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,%]')),
                LengthLimitingTextInputFormatter(6),
              ],
              style: AppTypography.monoSm.copyWith(
                color: AppColors.onSurface,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                suffixText: '%',
                suffixStyle: AppTypography.monoSm.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
                filled: true,
                fillColor: AppColors.surfaceLowest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppColors.primary),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.primary,
                    width: 1.4,
                  ),
                ),
              ),
              onSubmitted: (_) => _commitZoomEdit(),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: 'Clic para escribir el zoom manualmente (%)',
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          child: InkWell(
            onTap: _startZoomEdit,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                '${(_zoom * 100).round()}%',
                style: AppTypography.monoSm.copyWith(
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
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
          if (_outlineTab == 0 && _outlineNodes.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: AppColors.surfaceLowest.withValues(alpha: 0.65),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_outlineNodes.length} temas',
                      style: AppTypography.badgeMono.copyWith(
                        color: AppColors.outline,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: () {
                      setState(() {
                        if (_expandedOutlinePaths.isEmpty) {
                          _expandedOutlinePaths.addAll(
                            _collectExpandableOutlinePaths(_outlineNodes),
                          );
                        } else {
                          _expandedOutlinePaths.clear();
                        }
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _expandedOutlinePaths.isEmpty
                                ? Icons.unfold_more_rounded
                                : Icons.unfold_less_rounded,
                            size: 14,
                            color: AppColors.secondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _expandedOutlinePaths.isEmpty
                                ? 'Expandir todo'
                                : 'Contraer todo',
                            style: AppTypography.badgeMono.copyWith(
                              color: AppColors.secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
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

  Iterable<String> _collectExpandableOutlinePaths(
    List<PdfOutlineNode> nodes, [
    String pathPrefix = '',
  ]) sync* {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node.children.isEmpty) continue;
      final pathKey = pathPrefix.isEmpty ? '$i' : '$pathPrefix/$i';
      yield pathKey;
      yield* _collectExpandableOutlinePaths(node.children, pathKey);
    }
  }

  List<Widget> _buildOutlineNodesWidgets(
    List<PdfOutlineNode> nodes,
    int depth, [
    String pathPrefix = '',
  ]) {
    final widgets = <Widget>[];
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final pathKey = pathPrefix.isEmpty ? '$i' : '$pathPrefix/$i';
      final hasChildren = node.children.isNotEmpty;
      final isExpanded = _expandedOutlinePaths.contains(pathKey);
      final marker = formatOutlineLevelMarker(depth, i);
      final displayTitle = cleanOutlineDisplayTitle(node.title);
      final pageNumber = node.dest?.pageNumber;

      final Color markerTextColor;
      final Color markerBgColor;
      final Color markerBorderColor;
      switch (depth) {
        case <= 0:
          markerTextColor = AppColors.onSurface;
          markerBgColor = AppColors.surfaceHighest;
          markerBorderColor = AppColors.outlineVariant.withValues(alpha: 0.7);
        case 1:
          markerTextColor = AppColors.secondary;
          markerBgColor = AppColors.secondary.withValues(alpha: 0.14);
          markerBorderColor = AppColors.secondary.withValues(alpha: 0.35);
        case 2:
          markerTextColor = AppColors.bookAmber;
          markerBgColor = AppColors.bookAmber.withValues(alpha: 0.14);
          markerBorderColor = AppColors.bookAmber.withValues(alpha: 0.35);
        default:
          markerTextColor = AppColors.outline;
          markerBgColor = Colors.transparent;
          markerBorderColor = Colors.transparent;
      }

      widgets.add(
        Container(
          margin: EdgeInsets.only(
            top: depth == 0 && i > 0 ? 4 : 1,
            bottom: 1,
            left: depth.clamp(0, 4) * 10.0,
          ),
          decoration: BoxDecoration(
            color: depth == 0
                ? AppColors.surfaceContainer.withValues(alpha: 0.55)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: depth > 0
                ? Border(
                    left: BorderSide(
                      color: AppColors.outlineVariant.withValues(alpha: 0.45),
                      width: 1.2,
                    ),
                  )
                : null,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              if (node.dest != null && _controller.isReady) {
                _controller.goToDest(node.dest);
              } else if (hasChildren) {
                setState(() {
                  if (isExpanded) {
                    _expandedOutlinePaths.remove(pathKey);
                  } else {
                    _expandedOutlinePaths.add(pathKey);
                  }
                });
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 5, 6, 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasChildren)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () {
                        setState(() {
                          if (isExpanded) {
                            _expandedOutlinePaths.remove(pathKey);
                          } else {
                            _expandedOutlinePaths.add(pathKey);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          isExpanded
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_right_rounded,
                          size: 16,
                          color: depth == 0
                              ? AppColors.onSurface
                              : AppColors.secondary,
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: 20),
                  Container(
                    margin: const EdgeInsets.only(top: 1, right: 7),
                    constraints: const BoxConstraints(minWidth: 19),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: markerBgColor,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: markerBorderColor, width: 0.8),
                    ),
                    child: Text(
                      marker,
                      style: AppTypography.badgeMono.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: markerTextColor,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Tooltip(
                      message: displayTitle,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Text(
                        displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyMd.copyWith(
                          fontSize: depth == 0 ? 12.5 : 11.8,
                          fontWeight:
                              depth == 0 ? FontWeight.w600 : FontWeight.w400,
                          color: depth == 0
                              ? AppColors.onSurface
                              : (depth == 1
                                  ? AppColors.onSurface.withValues(alpha: 0.88)
                                  : AppColors.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ),
                  if (pageNumber != null)
                    Container(
                      margin: const EdgeInsets.only(left: 6, top: 1),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceLowest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '$pageNumber',
                        style: AppTypography.badgeMono.copyWith(
                          fontSize: 9.5,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );

      if (hasChildren && isExpanded) {
        widgets.addAll(
          _buildOutlineNodesWidgets(node.children, depth + 1, pathKey),
        );
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

class _FloatingSelectionBtn extends StatelessWidget {
  const _FloatingSelectionBtn({
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
      borderRadius: BorderRadius.circular(7),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: AppTypography.badgeMono.copyWith(
                color: AppColors.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
