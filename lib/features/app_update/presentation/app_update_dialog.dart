import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../application/app_update_service.dart';

/// Opens the interactive GitHub Releases update dialog showing release notes,
/// download progress, and 1-click self-update / APK installation.
Future<void> showAppUpdateDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => const _AppUpdateDialog(),
  );
}

class _AppUpdateDialog extends ConsumerWidget {
  const _AppUpdateDialog();

  String _formatMb(int bytes) {
    if (bytes <= 0) return '';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _openInBrowser(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateProvider);
    final notifier = ref.read(appUpdateProvider.notifier);
    final release = state.latestRelease;
    final asset = release?.preferredAssetForPlatform();

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            state.hasUpdate
                ? Icons.system_update_alt_rounded
                : Icons.verified_outlined,
            color: state.hasUpdate ? AppColors.primary : AppColors.secondary,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.hasUpdate
                  ? 'Nueva actualización disponible'
                  : 'Actualizaciones de VaultStudy',
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLowest,
                  borderRadius: BorderRadius.circular(AppBreakpoints.radiusMd),
                  border: Border.all(
                    color: state.hasUpdate
                        ? AppColors.primary.withValues(alpha: 0.45)
                        : AppColors.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'VERSIÓN INSTALADA',
                            style: AppTypography.badgeMono.copyWith(
                              color: AppColors.outline,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'v${state.currentVersion}',
                            style: AppTypography.monoMd.copyWith(
                              color: AppColors.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (release != null) ...[
                      const Icon(
                        Icons.arrow_forward_rounded,
                        size: 16,
                        color: AppColors.outline,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.hasUpdate
                                  ? 'ÚLTIMA EN GITHUB'
                                  : 'AL DÍA',
                              style: AppTypography.badgeMono.copyWith(
                                color: state.hasUpdate
                                    ? AppColors.primary
                                    : AppColors.secondary,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              release.tagName,
                              style: AppTypography.monoMd.copyWith(
                                color: state.hasUpdate
                                    ? AppColors.primary
                                    : AppColors.secondary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (state.status == AppUpdateStatus.checking)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('Consultando GitHub Releases...'),
                      ),
                    ],
                  ),
                )
              else if (state.status == AppUpdateStatus.upToDate)
                Text(
                  'Ya tienes la última versión publicada (${release?.tagName ?? 'v${state.currentVersion}'}).',
                  style: AppTypography.bodyMd.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              if (release != null && state.hasUpdate) ...[
                if (asset != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Paquete: ${asset.name}${asset.sizeBytes > 0 ? ' (${_formatMb(asset.sizeBytes)})' : ''}',
                      style: AppTypography.monoSm.copyWith(
                        color: AppColors.secondary,
                      ),
                    ),
                  ),
                if (release.notes.isNotEmpty) ...[
                  Text(
                    'NOVEDADES DE ${release.tagName.toUpperCase()}',
                    style: AppTypography.badgeMono.copyWith(
                      color: AppColors.outline,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 180),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLow,
                      borderRadius:
                          BorderRadius.circular(AppBreakpoints.radiusSm),
                      border: Border.all(
                        color: AppColors.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        release.notes,
                        style: AppTypography.bodySm.copyWith(
                          color: AppColors.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Text(
                  !kIsWeb && Platform.isWindows
                      ? 'En Windows la app se descargará, se actualizará sola manteniendo tus apuntes intactos y se reiniciará automáticamente.'
                      : 'En Android se descargará el APK y se abrirá el instalador del sistema para confirmar con 1 toque sin perder tus datos.',
                  style: AppTypography.bodySm.copyWith(
                    color: AppColors.outline,
                  ),
                ),
              ],
              if (state.status == AppUpdateStatus.downloading ||
                  state.status == AppUpdateStatus.preparing ||
                  state.status == AppUpdateStatus.installing) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: state.status == AppUpdateStatus.downloading &&
                          state.totalBytes > 0
                      ? state.downloadProgress
                      : null,
                  color: AppColors.primary,
                  backgroundColor: AppColors.surfaceHighest,
                ),
                const SizedBox(height: 8),
                Text(
                  switch (state.status) {
                    AppUpdateStatus.downloading => state.totalBytes > 0
                        ? 'Descargando ${(state.downloadProgress * 100).round()}% (${_formatMb(state.downloadedBytes)} / ${_formatMb(state.totalBytes)})...'
                        : 'Descargando ${_formatMb(state.downloadedBytes)}...',
                    AppUpdateStatus.preparing =>
                      'Verificando y preparando archivos de actualización...',
                    AppUpdateStatus.installing =>
                      'Aplicando actualización y reiniciando VaultStudy...',
                    _ => '',
                  },
                  style: AppTypography.monoSm.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ],
              if (state.status == AppUpdateStatus.needsPermission) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.bookAmber.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                    border: Border.all(
                      color: AppColors.bookAmber.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    'Activa "Permitir instalar aplicaciones de esta fuente" en los ajustes de Android que acaban de abrirse y vuelve aquí para continuar.',
                    style: AppTypography.bodySm.copyWith(
                      color: AppColors.bookAmber,
                    ),
                  ),
                ),
              ],
              if (state.errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppBreakpoints.radiusSm),
                    border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    state.errorMessage!,
                    style: AppTypography.bodySm.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (state.status == AppUpdateStatus.downloading)
          TextButton(
            onPressed: notifier.cancelDownload,
            child: const Text('Cancelar descarga'),
          )
        else ...[
          if (release != null)
            TextButton(
              onPressed: () => _openInBrowser(release.htmlUrl),
              child: const Text('Ver en GitHub'),
            ),
          if (!state.hasUpdate || state.status == AppUpdateStatus.error)
            OutlinedButton.icon(
              onPressed: state.isBusy
                  ? null
                  : () => unawaited(notifier.checkForUpdates(silent: false)),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Buscar ahora'),
            ),
          if (state.status == AppUpdateStatus.needsPermission ||
              state.status == AppUpdateStatus.readyToInstall)
            ElevatedButton.icon(
              onPressed: () => unawaited(notifier.retryPendingInstall()),
              icon: const Icon(Icons.install_mobile_rounded, size: 17),
              label: const Text('Instalar ahora'),
            )
          else if (state.hasUpdate &&
              asset != null &&
              !state.isReadOnlyWindowsInstall &&
              !state.isBusy)
            ElevatedButton.icon(
              onPressed: () => unawaited(notifier.downloadAndInstallUpdate()),
              icon: const Icon(Icons.download_rounded, size: 17),
              label: Text(
                !kIsWeb && Platform.isWindows
                    ? 'Actualizar y reiniciar'
                    : 'Descargar e instalar',
              ),
            ),
          TextButton(
            onPressed: () {
              if (state.hasUpdate) notifier.dismissBanner();
              Navigator.pop(context);
            },
            child: Text(state.hasUpdate ? 'Más tarde' : 'Cerrar'),
          ),
        ],
      ],
    );
  }
}
