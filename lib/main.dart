import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';
import 'core/database/database_helper.dart';
import 'features/workspace_desktop/application/workspace_persistence.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureFfiInitialized();
  await pdfrxFlutterInitialize();
  await WorkspacePersistence.preload();

  runApp(
    const ProviderScope(
      child: VaultStudyApp(),
    ),
  );
}
