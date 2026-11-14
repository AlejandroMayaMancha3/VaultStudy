import 'dart:convert';
import 'dart:typed_data';

/// Lightweight pure-Dart generator for valid PDF 1.4 documents used by the
/// initial seeder so sample PDFs open natively with selectable text & pages.
abstract final class MinimalPdfGenerator {
  static Uint8List buildPdf({
    required String title,
    required List<List<String>> pagesLines,
  }) {
    final buffer = StringBuffer();
    final offsets = <int>[0]; // object 0 is always free

    void writeObj(int id, String body) {
      offsets.add(buffer.length);
      buffer.write('$id 0 obj\n$body\nendobj\n');
    }

    // Object 1: Catalog, Object 2: Pages, Object 3: Font Helvetica
    final pageCount = pagesLines.length;
    final firstPageObjId = 4;
    final kidsRefs = List.generate(
      pageCount,
      (i) => '${firstPageObjId + i * 2} 0 R',
    ).join(' ');

    buffer.write('%PDF-1.4\n');
    writeObj(1, '<< /Type /Catalog /Pages 2 0 R >>');
    writeObj(2, '<< /Type /Pages /Kids [$kidsRefs] /Count $pageCount >>');
    writeObj(
      3,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    );

    for (var i = 0; i < pageCount; i++) {
      final pageObjId = firstPageObjId + i * 2;
      final contentObjId = pageObjId + 1;

      final stream = _buildPageContentStream(
        title: title,
        pageNumber: i + 1,
        totalPages: pageCount,
        lines: pagesLines[i],
      );

      writeObj(
        pageObjId,
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents $contentObjId 0 R >>',
      );

      writeObj(
        contentObjId,
        '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
      );
    }

    final xrefOffset = buffer.length;
    final totalObjects = offsets.length;
    buffer.write('xref\n');
    buffer.write('0 $totalObjects\n');
    buffer.write('0000000000 65535 f \n');
    for (var i = 1; i < totalObjects; i++) {
      final off = offsets[i].toString().padLeft(10, '0');
      buffer.write('$off 00000 n \n');
    }

    buffer.write('trailer\n');
    buffer.write('<< /Size $totalObjects /Root 1 0 R >>\n');
    buffer.write('startxref\n');
    buffer.write('$xrefOffset\n');
    buffer.write('%%EOF\n');

    return Uint8List.fromList(latin1.encode(_toLatin1Safe(buffer.toString())));
  }

  static String _buildPageContentStream({
    required String title,
    required int pageNumber,
    required int totalPages,
    required List<String> lines,
  }) {
    final sb = StringBuffer();
    // Subtle dark-ink-on-paper academic layout (readable inside PDFium)
    sb.writeln('BT');
    sb.writeln('/F1 10 Tf');
    sb.writeln('54 790 Td');
    sb.writeln('(${_escapePdfText(_toLatin1Safe('$title   |   Hoja $pageNumber / $totalPages'))}) Tj');
    sb.writeln('0 -14 Td');
    sb.writeln('(------------------------------------------------------------------------) Tj');
    sb.writeln('0 -24 Td');
    sb.writeln('/F1 12 Tf');
    for (final line in lines) {
      sb.writeln('(${_escapePdfText(_toLatin1Safe(line))}) Tj');
      sb.writeln('0 -18 Td');
    }
    sb.writeln('ET');
    return sb.toString();
  }

  static String _escapePdfText(String input) {
    return input
        .replaceAll('\\', '\\\\')
        .replaceAll('(', '\\(')
        .replaceAll(')', '\\)');
  }

  static String _toLatin1Safe(String input) {
    final out = StringBuffer();
    for (final code in input.runes) {
      if (code <= 255) {
        out.writeCharCode(code);
      } else {
        out.write(' ');
      }
    }
    return out.toString();
  }
}
