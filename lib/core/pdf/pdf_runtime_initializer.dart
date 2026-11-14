import 'dart:async';

import 'package:pdfrx/pdfrx.dart';

/// Lazily initializes PDFium / `pdfrx` once, without blocking `runApp()`.
class PdfRuntimeInitializer {
  PdfRuntimeInitializer._();

  static Future<void>? _initFuture;

  /// Ensures `pdfrxFlutterInitialize` has completed before any PDF open/extract.
  static Future<void> ensureInitialized() {
    return _initFuture ??= pdfrxFlutterInitialize().catchError((Object e) {
      _initFuture = null;
      throw e;
    });
  }
}
