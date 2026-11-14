/// Structured block model parsed from enriched VaultStudy Markdown (`content_md`).
sealed class VaultMdBlock {
  const VaultMdBlock();
}

class MdHeadingBlock extends VaultMdBlock {
  const MdHeadingBlock({required this.level, required this.text});
  final int level;
  final String text;
}

class MdParagraphBlock extends VaultMdBlock {
  const MdParagraphBlock({required this.text});
  final String text;
}

class MdCodeBlock extends VaultMdBlock {
  const MdCodeBlock({
    required this.language,
    required this.code,
    this.filePath,
  });

  final String language;
  final String code;
  final String? filePath;
}

class MdCalloutBlock extends VaultMdBlock {
  const MdCalloutBlock({required this.tag, required this.text});
  final String tag;
  final String text;
}

class MdChecklistEntry {
  const MdChecklistEntry({
    required this.lineIndex,
    required this.checked,
    required this.text,
  });

  final int lineIndex;
  final bool checked;
  final String text;
}

class MdChecklistBlock extends VaultMdBlock {
  const MdChecklistBlock({required this.entries});
  final List<MdChecklistEntry> entries;
}

class MdBulletListBlock extends VaultMdBlock {
  const MdBulletListBlock({required this.items});
  final List<String> items;
}

class MdTableBlock extends VaultMdBlock {
  const MdTableBlock({required this.headers, required this.rows});
  final List<String> headers;
  final List<List<String>> rows;
}

class MdImageBlock extends VaultMdBlock {
  const MdImageBlock({required this.alt, required this.path});
  final String alt;
  final String path;
}

class MdHeadingSummary {
  const MdHeadingSummary({
    required this.blockIndex,
    required this.level,
    required this.text,
  });

  final int blockIndex;
  final int level;
  final String text;
}

/// Parses enriched VaultStudy Markdown into renderable UI blocks.
abstract final class VaultMarkdownParser {
  static final RegExp _headingRx = RegExp(r'^(#{1,3})\s+(.+)$');
  static final RegExp _checklistRx = RegExp(r'^[-*]\s+\[([ xX])\]\s+(.+)$');
  static final RegExp _bulletRx = RegExp(r'^[-*]\s+(.+)$');
  static final RegExp _imageRx = RegExp(r'^!\[([^\]]*)\]\((.+)\)$');
  static final RegExp _tableRowRx = RegExp(r'^\|(.+)\|$');
  static final RegExp _tableSepRx = RegExp(r'^\|(?:\s*:?-+:?\s*\|)+$');
  static final RegExp _fileHintRx = RegExp(
    r'^(?:--|//|#|/\*)\s*file:\s*(.+?)(?:\s*\*/)?$',
    caseSensitive: false,
  );

  static int countCodeSnippets(String md) {
    return parse(md).whereType<MdCodeBlock>().length;
  }

