import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/constants/app_breakpoints.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../application/code_execution_service.dart';

/// Terminal-styled code block card with line numbers, syntax highlighting,
/// 1-click copy, in-app/browser HTML preview, and local snippet execution.
class CodeBlockCard extends StatefulWidget {
  const CodeBlockCard({
    super.key,
    required this.language,
    required this.code,
    this.filePath,
  });

  final String language;
  final String code;
  final String? filePath;

  @override
  State<CodeBlockCard> createState() => _CodeBlockCardState();
}

class _CodeBlockCardState extends State<CodeBlockCard> {
  bool _copied = false;
  bool _showHtmlPreview = false;
  bool _running = false;
  bool _showOutputAsHtml = true;
  CodeExecutionResult? _execResult;
  Timer? _resetTimer;

  @override
  void didUpdateWidget(covariant CodeBlockCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code || oldWidget.language != widget.language) {
      _execResult = null;
    }
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  static const Map<String, TextStyle> _vaultHighlightTheme = {
    'root': TextStyle(
      backgroundColor: Colors.transparent,
      color: AppColors.onSurface,
    ),
    'keyword': TextStyle(
      color: AppColors.primary,
      fontWeight: FontWeight.w600,
    ),
    'built_in': TextStyle(
      color: AppColors.secondary,
      fontWeight: FontWeight.w600,
    ),
    'type': TextStyle(color: AppColors.secondary),
    'literal': TextStyle(color: AppColors.secondary),
    'number': TextStyle(color: AppColors.secondary),
    'string': TextStyle(color: AppColors.tertiary),
    'comment': TextStyle(
      color: AppColors.outline,
      fontStyle: FontStyle.italic,
    ),
    'title': TextStyle(color: AppColors.primaryFixed),
    'function': TextStyle(color: AppColors.secondary),
    'attr': TextStyle(color: AppColors.primary),
    'attribute': TextStyle(color: AppColors.primary),
    'selector-class': TextStyle(color: AppColors.primary),
    'selector-tag': TextStyle(color: AppColors.secondary),
    'property': TextStyle(color: AppColors.secondary),
    'variable': TextStyle(color: AppColors.onSurface),
    'operator': TextStyle(color: AppColors.onSurfaceVariant),
    'punctuation': TextStyle(color: AppColors.onSurfaceVariant),
  };

