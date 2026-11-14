import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/type_badge.dart';
import '../../vault_tree/application/vault_providers.dart';
import '../../vault_tree/domain/vault_item.dart';
import '../domain/search_result.dart';

class SearchOpenSelection {
  const SearchOpenSelection({
    required this.result,
    required this.openInSplit,
  });

  final SearchResult result;
  final bool openInSplit;
}

/// Global Command-K Superbuscador modal matching `vaultstudy_superbuscador_global`.
class SuperSearchDialog extends ConsumerStatefulWidget {
  const SuperSearchDialog({super.key, this.initialQuery = ''});

  final String initialQuery;

  static Future<SearchOpenSelection?> show(
    BuildContext context, {
    String initialQuery = '',
  }) {
    return showDialog<SearchOpenSelection>(
      context: context,
      barrierColor: AppColors.surfaceLowest.withValues(alpha: 0.82),
      builder: (_) => SuperSearchDialog(initialQuery: initialQuery),
    );
  }

  @override
  ConsumerState<SuperSearchDialog> createState() => _SuperSearchDialogState();
}

class _SuperSearchDialogState extends ConsumerState<SuperSearchDialog> {
  late final TextEditingController _queryController;
  final FocusNode _inputFocus = FocusNode();

  SearchFilter _filter = SearchFilter.all;
  List<SearchResult> _results = [];
  Map<SearchFilter, int> _counts = {
    for (final f in SearchFilter.values) f: 0,
  };
  int _selectedIndex = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _runSearch();
  }

  @override
  void dispose() {
    _queryController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final repo = ref.read(vaultRepositoryProvider);
    final q = _queryController.text;
    final allFuture = repo.search(q, filter: SearchFilter.all);
    final pdfFuture = repo.search(q, filter: SearchFilter.pdfs);
    final notesFuture = repo.search(q, filter: SearchFilter.notes);
    final codeFuture = repo.search(q, filter: SearchFilter.codeOnly);

    final all = await allFuture;
    final pdfs = await pdfFuture;
    final notes = await notesFuture;
    final code = await codeFuture;

    if (!mounted) return;
    final activeList = switch (_filter) {
      SearchFilter.all => all,
      SearchFilter.pdfs => pdfs,
      SearchFilter.notes => notes,
      SearchFilter.codeOnly => code,
    };

    setState(() {
      _counts = {
        SearchFilter.all: all.length,
        SearchFilter.pdfs: pdfs.length,
        SearchFilter.notes: notes.length,
        SearchFilter.codeOnly: code.length,
      };
      _results = activeList;
      _selectedIndex = activeList.isEmpty
          ? 0
          : _selectedIndex.clamp(0, activeList.length - 1);
      _loading = false;
    });
  }

  void _cycleFilter() {
    final idx = SearchFilter.values.indexOf(_filter);
    final next = SearchFilter.values[(idx + 1) % SearchFilter.values.length];
    setState(() {
      _filter = next;
      _selectedIndex = 0;
    });
    _runSearch();
  }

  void _confirmSelection({required bool split}) {
    if (_results.isEmpty) return;
    final target = _results[_selectedIndex.clamp(0, _results.length - 1)];
    Navigator.pop(
      context,
      SearchOpenSelection(result: target, openInSplit: split),
    );
  }

  @override
  Widget build(BuildContext context) {
    final noteResults = _results
        .where((r) => r.item.type == VaultItemType.note)
        .toList();
    final pdfResults =
        _results.where((r) => r.item.type.isDocument).toList();
    final ordered = [...noteResults, ...pdfResults];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () {
          if (ordered.isEmpty) return;
          setState(
            () => _selectedIndex = (_selectedIndex + 1) % ordered.length,
          );
        },
        const SingleActivator(LogicalKeyboardKey.arrowUp): () {
          if (ordered.isEmpty) return;
          setState(
            () => _selectedIndex =
                (_selectedIndex - 1 + ordered.length) % ordered.length,
          );
        },
        const SingleActivator(LogicalKeyboardKey.tab): _cycleFilter,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            _confirmSelection(split: true),
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
            _confirmSelection(split: true),
      },
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        backgroundColor: AppColors.surfaceLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: AppColors.secondary.withValues(alpha: 0.45),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Search Header + Filter Pills
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(14),
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: AppColors.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.search_rounded,
                          color: AppColors.secondary,
                          size: 26,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _queryController,
                            focusNode: _inputFocus,
                            autofocus: true,
                            style: AppTypography.headlineSm.copyWith(
                              fontSize: 18,
                            ),
                            decoration: const InputDecoration(
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              hintText:
                                  'Buscar en apuntes, PDFs, código o fórmulas...',
                            ),
                            onChanged: (_) => _runSearch(),
                            onSubmitted: (_) => _confirmSelection(split: false),
                          ),
                        ),
                        InkWell(
                          onTap: () => Navigator.pop(context),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHighest,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppColors.outlineVariant,
                              ),
                            ),
                            child: Text(
                              'ESC',
                              style: AppTypography.badgeMono.copyWith(
                                color: AppColors.outline,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final f in SearchFilter.values) ...[
                            _FilterPill(
                              filter: f,
                              count: _counts[f] ?? 0,
                              active: _filter == f,
                              onTap: () {
                                setState(() {
                                  _filter = f;
                                  _selectedIndex = 0;
                                });
                                _runSearch();
                              },
                            ),
                            const SizedBox(width: 8),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Results List
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : ordered.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(40),
                            child: Center(
                              child: Text(
                                'Sin coincidencias locales para "${_queryController.text}".',
                                style: AppTypography.bodyMd.copyWith(
                                  color: AppColors.outline,
                                ),
                              ),
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.all(10),
                            children: [
                              if (noteResults.isNotEmpty) ...[
                                _SectionHeader(
                                  title: 'DENTRO DE TUS NOTAS',
                                  subtitle:
                                      '${noteResults.length} coincidencias',
                                ),
                                for (var i = 0; i < noteResults.length; i++)
                                  _ResultRow(
                                    result: noteResults[i],
                                    query: _queryController.text,
                                    selected: i == _selectedIndex,
                                    onTap: () => Navigator.pop(
                                      context,
                                      SearchOpenSelection(
                                        result: noteResults[i],
                                        openInSplit: true,
                                      ),
                                    ),
                                  ),
                              ],
                              if (pdfResults.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                const _SectionHeader(
                                  title: 'DENTRO DE ARCHIVOS PDF',
                                  subtitle: 'Indexado localmente',
                                ),
                                for (var j = 0; j < pdfResults.length; j++)
                                  _ResultRow(
                                    result: pdfResults[j],
                                    query: _queryController.text,
                                    selected:
                                        (noteResults.length + j) ==
                                        _selectedIndex,
                                    onTap: () => Navigator.pop(
                                      context,
                                      SearchOpenSelection(
                                        result: pdfResults[j],
                                        openInSplit: false,
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
              ),
              // Footer shortcuts bar
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(14),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: AppColors.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: const [
                    _KbdHint(kbd: '↑↓', label: 'Navegar'),
                    _KbdHint(kbd: '↵', label: 'Abrir archivo'),
                    _KbdHint(
                      kbd: 'Ctrl+↵',
                      label: 'Abrir en vista dividida',
                      accent: AppColors.secondary,
                    ),
                    _KbdHint(kbd: 'Tab', label: 'Cambiar filtro'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.filter,
    required this.count,
    required this.active,
    required this.onTap,
  });

  final SearchFilter filter;
  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tag = switch (filter) {
      SearchFilter.all => null,
      SearchFilter.pdfs => ('PDF', AppColors.error),
      SearchFilter.notes => ('NOTA', AppColors.primary),
      SearchFilter.codeOnly => ('SRC', AppColors.secondary),
    };

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? AppColors.secondary.withValues(alpha: 0.16)
              : AppColors.surfaceHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? AppColors.secondary.withValues(alpha: 0.7)
                : AppColors.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tag != null) ...[
              Text(
                tag.$1,
                style: AppTypography.badgeMono.copyWith(color: tag.$2),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              '${filter.label} ($count)',
              style: AppTypography.monoSm.copyWith(
                color: active ? AppColors.secondary : AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: AppTypography.labelMono.copyWith(
              color: AppColors.outline,
              fontSize: 10.5,
            ),
          ),
          Text(
            subtitle,
            style: AppTypography.monoSm.copyWith(
              color: AppColors.outline,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    required this.query,
    required this.selected,
    required this.onTap,
  });

  final SearchResult result;
  final String query;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDoc = result.item.type.isDocument;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppBreakpoints.radiusLg),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.secondary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppBreakpoints.radiusLg),
          border: Border.all(
            color: selected
                ? AppColors.secondary.withValues(alpha: 0.45)
                : Colors.transparent,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TypeBadge(
                  type: result.item.type,
                  customLabel: result.isCodeMatch ? 'SRC' : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: result.item.title,
                          style: AppTypography.headlineSm.copyWith(fontSize: 14.5),
                        ),
                        TextSpan(
                          text: '  •  ${result.breadcrumb}',
                          style: AppTypography.monoSm.copyWith(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (isDoc && result.matchedPageNumber != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHighest,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: AppColors.error.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      'Ir a Pág ${result.matchedPageNumber}',
                      style: AppTypography.badgeMono.copyWith(
                        color: AppColors.error,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.secondary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '↵ Abrir en Split',
                      style: AppTypography.badgeMono.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                  ),
              ],
            ),
            if (result.snippet.isNotEmpty) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  result.snippet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodySm,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _KbdHint extends StatelessWidget {
  const _KbdHint({
    required this.kbd,
    required this.label,
    this.accent,
  });

  final String kbd;
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.surfaceHighest,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppColors.outlineVariant),
          ),
          child: Text(
            kbd,
            style: AppTypography.badgeMono.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: AppTypography.monoSm.copyWith(
            color: accent ?? AppColors.outline,
          ),
        ),
      ],
    );
  }
}
