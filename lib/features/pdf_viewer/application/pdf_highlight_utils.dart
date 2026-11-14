import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../vault_tree/domain/vault_item.dart';

class HighlightColorOption {
  const HighlightColorOption({
    required this.hex,
    required this.label,
    required this.color,
  });

  final String hex;
  final String label;
  final Color color;
}

class PdfHighlightPalette {
  PdfHighlightPalette._();

  static const List<HighlightColorOption> options = [
    HighlightColorOption(
      hex: '#4EDEA3',
      label: 'Esmeralda',
      color: Color(0xFF4EDEA3),
    ),
    HighlightColorOption(
      hex: '#FFD166',
      label: 'Ámbar',
      color: Color(0xFFFFD166),
    ),
    HighlightColorOption(
      hex: '#7BD0FF',
      label: 'Cian',
      color: Color(0xFF7BD0FF),
    ),
    HighlightColorOption(
      hex: '#FF6B8B',
      label: 'Coral',
      color: Color(0xFFFF6B8B),
    ),
  ];

  static Color colorFromHex(String hex) {
    final cleaned = hex.trim().replaceFirst('#', '');
    if (cleaned.length == 6) {
      final value = int.tryParse('FF$cleaned', radix: 16);
      if (value != null) return Color(value);
    } else if (cleaned.length == 8) {
      final value = int.tryParse(cleaned, radix: 16);
      if (value != null) return Color(value);
    }
    return const Color(0xFF4EDEA3);
  }
}

/// Merges fragmented word/character rectangles that belong to the same line
/// into continuous highlighter strips.
List<NormalizedRect> mergeLineRects(List<NormalizedRect> input) {
  if (input.isEmpty) return const [];

  final sorted = input
      .map(
        (r) => NormalizedRect(
          left: math.min(r.left, r.right).clamp(0.0, 1.0),
          top: math.min(r.top, r.bottom).clamp(0.0, 1.0),
          right: math.max(r.left, r.right).clamp(0.0, 1.0),
          bottom: math.max(r.top, r.bottom).clamp(0.0, 1.0),
        ),
      )
      .where((r) => (r.right - r.left) > 0.0005 && (r.bottom - r.top) > 0.0005)
      .toList()
    ..sort((a, b) {
      final topDiff = (a.top - b.top).abs();
      if (topDiff > 0.008) return a.top.compareTo(b.top);
      return a.left.compareTo(b.left);
    });

  if (sorted.isEmpty) return const [];

  final merged = <NormalizedRect>[sorted.first];
  for (var i = 1; i < sorted.length; i++) {
    final cur = sorted[i];
    var absorbed = false;

    for (var j = merged.length - 1; j >= 0 && j >= merged.length - 4; j--) {
      final prev = merged[j];
      final prevH = (prev.bottom - prev.top).abs();
      final curH = (cur.bottom - cur.top).abs();
      final minH = math.min(prevH, curH);
      final overlapTop = math.max(prev.top, cur.top);
      final overlapBottom = math.min(prev.bottom, cur.bottom);
      final vOverlap = overlapBottom - overlapTop;
      final sameLine = vOverlap >= minH * 0.4 ||
          ((prev.top + prev.bottom) / 2 - (cur.top + cur.bottom) / 2).abs() <=
              math.max(prevH, curH) * 0.45;

      final horizontalGap = cur.left - prev.right;
      final horizontalOverlapOrClose =
          horizontalGap <= 0.038 && prev.left - cur.right <= 0.038;

      if (sameLine && horizontalOverlapOrClose) {
        merged[j] = NormalizedRect(
          left: math.min(prev.left, cur.left),
          top: math.min(prev.top, cur.top),
          right: math.max(prev.right, cur.right),
          bottom: math.max(prev.bottom, cur.bottom),
        );
        absorbed = true;
        break;
      }
    }

    if (!absorbed) {
      merged.add(cur);
    }
  }

  return merged;
}

/// Converts normalized pointer drag points (`0..1`) into clean highlighter strips.
List<NormalizedRect> strokeToNormalizedRects(
  List<Offset> points, {
  double bandHalfHeight = 0.011,
  double brushHalfWidth = 0.008,
}) {
  if (points.isEmpty) return const [];

  final rawRects = <NormalizedRect>[];
  void addBrushAt(Offset pt) {
    final cx = pt.dx.clamp(0.0, 1.0);
    final cy = pt.dy.clamp(0.0, 1.0);
    rawRects.add(
      NormalizedRect(
        left: (cx - brushHalfWidth).clamp(0.0, 1.0),
        top: (cy - bandHalfHeight).clamp(0.0, 1.0),
        right: (cx + brushHalfWidth).clamp(0.0, 1.0),
        bottom: (cy + bandHalfHeight).clamp(0.0, 1.0),
      ),
    );
  }

  addBrushAt(points.first);
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1];
    final b = points[i];
    final dist = (b - a).distance;
    final steps = math.max(1, (dist / 0.012).ceil());
    for (var s = 1; s <= steps; s++) {
      final t = s / steps;
      addBrushAt(Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t));
    }
  }

  return mergeLineRects(rawRects);
}

enum AnnotationActionKind { add, delete }

class AnnotationAction {
  const AnnotationAction({
    required this.kind,
    required this.annotations,
  });

  final AnnotationActionKind kind;
  final List<PdfAnnotation> annotations;
}

/// Manages undo/redo command history for PDF highlight annotations.
class AnnotationHistoryStack {
  static const int _maxDepth = 50;

  final List<AnnotationAction> _undo = [];
  final List<AnnotationAction> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoCount => _undo.length;

  void recordAdd(List<PdfAnnotation> created) {
    if (created.isEmpty) return;
    _pushUndo(
      AnnotationAction(kind: AnnotationActionKind.add, annotations: created),
    );
  }

  void recordDelete(List<PdfAnnotation> removed) {
    if (removed.isEmpty) return;
    _pushUndo(
      AnnotationAction(kind: AnnotationActionKind.delete, annotations: removed),
    );
  }

  void _pushUndo(AnnotationAction action) {
    _undo.add(action);
    if (_undo.length > _maxDepth) {
      _undo.removeAt(0);
    }
    _redo.clear();
  }

  AnnotationAction? popUndo() {
    if (_undo.isEmpty) return null;
    final action = _undo.removeLast();
    _redo.add(action);
    return action;
  }

  AnnotationAction? popRedo() {
    if (_redo.isEmpty) return null;
    final action = _redo.removeLast();
    _undo.add(action);
    return action;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
