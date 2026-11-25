import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/constants/app_breakpoints.dart';
import 'core/theme/app_theme.dart';
import 'features/app_update/application/app_update_service.dart';
import 'features/cloud_sync/application/cloud_sync_service.dart';
import 'features/mobile_explorer/presentation/mobile_shell.dart';
import 'features/workspace_desktop/presentation/desktop_shell.dart';

/// Root MaterialApp switching adaptively between Mobile (< 900px) and Desktop (>= 900px).
class VaultStudyApp extends ConsumerStatefulWidget {
  const VaultStudyApp({super.key});

  @override
  ConsumerState<VaultStudyApp> createState() => _VaultStudyAppState();
}

class _VaultStudyAppState extends ConsumerState<VaultStudyApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(cloudSyncProvider.notifier).tryAutoSyncOnStartup());
        unawaited(ref.read(appUpdateProvider.notifier).checkForUpdates(silent: true));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VaultStudy',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= AppBreakpoints.desktop) {
            return const DesktopShell();
          }
          return const MobileShell();
        },
      ),
    );
  }
}
