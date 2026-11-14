import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/constants/app_breakpoints.dart';
import '../../../../core/database/database_helper.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../application/markdown_parser.dart';
import 'code_block_card.dart';

/// Renders VaultStudy Markdown notes with `Inter` reading typography,
/// `Space Grotesk` headings, copyable `CodeBlockCard`s, tables, local images,
/// callouts, and interactive checklists.
class VaultMarkdownReader extends StatelessWidget {
  const VaultMarkdownReader({
    super.key,
    required this.contentMd,
    this.onToggleChecklist,
    this.readOnly = false,
    this.searchHighlight = '',
    this.headingKeys,
  });

  final String contentMd;
  final void Function(int lineIndex, bool checked)? onToggleChecklist;
  final bool readOnly;
  final String searchHighlight;
  final Map<int, GlobalKey>? headingKeys;

  @override
  Widget build(BuildContext context) {
    final blocks = VaultMarkdownParser.parse(contentMd);
    if (blocks.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surfaceLow,
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Text(
          'Esta nota aún no tiene contenido. Cambia a modo Editar para empezar a escribir apuntes o bloques de código.',
          style: AppTypography.bodyMd.copyWith(color: AppColors.outline),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          _buildBlock(blocks[i], i),
          if (i < blocks.length - 1) const SizedBox(height: 14),
        ],
      ],
    );
  }

  Widget _buildBlock(VaultMdBlock block, int blockIndex) {
    return switch (block) {
      MdHeadingBlock b => Padding(
          key: headingKeys?[blockIndex],
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'H${b.level}',
                  style: AppTypography.badgeMono.copyWith(
                    color: b.level == 1 ? AppColors.primary : AppColors.secondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  b.text,
                  style: switch (b.level) {
                    1 => AppTypography.headlineLg,
                    2 => AppTypography.headlineMd,
                    _ => AppTypography.headlineSm,
                  },
                ),
              ),
            ],
          ),
        ),
      MdParagraphBlock b => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceLow,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          ),
          child: _RichInlineText(
            text: b.text,
            baseStyle: AppTypography.bodyLg.copyWith(fontSize: 15),
            searchHighlight: searchHighlight,
          ),
        ),
      MdCodeBlock b => CodeBlockCard(
          language: b.language,
          code: b.code,
          filePath: b.filePath,
        ),
      MdCalloutBlock b => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  size: 18,
                  color: AppColors.onPrimary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${b.tag} DE EXAMEN',
                          style: AppTypography.labelMono.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'PRIORIDAD ALTA',
                            style: AppTypography.badgeMono.copyWith(
                              color: AppColors.primaryFixed,
                              fontSize: 9.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _RichInlineText(
                      text: b.text,
                      baseStyle: AppTypography.bodyMd.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                      searchHighlight: searchHighlight,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      MdChecklistBlock b => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            border: Border.all(
              color: AppColors.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'BITÁCORA RÁPIDA (LOCAL)',
                    style: AppTypography.labelMono.copyWith(
                      color: AppColors.outline,
                      fontSize: 10.5,
                    ),
                  ),
                  Text(
                    '${b.entries.where((e) => !e.checked).length} pendientes',
                    style: AppTypography.monoSm.copyWith(
                      color: AppColors.secondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final entry in b.entries)
                InkWell(
                  onTap: readOnly || onToggleChecklist == null
                      ? null
                      : () => onToggleChecklist!(
                            entry.lineIndex,
                            !entry.checked,
                          ),
                  borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          entry.checked
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 18,
                          color: entry.checked
                              ? AppColors.primary
                              : AppColors.outline,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _RichInlineText(
                            text: entry.text,
                            baseStyle: AppTypography.bodySm.copyWith(
                              color: entry.checked
                                  ? AppColors.onSurfaceVariant
                                  : AppColors.onSurface,
                              decoration: entry.checked
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                            searchHighlight: searchHighlight,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      MdBulletListBlock b => Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceLow,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in b.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '• ',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Expanded(
                        child: _RichInlineText(
                          text: item,
                          baseStyle: AppTypography.bodyMd,
                          searchHighlight: searchHighlight,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      MdTableBlock b => Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceLow,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            border: Border.all(
              color: AppColors.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 38,
                dataRowMinHeight: 34,
                dataRowMaxHeight: 56,
                horizontalMargin: 14,
                columnSpacing: 22,
                headingRowColor: WidgetStatePropertyAll(
                  AppColors.surfaceHighest.withValues(alpha: 0.75),
                ),
                dividerThickness: 0.6,
                columns: [
                  for (final header in b.headers)
                    DataColumn(
                      label: Text(
                        header,
                        style: AppTypography.labelMono.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
                rows: [
                  for (var r = 0; r < b.rows.length; r++)
                    DataRow(
                      color: WidgetStatePropertyAll(
                        r.isEven
                            ? Colors.transparent
                            : AppColors.surfaceContainer.withValues(alpha: 0.45),
                      ),
                      cells: [
                        for (final cell in b.rows[r])
                          DataCell(
                            _RichInlineText(
                              text: cell,
                              baseStyle: AppTypography.bodyMd.copyWith(
                                fontSize: 13,
                              ),
                              searchHighlight: searchHighlight,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      MdImageBlock b => _VaultImageBlockView(
          imagePath: b.path,
          alt: b.alt,
        ),
    };
  }
}

class _VaultImageBlockView extends StatefulWidget {
  const _VaultImageBlockView({
    required this.imagePath,
    required this.alt,
  });

  final String imagePath;
  final String alt;

  @override
  State<_VaultImageBlockView> createState() => _VaultImageBlockViewState();
}

class _VaultImageBlockViewState extends State<_VaultImageBlockView> {
  Future<File?>? _resolvedFuture;

  @override
  void initState() {
    super.initState();
    _resolvedFuture = _resolveLocalImage();
  }

  @override
  void didUpdateWidget(covariant _VaultImageBlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _resolvedFuture = _resolveLocalImage();
    }
  }

  Future<File?> _resolveLocalImage() async {
    final raw = widget.imagePath.trim();
    if (raw.isEmpty ||
        raw.startsWith('http://') ||
        raw.startsWith('https://')) {
      return null;
    }
    final resolved = await DatabaseHelper.instance.resolveVaultFilePath(raw);
    final file = File(resolved);
    if (await file.exists()) return file;
    return null;
  }

  void _openLightbox(BuildContext context, File file) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surfaceLowest,
        insetPadding: const EdgeInsets.all(24),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Image.file(file, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surfaceContainer,
                ),
              ),
            ),
            if (widget.alt.isNotEmpty)
              Positioned(
                left: 16,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainer.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    widget.alt,
                    style: AppTypography.labelMono.copyWith(fontSize: 11.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _resolvedFuture,
      builder: (context, snap) {
        final file = snap.data;
        if (snap.connectionState == ConnectionState.waiting) {
          return Container(
            height: 120,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surfaceLow,
              borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            ),
            child: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (file == null) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceLow,
              borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
              border: Border.all(
                color: AppColors.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.broken_image_outlined,
                  size: 18,
                  color: AppColors.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.alt.isNotEmpty
                        ? '${widget.alt} (${widget.imagePath})'
                        : 'Imagen local no disponible: ${widget.imagePath}',
                    style: AppTypography.labelMono.copyWith(
                      fontSize: 11.5,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.surfaceLow,
            borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
            border: Border.all(
              color: AppColors.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () => _openLightbox(context, file),
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                      width: double.infinity,
                    ),
                  ),
                ),
              ),
              if (widget.alt.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(
                      Icons.image_outlined,
                      size: 13,
                      color: AppColors.outline,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.alt,
                        style: AppTypography.labelMono.copyWith(
                          fontSize: 11,
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Text(
                      'Clic para ampliar',
                      style: AppTypography.badgeMono.copyWith(
                        fontSize: 10,
                        color: AppColors.outline,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RichInlineText extends StatelessWidget {
  const _RichInlineText({
    required this.text,
    required this.baseStyle,
    this.searchHighlight = '',
  });

  final String text;
  final TextStyle baseStyle;
  final String searchHighlight;

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      TextSpan(
        style: baseStyle,
        children: _parseInlineSpans(context, text, baseStyle),
      ),
    );
  }

  List<InlineSpan> _parseInlineSpans(
    BuildContext context,
    String input,
    TextStyle base,
  ) {
    final spans = <InlineSpan>[];
    final tokenRx = RegExp(
      r'(`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\([^)]+\))',
    );
    final linkRx = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)$');
    var lastEnd = 0;

    for (final match in tokenRx.allMatches(input)) {
      if (match.start > lastEnd) {
        _addPlainWithHighlight(
          spans,
          input.substring(lastEnd, match.start),
          base,
        );
      }
      final token = match.group(0)!;
      if (token.startsWith('`') && token.endsWith('`')) {
        final inner = token.substring(1, token.length - 1);
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.surfaceHighest,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.4),
                  width: 0.7,
                ),
              ),
              child: Text(
                inner,
                style: AppTypography.monoSm.copyWith(
                  color: AppColors.secondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );
      } else if (token.startsWith('**') && token.endsWith('**')) {
        final inner = token.substring(2, token.length - 2);
        _addPlainWithHighlight(
          spans,
          inner,
          base.copyWith(fontWeight: FontWeight.w700, color: AppColors.onSurface),
        );
      } else {
        final linkMatch = linkRx.firstMatch(token);
        if (linkMatch != null) {
          final label = linkMatch.group(1)!;
          final url = linkMatch.group(2)!.trim();
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Tooltip(
                message: '$url (clic para copiar)',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Enlace copiado: $url'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    child: Text(
                      label,
                      style: base.copyWith(
                        color: AppColors.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: AppColors.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }
      }
      lastEnd = match.end;
    }

    if (lastEnd < input.length) {
      _addPlainWithHighlight(spans, input.substring(lastEnd), base);
    }
    return spans;
  }

  void _addPlainWithHighlight(
    List<InlineSpan> spans,
    String textSegment,
    TextStyle style,
  ) {
    final q = searchHighlight.trim();
    if (q.isEmpty) {
      spans.add(TextSpan(text: textSegment, style: style));
      return;
    }
    final lower = textSegment.toLowerCase();
    final qLower = q.toLowerCase();
    var idx = 0;
    while (true) {
      final hit = lower.indexOf(qLower, idx);
      if (hit < 0) {
        spans.add(TextSpan(text: textSegment.substring(idx), style: style));
        break;
      }
      if (hit > idx) {
        spans.add(TextSpan(text: textSegment.substring(idx, hit), style: style));
      }
      spans.add(
        TextSpan(
          text: textSegment.substring(hit, hit + q.length),
          style: style.copyWith(
            backgroundColor: AppColors.secondary.withValues(alpha: 0.3),
            color: AppColors.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      idx = hit + q.length;
    }
  }
}
