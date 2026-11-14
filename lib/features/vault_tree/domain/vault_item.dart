import 'dart:convert';

enum VaultItemType {
  folder('folder'),
  pdf('pdf'),
  book('book'),
  note('note');

  const VaultItemType(this.dbValue);
  final String dbValue;

  bool get isDocument => this == pdf || this == book;

  static VaultItemType fromDb(String value) {
    return VaultItemType.values.firstWhere(
      (e) => e.dbValue == value,
      orElse: () => VaultItemType.note,
    );
  }
}

/// Recursive hierarchical item stored in the `items` SQLite table.
class VaultItem {
  const VaultItem({
    required this.id,
    required this.parentId,
    required this.title,
    required this.type,
    this.filePath,
    this.fileSize = 0,
    this.extractedText = '',
    this.contentMd = '',
    this.isPinned = false,
    this.sortOrder = 0,
    required this.updatedAt,
  });

  final String id;
  final String? parentId;
  final String title;
  final VaultItemType type;
  final String? filePath;
  final int fileSize;
  final String extractedText;
  final String contentMd;
  final bool isPinned;
  final int sortOrder;
  final DateTime updatedAt;

  VaultItem copyWith({
    String? id,
    Object? parentId = _sentinel,
    String? title,
    VaultItemType? type,
    Object? filePath = _sentinel,
    int? fileSize,
    String? extractedText,
    String? contentMd,
    bool? isPinned,
    int? sortOrder,
    DateTime? updatedAt,
  }) {
    return VaultItem(
      id: id ?? this.id,
      parentId: identical(parentId, _sentinel)
          ? this.parentId
          : parentId as String?,
      title: title ?? this.title,
      type: type ?? this.type,
      filePath: identical(filePath, _sentinel)
          ? this.filePath
          : filePath as String?,
      fileSize: fileSize ?? this.fileSize,
      extractedText: extractedText ?? this.extractedText,
      contentMd: contentMd ?? this.contentMd,
      isPinned: isPinned ?? this.isPinned,
      sortOrder: sortOrder ?? this.sortOrder,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'parent_id': parentId,
      'title': title,
      'type': type.dbValue,
      'file_path': filePath,
      'file_size': fileSize,
      'extracted_text': extractedText,
      'content_md': contentMd,
      'is_pinned': isPinned ? 1 : 0,
      'sort_order': sortOrder,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory VaultItem.fromMap(Map<String, Object?> map) {
    return VaultItem(
      id: map['id'] as String,
      parentId: map['parent_id'] as String?,
      title: map['title'] as String,
      type: VaultItemType.fromDb(map['type'] as String),
      filePath: map['file_path'] as String?,
      fileSize: (map['file_size'] as int?) ?? 0,
      extractedText: (map['extracted_text'] as String?) ?? '',
      contentMd: (map['content_md'] as String?) ?? '',
      isPinned: ((map['is_pinned'] as int?) ?? 0) == 1,
      sortOrder: (map['sort_order'] as int?) ?? 0,
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  String get formattedSize {
    if (fileSize <= 0) return '0 B';
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(0)} KB';
    }
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

const Object _sentinel = Object();

/// Normalized rectangle (0..1 relative to unrotated page dimensions).
class NormalizedRect {
  const NormalizedRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  Map<String, double> toJson() => {
        'l': left,
        't': top,
        'r': right,
        'b': bottom,
      };

  factory NormalizedRect.fromJson(Map<String, dynamic> json) {
    return NormalizedRect(
      left: (json['l'] as num).toDouble(),
      top: (json['t'] as num).toDouble(),
      right: (json['r'] as num).toDouble(),
      bottom: (json['b'] as num).toDouble(),
    );
  }
}

/// Persistent non-destructive highlight annotation stored in `pdf_annotations`.
class PdfAnnotation {
  const PdfAnnotation({
    required this.id,
    required this.itemId,
    required this.pageNumber,
    required this.rects,
    required this.selectedText,
    required this.colorHex,
    this.note = '',
    required this.createdAt,
  });

  final String id;
  final String itemId;
  final int pageNumber;
  final List<NormalizedRect> rects;
  final String selectedText;
  final String colorHex;
  final String note;
  final DateTime createdAt;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'item_id': itemId,
      'page_number': pageNumber,
      'rects_json': jsonEncode(rects.map((r) => r.toJson()).toList()),
      'selected_text': selectedText,
      'color_hex': colorHex,
      'note': note,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory PdfAnnotation.fromMap(Map<String, Object?> map) {
    final decoded = jsonDecode(map['rects_json'] as String) as List<dynamic>;
    return PdfAnnotation(
      id: map['id'] as String,
      itemId: map['item_id'] as String,
      pageNumber: map['page_number'] as int,
      rects: decoded
          .map((e) => NormalizedRect.fromJson(e as Map<String, dynamic>))
          .toList(),
      selectedText: (map['selected_text'] as String?) ?? '',
      colorHex: (map['color_hex'] as String?) ?? '#4EDEA3',
      note: (map['note'] as String?) ?? '',
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Indexed page text for exact page-level search & jumps.
class PdfPageEntry {
  const PdfPageEntry({
    required this.itemId,
    required this.pageNumber,
    required this.content,
  });

  final String itemId;
  final int pageNumber;
  final String content;
}
