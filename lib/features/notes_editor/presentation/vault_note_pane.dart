import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_breakpoints.dart';
import '../../../core/storage/vault_storage_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../vault_tree/application/vault_providers.dart';
import '../../vault_tree/domain/vault_item.dart';
import '../../vault_tree/presentation/vault_dialogs.dart';
import '../application/markdown_parser.dart';
import 'widgets/vault_markdown_reader.dart';

enum NoteViewMode { read, split, edit }

/// Interactive Markdown note reader & editor with local debounced autosave,
/// TOC outline navigation, enriched blocks, and drag-and-drop image import.
class VaultNotePane extends ConsumerStatefulWidget {
  const VaultNotePane({
    super.key,
    required this.item,
    this.showTopBar = true,
    this.searchHighlight = '',
  });

  final VaultItem item;
  final bool showTopBar;
  final String searchHighlight;

  @override
  ConsumerState<VaultNotePane> createState() => VaultNotePaneState();
}

class VaultNotePaneState extends ConsumerState<VaultNotePane> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  NoteViewMode _mode = NoteViewMode.read;
  Timer? _saveDebounce;
  bool _saving = false;
  bool _showOutline = false;
  bool _isDraggingFile = false;
  Map<int, GlobalKey> _headingKeys = {};
  final ValueNotifier<String> _selectedReaderText = ValueNotifier<String>('');

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.item.title);
    _contentController = TextEditingController(text: widget.item.contentMd);
  }

  /// Cycles Read -> Split -> Edit -> Read (triggered by Ctrl+E shortcut).
  void cycleViewMode() {
    final readOnlyExam = ref.read(examReadOnlyProvider).value ?? false;
    if (readOnlyExam) return;
    setState(() {
      _mode = switch (_mode) {
        NoteViewMode.read => NoteViewMode.split,
        NoteViewMode.split => NoteViewMode.edit,
        NoteViewMode.edit => NoteViewMode.read,
      };
    });
  }

  void toggleOutline() {
    setState(() => _showOutline = !_showOutline);
  }

  @override
  void didUpdateWidget(covariant VaultNotePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _saveDebounce?.cancel();
      _titleController.text = widget.item.title;
      _contentController.text = widget.item.contentMd;
      _headingKeys = {};
      _selectedReaderText.value = '';
    } else if (oldWidget.item.contentMd != widget.item.contentMd &&
        widget.item.contentMd != _contentController.text) {
      _contentController.text = widget.item.contentMd;
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _selectedReaderText.dispose();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _copySelectedReaderText() async {
    final text = _selectedReaderText.value.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _selectedReaderText.value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Texto copiado al portapapeles'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _scheduleAutosave() {
    _saveDebounce?.cancel();
    setState(() => _saving = true);
    _saveDebounce = Timer(const Duration(milliseconds: 350), () async {
      await ref.read(vaultItemsProvider.notifier).updateNoteContent(
            id: widget.item.id,
            title: _titleController.text,
            contentMd: _contentController.text,
          );
      if (mounted) setState(() => _saving = false);
    });
  }

  void _insertTemplate(String snippet) {
    final text = _contentController.text;
    final sel = _contentController.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final nextText = text.replaceRange(start, end, snippet);
    _contentController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + snippet.length),
    );
    _scheduleAutosave();
  }

  Future<void> _insertImageFromPicker() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      dialogTitle: 'Insertar imagen local en la nota',
    );
    if (picked.isEmpty) return;
    await _importAndInsertImages(
      picked.map((e) => e.path).whereType<String>().toList(),
    );
  }

  Future<void> _importAndInsertImages(List<String> imagePaths) async {
    if (imagePaths.isEmpty) return;
    final storage = VaultStorageService.instance;
    final buf = StringBuffer();
    for (final src in imagePaths) {
      if (!VaultStorageService.isImageExtension(src)) continue;
      final relPath = await storage.importImageFile(sourceFilePath: src);
      final caption = p.basenameWithoutExtension(src);
      buf.writeln('\n![$caption]($relPath)');
    }
    final snippet = buf.toString();
    if (snippet.isEmpty) return;
    if (_mode == NoteViewMode.read) {
      setState(() => _mode = NoteViewMode.split);
    }
    _insertTemplate(snippet);
  }

  Future<void> _handleDroppedPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final readOnlyExam = ref.read(examReadOnlyProvider).value ?? false;
    final images = <String>[];
    final others = <String>[];
    for (final path in paths) {
      if (!readOnlyExam && VaultStorageService.isImageExtension(path)) {
        images.add(path);
      } else {
        others.add(path);
      }
    }
    if (images.isNotEmpty) {
      await _importAndInsertImages(images);
    }
    if (others.isNotEmpty && mounted) {
      await VaultDialogs.confirmAndRunBatchImport(
        context,
        ref,
        paths: others,
        parentId: widget.item.parentId,
      );
    }
  }

  void _syncHeadingKeys(List<MdHeadingSummary> headings) {
    final next = <int, GlobalKey>{};
    for (final h in headings) {
      next[h.blockIndex] = _headingKeys[h.blockIndex] ?? GlobalKey();
    }
    _headingKeys = next;
  }

  void _scrollToHeading(MdHeadingSummary heading) {
    if (_mode == NoteViewMode.edit) {
      setState(() => _mode = NoteViewMode.split);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureHeadingVisible(heading.blockIndex);
      });
    } else {
      _ensureHeadingVisible(heading.blockIndex);
    }
  }

  void _ensureHeadingVisible(int blockIndex) {
    final targetCtx = _headingKeys[blockIndex]?.currentContext;
    if (targetCtx == null) return;
    Scrollable.ensureVisible(
      targetCtx,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
  }

  Future<void> _onToggleChecklist(int lineIndex, bool checked) async {
    final updated = VaultMarkdownParser.toggleChecklistLine(
      _contentController.text,
      lineIndex,
      checked,
    );
    _contentController.text = updated;
    await ref.read(vaultItemsProvider.notifier).updateNoteContent(
          id: widget.item.id,
          title: _titleController.text,
          contentMd: updated,
        );
  }

  @override
  Widget build(BuildContext context) {
    final readOnlyExam = ref.watch(examReadOnlyProvider).value ?? false;
    final allItems = ref.watch(vaultItemsProvider).value ?? [];
    final breadcrumb = buildBreadcrumbPath(allItems, widget.item);
    final effectiveMode = readOnlyExam ? NoteViewMode.read : _mode;
    final snippetCount =
        VaultMarkdownParser.countCodeSnippets(_contentController.text);
    final headings =
        VaultMarkdownParser.extractHeadings(_contentController.text);
    _syncHeadingKeys(headings);

    return DropTarget(
      onDragEntered: (_) {
        if (mounted) setState(() => _isDraggingFile = true);
      },
      onDragExited: (_) {
        if (mounted) setState(() => _isDraggingFile = false);
      },
      onDragDone: (details) async {
        if (mounted) setState(() => _isDraggingFile = false);
        final paths = details.files.map((f) => f.path).toList();
        await _handleDroppedPaths(paths);
      },
      child: Stack(
        children: [
          Container(
            color: AppColors.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.showTopBar)
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
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.edit_document,
                                  size: 15,
                                  color: AppColors.primary,
                                ),
                                const SizedBox(width: 8),
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 180),
                                  child: Text(
                                    '${_slug(widget.item.title)}.vault',
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.monoSm.copyWith(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.surfaceContainer,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    readOnlyExam
                                        ? 'SOLO LECTURA EXAMEN'
                                        : _saving
                                            ? 'Guardando...'
                                            : '● Autoguardado local',
                                    style: AppTypography.badgeMono.copyWith(
                                      color: readOnlyExam
                                          ? AppColors.bookAmber
                                          : AppColors.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (headings.isNotEmpty) ...[
                          Tooltip(
                            message: 'Índice de la nota (H1–H3)',
                            child: InkWell(
                              onTap: toggleOutline,
                              borderRadius: BorderRadius.circular(4),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _showOutline
                                      ? AppColors.surfaceHighest
                                      : AppColors.surfaceContainer,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: _showOutline
                                        ? AppColors.primary
                                            .withValues(alpha: 0.5)
                                        : AppColors.outlineVariant
                                            .withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.toc_rounded,
                                      size: 14,
                                      color: _showOutline
                                          ? AppColors.primary
                                          : AppColors.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Índice (${headings.length})',
                                      style: AppTypography.badgeMono.copyWith(
                                        color: _showOutline
                                            ? AppColors.primary
                                            : AppColors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (!readOnlyExam) _buildModeToggle(),
                      ],
                    ),
                  ),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: switch (effectiveMode) {
                          NoteViewMode.read => _buildReaderScroll(
                              breadcrumb: breadcrumb,
                              snippetCount: snippetCount,
                              readOnlyExam: readOnlyExam,
                            ),
                          NoteViewMode.edit =>
                            _buildEditorPane(readOnlyExam: readOnlyExam),
                          NoteViewMode.split => Row(
                              children: [
                                Expanded(
                                  child: _buildEditorPane(
                                    readOnlyExam: readOnlyExam,
                                  ),
                                ),
                                VerticalDivider(
                                  width: 1,
                                  color: AppColors.outlineVariant
                                      .withValues(alpha: 0.6),
                                ),
                                Expanded(
                                  child: _buildReaderScroll(
                                    breadcrumb: breadcrumb,
                                    snippetCount: snippetCount,
                                    readOnlyExam: readOnlyExam,
                                  ),
                                ),
                              ],
                            ),
                        },
                      ),
                      if (_showOutline && headings.isNotEmpty)
                        _buildOutlineSidebar(headings),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_isDraggingFile)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.primary,
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 30,
                          color: AppColors.primary,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Suelta imágenes para insertarlas en la nota\no archivos (.pdf/.md/.txt/código) para importarlos',
                          textAlign: TextAlign.center,
                          style: AppTypography.bodyMd.copyWith(
                            color: AppColors.onSurface,
                            fontWeight: FontWeight.w600,
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
    );
  }

  Widget _buildOutlineSidebar(List<MdHeadingSummary> headings) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: AppColors.surfaceLow,
        border: Border(
          left: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
            child: Row(
              children: [
                Text(
                  'ÍNDICE DE NOTA',
                  style: AppTypography.labelMono.copyWith(
                    color: AppColors.outline,
                    fontSize: 10.5,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: toggleOutline,
                  icon: const Icon(Icons.close_rounded, size: 15),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              itemCount: headings.length,
              itemBuilder: (ctx, idx) {
                final h = headings[idx];
                return InkWell(
                  onTap: () => _scrollToHeading(h),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      8.0 + (h.level - 1) * 10.0,
                      6,
                      8,
                      6,
                    ),
                    child: Text(
                      h.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodyMd.copyWith(
                        fontSize: h.level == 1 ? 13 : 12,
                        fontWeight:
                            h.level == 1 ? FontWeight.w600 : FontWeight.w400,
                        color: h.level == 1
                            ? AppColors.onSurface
                            : AppColors.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeToggle() {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.surfaceLowest,
        borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModeChip(
            label: 'Leer',
            selected: _mode == NoteViewMode.read,
            onTap: () => setState(() => _mode = NoteViewMode.read),
          ),
          _ModeChip(
            label: 'Split',
            selected: _mode == NoteViewMode.split,
            onTap: () => setState(() => _mode = NoteViewMode.split),
          ),
          _ModeChip(
            label: 'Editar',
            selected: _mode == NoteViewMode.edit,
            onTap: () => setState(() => _mode = NoteViewMode.edit),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderScroll({
    required String breadcrumb,
    required int snippetCount,
    required bool readOnlyExam,
  }) {
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (readOnlyExam)
                SelectableText(
                  _titleController.text,
                  style: AppTypography.headlineLg,
                )
              else
                TextField(
                  controller: _titleController,
                  onChanged: (_) => _scheduleAutosave(),
                  style: AppTypography.headlineLg,
                  decoration: const InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'Título de la nota...',
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (breadcrumb.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.folder_outlined,
                          size: 14,
                          color: AppColors.secondary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          breadcrumb,
                          style: AppTypography.monoSm.copyWith(
                            color: AppColors.secondary,
                          ),
                        ),
                      ],
                    ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.schedule_rounded,
                        size: 14,
                        color: AppColors.outline,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _formatTimestamp(widget.item.updatedAt),
                        style: AppTypography.monoSm.copyWith(
                          color: AppColors.outline,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.code_rounded,
                        size: 14,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '$snippetCount snippets de código',
                        style: AppTypography.monoSm.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),
              VaultMarkdownReader(
                contentMd: _contentController.text,
                readOnly: readOnlyExam,
                onToggleChecklist: _onToggleChecklist,
                searchHighlight: widget.searchHighlight,
                headingKeys: _headingKeys,
                onSelectionChanged: (text) => _selectedReaderText.value = text,
              ),
            ],
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable: _selectedReaderText,
          builder: (context, selectedText, _) {
            if (selectedText.trim().isEmpty) {
              return const SizedBox.shrink();
            }
            return Positioned(
              right: 20,
              bottom: widget.showTopBar ? 20 : 76,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _copySelectedReaderText,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHighest.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.55),
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
                        const Icon(
                          Icons.copy_rounded,
                          size: 15,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Copiar selección',
                          style: AppTypography.labelMono.copyWith(
                            color: AppColors.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildEditorPane({required bool readOnlyExam}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceLow,
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
                PopupMenuButton<String>(
                  tooltip: 'Insertar bloque de código',
                  onSelected: (lang) {
                    final template = switch (lang) {
                      'sql' =>
                        '\n```sql\n-- file: queries/consulta.sql\nSELECT *\nFROM tabla;\n```\n',
                      'python' =>
                        '\n```python\n# file: script.py\ndef resolver():\n    pass\n```\n',
                      'java' =>
                        '\n```java\n// file: Main.java\npublic class Main {\n  public static void main(String[] args) {}\n}\n```\n',
                      'cpp' =>
                        '\n```cpp\n// file: main.cpp\n#include <iostream>\nint main() { return 0; }\n```\n',
                      'dart' =>
                        '\n```dart\n// file: main.dart\nvoid main() {\n  print(\'Hola\');\n}\n```\n',
                      'javascript' =>
                        '\n```javascript\n// file: app.js\nconsole.log(\'Hola\');\n```\n',
                      'php' =>
                        '\n```php\n// file: index.php\n<?php\necho "<h1>Hola desde PHP</h1>";\n?>\n```\n',
                      'html' =>
                        '\n```html\n<!DOCTYPE html>\n<html>\n<body>\n  <h1>Vista HTML</h1>\n  <p>Contenido de ejemplo.</p>\n</body>\n</html>\n```\n',
                      _ => '\n```bash\n# Comando\necho "ok"\n```\n',
                    };
                    _insertTemplate(template);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'sql', child: Text('Código SQL')),
                    PopupMenuItem(value: 'python', child: Text('Código Python')),
                    PopupMenuItem(value: 'java', child: Text('Código Java')),
                    PopupMenuItem(value: 'php', child: Text('Código PHP')),
                    PopupMenuItem(value: 'html', child: Text('Código HTML')),
                    PopupMenuItem(value: 'cpp', child: Text('Código C / C++')),
                    PopupMenuItem(value: 'dart', child: Text('Código Dart')),
                    PopupMenuItem(
                        value: 'javascript', child: Text('Código JS / TS')),
                    PopupMenuItem(value: 'bash', child: Text('Comando Bash')),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainer,
                      borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                      border: Border.all(
                        color: AppColors.outlineVariant.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.code_rounded,
                          size: 14,
                          color: AppColors.secondary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '+ Código',
                          style: AppTypography.badgeMono.copyWith(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.arrow_drop_down_rounded,
                          size: 15,
                          color: AppColors.outline,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _QuickInsertChip(
                  icon: Icons.bolt_rounded,
                  label: '+ Tip',
                  onTap: () => _insertTemplate(
                    '\n> [!TIP]\n> **TIP DE EXAMEN:** Recordatorio clave aquí.\n',
                  ),
                ),
                const SizedBox(width: 8),
                _QuickInsertChip(
                  icon: Icons.school_outlined,
                  label: '+ Examen',
                  onTap: () => _insertTemplate(
                    '\n> [!EXAM]\n> **PREGUNTA FRECUENTE:** Concepto que suele caer.\n',
                  ),
                ),
                const SizedBox(width: 8),
                _QuickInsertChip(
                  icon: Icons.warning_amber_rounded,
                  label: '+ Aviso',
                  onTap: () => _insertTemplate(
                    '\n> [!WARN]\n> **ERROR COMÚN:** Detalle importante a evitar.\n',
                  ),
                ),
                const SizedBox(width: 8),
                _QuickInsertChip(
                  icon: Icons.table_chart_outlined,
                  label: '+ Tabla',
                  onTap: () => _insertTemplate(
                    '\n| Concepto | Complejidad / Uso | Nota |\n| --- | --- | --- |\n| Ejemplo | O(n log n) | Detalle |\n',
                  ),
                ),
                const SizedBox(width: 8),
                _QuickInsertChip(
                  icon: Icons.add_photo_alternate_outlined,
                  label: '+ Imagen',
                  onTap: _insertImageFromPicker,
                ),
                const SizedBox(width: 8),
                _QuickInsertChip(
                  icon: Icons.check_box_outlined,
                  label: '+ Checklist',
                  onTap: () => _insertTemplate('\n- [ ] Punto por repasar\n'),
                ),
                const SizedBox(width: 8),
                _QuickInsertChip(
                  icon: Icons.title_rounded,
                  label: '+ Sección',
                  onTap: () => _insertTemplate('\n## Nueva sección\n'),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _contentController,
              readOnly: readOnlyExam,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              onChanged: (_) => _scheduleAutosave(),
              style: AppTypography.monoMd.copyWith(height: 1.6),
              decoration: InputDecoration(
                fillColor: AppColors.surfaceLowest,
                hintText:
                    'Escribe en Markdown (usa ```sql para código, > [!TIP] para avisos y - [ ] para checklists)...',
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _slug(String title) {
    final clean = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return clean.isEmpty ? 'nota' : clean;
  }

  String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} $h:$m';
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
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
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceHighest : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: AppTypography.badgeMono.copyWith(
            color: selected ? AppColors.primary : AppColors.outline,
          ),
        ),
      ),
    );
  }
}

class _QuickInsertChip extends StatelessWidget {
  const _QuickInsertChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
          border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppColors.secondary),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppTypography.badgeMono.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
