import '../../vault_tree/domain/vault_item.dart';

enum SearchFilter {
  all('Todo'),
  pdfs('En PDFs'),
  notes('En Notas'),
  codeOnly('Solo Código');

  const SearchFilter(this.label);
  final String label;
}

class SearchResult {
  const SearchResult({
    required this.item,
    required this.breadcrumb,
    required this.snippet,
    this.matchedPageNumber,
    this.isCodeMatch = false,
  });

  final VaultItem item;
  final String breadcrumb;
  final String snippet;
  final int? matchedPageNumber;
  final bool isCodeMatch;
}