  static List<MdHeadingSummary> extractHeadings(String md) {
    final blocks = parse(md);
    final result = <MdHeadingSummary>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b is MdHeadingBlock) {
        result.add(
          MdHeadingSummary(blockIndex: i, level: b.level, text: b.text),
        );
      }
    }
    return result;
  }

  static bool _isTableStart(List<String> lines, int index) {
    if (index + 1 >= lines.length) return false;
    return _tableRowRx.hasMatch(lines[index].trim()) &&
        _tableSepRx.hasMatch(lines[index + 1].trim());
  }

  static List<String> _splitTableRow(String line) {
    var inner = line.trim();
    if (inner.startsWith('|')) inner = inner.substring(1);
    if (inner.endsWith('|')) inner = inner.substring(0, inner.length - 1);
    return inner.split('|').map((c) => c.trim()).toList();
  }

  /// Toggles a markdown checklist line `- [ ]` <-> `- [x]` at [lineIndex].
  static String toggleChecklistLine(
    String md,
    int lineIndex,
    bool newChecked,
  ) {
    final lines = md.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return md;
    final line = lines[lineIndex];
    final match = _checklistRx.firstMatch(line);
    if (match == null) return md;
    final mark = newChecked ? 'x' : ' ';
    lines[lineIndex] = '- [$mark] ${match.group(2)}';
    return lines.join('\n');
  }

  static List<VaultMdBlock> parse(String md) {
    final lines = md.replaceAll('\r\n', '\n').split('\n');
    final blocks = <VaultMdBlock>[];
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // Fenced code block ```lang
      if (trimmed.startsWith('```')) {
        final lang = trimmed.substring(3).trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // consume closing ```

        String? filePath;
        if (codeLines.isNotEmpty) {
          final hintMatch = _fileHintRx.firstMatch(codeLines.first.trim());
          if (hintMatch != null) {
            filePath = hintMatch.group(1)?.trim();
            codeLines.removeAt(0);
          }
        }

        blocks.add(
          MdCodeBlock(
            language: lang.isEmpty ? 'text' : lang,
            code: codeLines.join('\n').trimRight(),
            filePath: filePath,
          ),
        );
        continue;
      }

      // Callout / blockquote > [!TIP] or >
      if (trimmed.startsWith('>')) {
        final quoteLines = <String>[];
        var tag = 'NOTA';
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          var content = lines[i].trim().substring(1).trim();
          final tagMatch = RegExp(r'^\[!(TIP|EXAM|NOTE|INFO|WARN)\]$',
                  caseSensitive: false)
              .firstMatch(content);
          if (tagMatch != null) {
            tag = tagMatch.group(1)!.toUpperCase();
          } else if (content.isNotEmpty) {
            quoteLines.add(content);
          }
          i++;
        }
        if (quoteLines.isNotEmpty) {
          blocks.add(
            MdCalloutBlock(tag: tag, text: quoteLines.join(' ')),
          );
        }
        continue;
      }

      // Heading # ## ###
      final headingMatch = _headingRx.firstMatch(trimmed);
      if (headingMatch != null) {
        blocks.add(
          MdHeadingBlock(
            level: headingMatch.group(1)!.length,
            text: headingMatch.group(2)!.trim(),
          ),
        );
        i++;
        continue;
      }

      // Image ![alt](path)
      final imageMatch = _imageRx.firstMatch(trimmed);
      if (imageMatch != null) {
        blocks.add(
          MdImageBlock(
            alt: imageMatch.group(1)!.trim(),
            path: imageMatch.group(2)!.trim(),
          ),
        );
        i++;
        continue;
      }

      // Markdown Table
      if (_isTableStart(lines, i)) {
        final headers = _splitTableRow(trimmed);
        i += 2; // Skip header + separator row
        final rows = <List<String>>[];
        while (i < lines.length && _tableRowRx.hasMatch(lines[i].trim())) {
          final cells = _splitTableRow(lines[i].trim());
          final normalized = List<String>.generate(
            headers.length,
            (col) => col < cells.length ? cells[col] : '',
          );
          rows.add(normalized);
          i++;
        }
        blocks.add(MdTableBlock(headers: headers, rows: rows));
        continue;
      }

      // Checklist group
      if (_checklistRx.hasMatch(trimmed)) {
        final entries = <MdChecklistEntry>[];
        while (i < lines.length) {
          final m = _checklistRx.firstMatch(lines[i].trim());
          if (m == null) break;
          entries.add(
            MdChecklistEntry(
              lineIndex: i,
              checked: m.group(1)!.toLowerCase() == 'x',
              text: m.group(2)!.trim(),
            ),
          );
          i++;
        }
        blocks.add(MdChecklistBlock(entries: entries));
        continue;
      }

      // Bullet list
      if (_bulletRx.hasMatch(trimmed)) {
        final bullets = <String>[];
        while (i < lines.length) {
          final t = lines[i].trim();
          if (_checklistRx.hasMatch(t)) break;
          final m = _bulletRx.firstMatch(t);
          if (m == null) break;
          bullets.add(m.group(1)!.trim());
          i++;
        }
        blocks.add(MdBulletListBlock(items: bullets));
        continue;
      }

      // Paragraph (accumulate consecutive non-special lines)
      final paraLines = <String>[];
      while (i < lines.length) {
        final t = lines[i].trim();
        if (t.isEmpty ||
            t.startsWith('```') ||
            t.startsWith('>') ||
            _headingRx.hasMatch(t) ||
            _imageRx.hasMatch(t) ||
            _isTableStart(lines, i) ||
            _checklistRx.hasMatch(t) ||
            _bulletRx.hasMatch(t)) {
          break;
        }
        paraLines.add(t);
        i++;
      }
      blocks.add(MdParagraphBlock(text: paraLines.join(' ')));
    }

    return blocks;
  }
}