  Future<void> _copyCode() async {
    _resetTimer?.cancel();
    setState(() => _copied = true);
    _resetTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _copied = false);
    });
    await Clipboard.setData(ClipboardData(text: widget.code));
  }

  Future<void> _runSnippet() async {
    if (_running) return;
    setState(() => _running = true);
    final res = await VaultCodeExecutionService.instance.runSnippet(
      language: widget.language,
      code: widget.code,
      filePathHint: widget.filePath,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _execResult = res;
      _showOutputAsHtml = res.isHtmlOutput;
    });
  }

  Future<void> _openInBrowser(String html) async {
    try {
      final uri = await VaultCodeExecutionService.instance
          .openHtmlInLocalBrowser(html);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Vista web local abierta en $uri'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo abrir el navegador: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.code.isEmpty ? [''] : widget.code.split('\n');
    final isWeb = VaultCodeExecutionService.isWebPreviewLanguage(widget.language);
    final isRunnable = VaultCodeExecutionService.canExecuteOnCurrentPlatform &&
        VaultCodeExecutionService.isRunnableLanguage(widget.language);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceLowest,
        borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Code block header (wraps gracefully on narrow phone screens)
          Container(
            color: AppColors.surfaceHigh,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _WindowDot(color: AppColors.error),
                    const SizedBox(width: 5),
                    const _WindowDot(color: AppColors.secondaryContainer),
                    const SizedBox(width: 5),
                    const _WindowDot(color: AppColors.primary),
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
                        widget.language.toUpperCase(),
                        style: AppTypography.badgeMono.copyWith(
                          color: AppColors.secondary,
                        ),
                      ),
                    ),
                    if (widget.filePath != null &&
                        widget.filePath!.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          widget.filePath!,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.monoSm.copyWith(
                            color: AppColors.outline,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (isWeb) ...[
                      _HeaderActionChip(
                        icon: _showHtmlPreview
                            ? Icons.code_rounded
                            : Icons.public_rounded,
                        label: _showHtmlPreview ? 'Código' : 'Vista Web',
                        active: _showHtmlPreview,
                        onTap: () => setState(
                          () => _showHtmlPreview = !_showHtmlPreview,
                        ),
                      ),
                      _HeaderActionChip(
                        icon: Icons.open_in_browser_rounded,
                        label: 'Navegador',
                        onTap: () => _openInBrowser(widget.code),
                      ),
                    ],
                    if (isRunnable)
                      _HeaderActionChip(
                        icon: _running
                            ? Icons.hourglass_top_rounded
                            : Icons.play_arrow_rounded,
                        label: _running ? 'Ejecutando...' : 'Ejecutar',
                        active: _execResult != null,
                        accentColor: AppColors.primary,
                        onTap: _running ? null : _runSnippet,
                      ),
                    _HeaderActionChip(
                      icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                      label: _copied ? '¡Copiado!' : 'Copiar código',
                      active: _copied,
                      accentColor: AppColors.primary,
                      onTap: _copyCode,
                    ),
                  ],
                ),
              ],
            ),
          ),
          // HTML live visual preview or syntax-highlighted source code
          if (isWeb && _showHtmlPreview)
            Container(
              color: const Color(0xFFF8FAFC),
              padding: const EdgeInsets.all(16),
              constraints: const BoxConstraints(minHeight: 80, maxHeight: 420),
              child: SingleChildScrollView(
                child: HtmlWidget(
                  widget.code,
                  textStyle: const TextStyle(
                    color: Color(0xFF1E293B),
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < lines.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: Text(
                            '${i + 1}',
                            style: AppTypography.monoMd.copyWith(
                              fontSize: 12.5,
                              height: 1.55,
                              color: AppColors.outline.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                    ],
                  ),
                  HighlightView(
                    widget.code,
                    language: _normalizeLanguage(widget.language),
                    theme: _vaultHighlightTheme,
                    padding: EdgeInsets.zero,
                    textStyle: AppTypography.monoMd.copyWith(
                      fontSize: 12.5,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
          // Execution output console / PHP rendered web output
          if (_execResult != null) _buildOutputPanel(_execResult!),
        ],
      ),
    );
  }

  Widget _buildOutputPanel(CodeExecutionResult result) {
    final hasHtml = result.stdout.isNotEmpty && result.isHtmlOutput;
    final statusColor = result.isSuccess ? AppColors.primary : AppColors.error;
    final statusLabel = result.missingRuntime
        ? 'BINARIO NO ENCONTRADO'
        : result.timedOut
            ? 'TIMEOUT'
            : result.isSuccess
                ? 'OK • ${result.durationMs} ms'
                : 'EXIT ${result.exitCode} • ${result.durationMs} ms';

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        border: Border(
          top: BorderSide(
            color: statusColor.withValues(alpha: 0.45),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: AppColors.surfaceLow,
            child: Row(
              children: [
                Icon(
                  result.isSuccess
                      ? Icons.terminal_rounded
                      : Icons.error_outline_rounded,
                  size: 14,
                  color: statusColor,
                ),
                const SizedBox(width: 6),
                Text(
                  statusLabel,
                  style: AppTypography.badgeMono.copyWith(color: statusColor),
                ),
                const Spacer(),
                if (hasHtml) ...[
                  _HeaderActionChip(
                    icon: _showOutputAsHtml
                        ? Icons.terminal_rounded
                        : Icons.public_rounded,
                    label: _showOutputAsHtml ? 'Consola' : 'Vista Web',
                    active: _showOutputAsHtml,
                    onTap: () =>
                        setState(() => _showOutputAsHtml = !_showOutputAsHtml),
                  ),
                  const SizedBox(width: 6),
                  _HeaderActionChip(
                    icon: Icons.open_in_browser_rounded,
                    label: 'Navegador',
                    onTap: () => _openInBrowser(result.stdout),
                  ),
                  const SizedBox(width: 6),
                ],
                InkWell(
                  onTap: () => setState(() => _execResult = null),
                  borderRadius: BorderRadius.circular(4),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: AppColors.outline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (hasHtml && _showOutputAsHtml)
            Container(
              color: const Color(0xFFF8FAFC),
              padding: const EdgeInsets.all(14),
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: HtmlWidget(
                  result.stdout,
                  textStyle: const TextStyle(
                    color: Color(0xFF1E293B),
                    fontSize: 13.5,
                    height: 1.45,
                  ),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (result.errorMessage != null)
                    SelectableText(
                      result.errorMessage!,
                      style: AppTypography.monoSm.copyWith(
                        color: AppColors.error,
                        height: 1.45,
                      ),
                    ),
                  if (result.stdout.isNotEmpty)
                    SelectableText(
                      result.stdout,
                      style: AppTypography.monoSm.copyWith(
                        color: AppColors.onSurface,
                        height: 1.45,
                      ),
                    ),
                  if (result.stderr.isNotEmpty) ...[
                    if (result.stdout.isNotEmpty || result.errorMessage != null)
                      const SizedBox(height: 6),
                    SelectableText(
                      result.stderr,
                      style: AppTypography.monoSm.copyWith(
                        color: AppColors.error,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (result.stdout.isEmpty &&
                      result.stderr.isEmpty &&
                      result.errorMessage == null)
                    Text(
                      '(El programa finalizó sin salida por consola)',
                      style: AppTypography.monoSm.copyWith(
                        color: AppColors.outline,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _normalizeLanguage(String lang) {
    final lower = lang.toLowerCase();
    return switch (lower) {
      'js' => 'javascript',
      'ts' => 'typescript',
      'py' => 'python',
      'sh' || 'bash' => 'bash',
      'html' || 'htm' => 'xml',
      'c#' => 'cs',
      'ps1' => 'powershell',
      'kt' => 'kotlin',
      _ => lower,
    };
  }
}

class _HeaderActionChip extends StatelessWidget {
  const _HeaderActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.accentColor = AppColors.secondary,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
          border: Border.all(
            color: active
                ? accentColor.withValues(alpha: 0.65)
                : AppColors.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: active ? accentColor : AppColors.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppTypography.badgeMono.copyWith(
                color: active ? accentColor : AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowDot extends StatelessWidget {
  const _WindowDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.8),
        shape: BoxShape.circle,
      ),
    );
  }
}
