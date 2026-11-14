import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'core/database/database_helper.dart';
import 'core/pdf/pdf_runtime_initializer.dart';
import 'features/workspace_desktop/application/workspace_persistence.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    const ProviderScope(
      child: VaultStudyApp(),
    ),
  );

  // Warm up persisted tabs, SQLite FFI, and PDFium right after the first frame
  // is scheduled so the desktop window appears immediately on launch.
  unawaited(WorkspacePersistence.preload());
  SchedulerBinding.instance.addPostFrameCallback((_) {
    DatabaseHelper.ensureFfiInitialized();
    unawaited(PdfRuntimeInitializer.ensureInitialized());
  });
}
