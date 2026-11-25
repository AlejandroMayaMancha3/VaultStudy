import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Current app version (kept in lockstep with `pubspec.yaml` and verified by tests).
const String kVaultStudyAppVersion = '1.0.4';
const String kVaultStudyGitHubOwner = 'AlejandroMayaMancha3';
const String kVaultStudyGitHubRepo = 'VaultStudy';

const MethodChannel _androidUpdaterChannel = MethodChannel(
  'vaultstudy/app_updater',
);

enum AppUpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  preparing,
  readyToInstall,
  needsPermission,
  installing,
  error,
}

class AppReleaseAsset {
  const AppReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
  });

  final String name;
  final String downloadUrl;
  final int sizeBytes;
}

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.tagName,
    required this.version,
    required this.title,
    required this.notes,
    required this.htmlUrl,
    this.publishedAt,
    this.windowsAsset,
    this.androidAsset,
  });

  final String tagName;
  final String version;
  final String title;
  final String notes;
  final String htmlUrl;
  final DateTime? publishedAt;
  final AppReleaseAsset? windowsAsset;
  final AppReleaseAsset? androidAsset;

  AppReleaseAsset? preferredAssetForPlatform({
    bool? isWindowsOverride,
    bool? isAndroidOverride,
  }) {
    final useWin = isWindowsOverride ?? (!kIsWeb && Platform.isWindows);
    final useAndroid = isAndroidOverride ?? (!kIsWeb && Platform.isAndroid);
    if (useWin) return windowsAsset;
    if (useAndroid) return androidAsset;
    return null;
  }
}

class AppUpdateState {
  const AppUpdateState({
    this.status = AppUpdateStatus.idle,
    this.currentVersion = kVaultStudyAppVersion,
    this.latestRelease,
    this.downloadProgress = 0.0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.downloadedFilePath,
    this.extractedDirPath,
    this.errorMessage,
    this.dismissedTag,
    this.isReadOnlyWindowsInstall = false,
  });

  final AppUpdateStatus status;
  final String currentVersion;
  final AppReleaseInfo? latestRelease;
  final double downloadProgress;
  final int downloadedBytes;
  final int totalBytes;
  final String? downloadedFilePath;
  final String? extractedDirPath;
  final String? errorMessage;
  final String? dismissedTag;
  final bool isReadOnlyWindowsInstall;

  bool get hasUpdate {
    final release = latestRelease;
    if (release == null) return false;
    return isNewerVersion(currentVersion, release.tagName);
  }

  bool get shouldShowBanner {
    final release = latestRelease;
    if (release == null || !hasUpdate) return false;
    if (dismissedTag == release.tagName) return false;
    return status != AppUpdateStatus.error;
  }

  bool get isBusy =>
      status == AppUpdateStatus.checking ||
      status == AppUpdateStatus.downloading ||
      status == AppUpdateStatus.preparing ||
      status == AppUpdateStatus.installing;

  AppUpdateState copyWith({
    AppUpdateStatus? status,
    String? currentVersion,
    AppReleaseInfo? latestRelease,
    bool clearRelease = false,
    double? downloadProgress,
    int? downloadedBytes,
    int? totalBytes,
    String? downloadedFilePath,
    bool clearDownloadedFile = false,
    String? extractedDirPath,
    bool clearExtractedDir = false,
    String? errorMessage,
    bool clearError = false,
    String? dismissedTag,
    bool? isReadOnlyWindowsInstall,
  }) {
    return AppUpdateState(
      status: status ?? this.status,
      currentVersion: currentVersion ?? this.currentVersion,
      latestRelease:
          clearRelease ? null : (latestRelease ?? this.latestRelease),
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedFilePath: clearDownloadedFile
          ? null
          : (downloadedFilePath ?? this.downloadedFilePath),
      extractedDirPath: clearExtractedDir
          ? null
          : (extractedDirPath ?? this.extractedDirPath),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      dismissedTag: dismissedTag ?? this.dismissedTag,
      isReadOnlyWindowsInstall:
          isReadOnlyWindowsInstall ?? this.isReadOnlyWindowsInstall,
    );
  }
}

/// Parses a semantic version / tag string like `v1.0.4`, `1.0.3+4`, or `1.2`
/// into `[major, minor, patch]`.
List<int> parseSemverParts(String raw) {
  var clean = raw.trim();
  if (clean.startsWith('v') || clean.startsWith('V')) {
    clean = clean.substring(1);
  }
  final plusIdx = clean.indexOf('+');
  if (plusIdx >= 0) {
    clean = clean.substring(0, plusIdx);
  }
  final dashIdx = clean.indexOf('-');
  if (dashIdx >= 0) {
    clean = clean.substring(0, dashIdx);
  }
  final segments = clean.split('.');
  int partAt(int index) {
    if (index >= segments.length) return 0;
    final digits = RegExp(r'\d+').firstMatch(segments[index])?.group(0);
    return int.tryParse(digits ?? '') ?? 0;
  }

  return [partAt(0), partAt(1), partAt(2)];
}

/// Compares two semantic version strings (`> 0` when [a] is newer than [b]).
int compareSemver(String a, String b) {
  final pa = parseSemverParts(a);
  final pb = parseSemverParts(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return 0;
}

/// Returns `true` when [candidateTag] represents a strictly newer version than [currentVersion].
bool isNewerVersion(String currentVersion, String candidateTag) {
  return compareSemver(candidateTag, currentVersion) > 0;
}

/// Parses GitHub Releases API JSON (`/releases/latest`) into [AppReleaseInfo].
AppReleaseInfo? parseGitHubReleaseJson(Map<String, dynamic> json) {
  if (json['draft'] == true) return null;
  final tagName = (json['tag_name'] as String? ?? '').trim();
  if (tagName.isEmpty) return null;

  final parts = parseSemverParts(tagName);
  final normalizedVersion = '${parts[0]}.${parts[1]}.${parts[2]}';
  final rawName = (json['name'] as String? ?? '').trim();
  final notes = (json['body'] as String? ?? '').trim();
  final htmlUrl = (json['html_url'] as String? ?? '').trim();
  final publishedRaw = json['published_at'] as String?;

  AppReleaseAsset? windowsAsset;
  AppReleaseAsset? androidAsset;

  final assets = json['assets'];
  if (assets is List) {
    for (final rawAsset in assets) {
      if (rawAsset is! Map<String, dynamic>) continue;
      final name = (rawAsset['name'] as String? ?? '').trim();
      final url = (rawAsset['browser_download_url'] as String? ?? '').trim();
      final size = (rawAsset['size'] as num?)?.toInt() ?? 0;
      if (name.isEmpty || url.isEmpty) continue;

      final lower = name.toLowerCase();
      final asset = AppReleaseAsset(
        name: name,
        downloadUrl: url,
        sizeBytes: size,
      );
      if (lower.endsWith('.zip') &&
          (lower.contains('windows') || windowsAsset == null)) {
        windowsAsset = asset;
      } else if (lower.endsWith('.apk')) {
        androidAsset = asset;
      }
    }
  }

  return AppReleaseInfo(
    tagName: tagName,
    version: normalizedVersion,
    title: rawName.isEmpty ? 'VaultStudy $tagName' : rawName,
    notes: notes,
    htmlUrl: htmlUrl.isEmpty
        ? 'https://github.com/$kVaultStudyGitHubOwner/$kVaultStudyGitHubRepo/releases/tag/$tagName'
        : htmlUrl,
    publishedAt: publishedRaw != null ? DateTime.tryParse(publishedRaw) : null,
    windowsAsset: windowsAsset,
    androidAsset: androidAsset,
  );
}

String _escapePsSingleQuoted(String value) => value.replaceAll("'", "''");

/// Generates a self-contained PowerShell script that waits for [pid] to exit,
/// copies the verified update from [sourceDir] into [targetDir], removes
/// [cleanupDir], and relaunches [exePath].
String buildWindowsUpdaterPowerShellScript({
  required int pid,
  required String sourceDir,
  required String targetDir,
  required String exePath,
  required String cleanupDir,
}) {
  final src = _escapePsSingleQuoted(sourceDir);
  final dst = _escapePsSingleQuoted(targetDir);
  final exe = _escapePsSingleQuoted(exePath);
  final tmp = _escapePsSingleQuoted(cleanupDir);

  return '''
\$ErrorActionPreference = 'Stop'
\$appPid = $pid
\$sourceDir = '$src'
\$targetDir = '$dst'
\$exePath = '$exe'
\$cleanupDir = '$tmp'

for (\$i = 0; \$i -lt 60; \$i++) {
  if (-not (Get-Process -Id \$appPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 250
}
Start-Sleep -Milliseconds 350

\$copied = \$false
for (\$attempt = 0; \$attempt -lt 12; \$attempt++) {
  try {
    Copy-Item -Path (Join-Path \$sourceDir '*') -Destination \$targetDir -Recurse -Force
    \$copied = \$true
    break
  } catch {
    Start-Sleep -Milliseconds 400
  }
}

if (\$copied) {
  Remove-Item -LiteralPath \$cleanupDir -Recurse -Force -ErrorAction SilentlyContinue
}
Start-Process -FilePath \$exePath -WorkingDirectory \$targetDir
''';
}

/// Handles checking GitHub Releases, downloading update assets with progress,
/// and triggering platform-native installation on Windows and Android.
class AppUpdateService {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  static Uri get latestReleaseApiUri => Uri.https(
        'api.github.com',
        '/repos/$kVaultStudyGitHubOwner/$kVaultStudyGitHubRepo/releases/latest',
      );

  Future<String> resolveCurrentVersion() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final raw = await _androidUpdaterChannel.invokeMethod<String>(
          'getInstalledVersion',
        );
        if (raw != null && raw.trim().isNotEmpty) {
          final parts = parseSemverParts(raw);
          return '${parts[0]}.${parts[1]}.${parts[2]}';
        }
      } catch (_) {}
    }
    return kVaultStudyAppVersion;
  }

  Future<AppReleaseInfo?> fetchLatestRelease({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(latestReleaseApiUri).timeout(timeout);
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('User-Agent', 'VaultStudy-AutoUpdater');
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException(
          'GitHub API respondió con HTTP ${response.statusCode}',
          uri: latestReleaseApiUri,
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      return parseGitHubReleaseJson(decoded);
    } finally {
      client.close(force: true);
    }
  }

  Future<Directory> _getUpdatesTempDir() async {
    final tempDir = await getTemporaryDirectory();
    final updatesDir = Directory(p.join(tempDir.path, 'vaultstudy_updates'));
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }
    return updatesDir;
  }

  Future<void> cleanupStaleUpdateFiles() async {
    try {
      final dir = await _getUpdatesTempDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<bool> canWriteWindowsInstallDir() async {
    if (kIsWeb || !Platform.isWindows) return true;
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final probe = File(p.join(exeDir, '.vaultstudy_update_probe'));
    try {
      await probe.writeAsString('ok', flush: true);
      if (await probe.exists()) {
        await probe.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> downloadAsset(
    AppReleaseAsset asset, {
    required String tagName,
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final baseDir = await _getUpdatesTempDir();
    final safeTag = tagName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final tagDir = Directory(p.join(baseDir.path, safeTag));
    if (!await tagDir.exists()) {
      await tagDir.create(recursive: true);
    }

    final targetFile = File(p.join(tagDir.path, asset.name));
    final partFile = File('${targetFile.path}.part');
    if (await partFile.exists()) {
      await partFile.delete();
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      final req = await client
          .getUrl(Uri.parse(asset.downloadUrl))
          .timeout(const Duration(seconds: 15));
      req.headers.set('User-Agent', 'VaultStudy-AutoUpdater');
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw HttpException(
          'No se pudo descargar ${asset.name} (HTTP ${resp.statusCode})',
        );
      }

      final total =
          resp.contentLength > 0 ? resp.contentLength : asset.sizeBytes;
      var received = 0;
      sink = partFile.openWrite();

      await for (final chunk in resp) {
        if (isCancelled?.call() == true) {
          throw StateError('Descarga cancelada');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final actualSize = await partFile.length();
      if (actualSize <= 0 ||
          (asset.sizeBytes > 0 && actualSize != asset.sizeBytes)) {
        throw StateError(
          'El archivo descargado está incompleto ($actualSize bytes).',
        );
      }

      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await partFile.rename(targetFile.path);
      return targetFile.path;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Extracts [zipPath] into a staging folder and locates the directory
  /// containing `vaultstudy.exe`.
  Future<String> extractWindowsZip(String zipPath) async {
    final baseDir = await _getUpdatesTempDir();
    final extractDir = Directory(p.join(baseDir.path, 'extracted'));
    if (await extractDir.exists()) {
      await extractDir.delete(recursive: true);
    }
    await extractDir.create(recursive: true);

    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    for (final entry in archive) {
      final safeName = p.normalize(entry.name);
      if (p.isAbsolute(safeName) || safeName.startsWith('..')) continue;
      final outPath = p.join(extractDir.path, safeName);
      if (entry.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(entry.content as List<int>, flush: true);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }

    final rootExe = File(p.join(extractDir.path, 'vaultstudy.exe'));
    if (await rootExe.exists()) {
      return extractDir.path;
    }
    // Check one level deep in case archive wrapped files in a single folder.
    await for (final entity in extractDir.list(followLinks: false)) {
      if (entity is Directory) {
        final nestedExe = File(p.join(entity.path, 'vaultstudy.exe'));
        if (await nestedExe.exists()) {
          return entity.path;
        }
      }
    }
    throw StateError(
      'El paquete descargado no contiene vaultstudy.exe válido.',
    );
  }

  Future<void> launchWindowsSelfUpdaterAndExit({
    required String extractedDir,
  }) async {
    final updatesDir = await _getUpdatesTempDir();
    final exePath = Platform.resolvedExecutable;
    final targetDir = p.dirname(exePath);
    final scriptFile = File(p.join(updatesDir.path, 'apply_update.ps1'));
    final scriptBody = buildWindowsUpdaterPowerShellScript(
      pid: pid,
      sourceDir: extractedDir,
      targetDir: targetDir,
      exePath: exePath,
      cleanupDir: updatesDir.path,
    );
    await scriptFile.writeAsString(scriptBody, flush: true);

    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptFile.path,
      ],
      mode: ProcessStartMode.detached,
    );

    await Future<void>.delayed(const Duration(milliseconds: 180));
    exit(0);
  }

  Future<String> installAndroidApk(String apkPath) async {
    final res = await _androidUpdaterChannel.invokeMethod<String>(
      'installApk',
      {'path': apkPath},
    );
    return res ?? 'LAUNCHED';
  }
}

final appUpdateProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdateState>(AppUpdateNotifier.new);

class AppUpdateNotifier extends Notifier<AppUpdateState> {
  bool _cancelRequested = false;

  @override
  AppUpdateState build() => const AppUpdateState();

  Future<void> checkForUpdates({bool silent = false}) async {
    if (kIsWeb) return;
    if (silent && Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    if (state.status == AppUpdateStatus.downloading ||
        state.status == AppUpdateStatus.preparing ||
        state.status == AppUpdateStatus.installing) {
      return;
    }

    final current = await AppUpdateService.instance.resolveCurrentVersion();
    if (silent) {
      // Best-effort cleanup of previous update artifacts on startup.
      unawaited(AppUpdateService.instance.cleanupStaleUpdateFiles());
    } else {
      state = state.copyWith(
        status: AppUpdateStatus.checking,
        currentVersion: current,
        clearError: true,
      );
    }

    try {
      final latest = await AppUpdateService.instance.fetchLatestRelease();
      if (latest == null) {
        if (!silent) {
          state = state.copyWith(
            status: AppUpdateStatus.upToDate,
            currentVersion: current,
            clearError: true,
          );
        }
        return;
      }

      final hasNew = isNewerVersion(current, latest.tagName);
      final writableWin = Platform.isWindows
          ? await AppUpdateService.instance.canWriteWindowsInstallDir()
          : true;

      if (hasNew) {
        state = state.copyWith(
          status: AppUpdateStatus.available,
          currentVersion: current,
          latestRelease: latest,
          isReadOnlyWindowsInstall: !writableWin,
          clearError: true,
        );
      } else {
        state = state.copyWith(
          status: silent ? AppUpdateStatus.idle : AppUpdateStatus.upToDate,
          currentVersion: current,
          latestRelease: latest,
          clearError: true,
        );
      }
    } catch (e) {
      if (silent) return;
      state = state.copyWith(
        status: AppUpdateStatus.error,
        currentVersion: current,
        errorMessage: 'No se pudo comprobar actualizaciones: $e',
      );
    }
  }

  Future<void> downloadAndInstallUpdate() async {
    final release = state.latestRelease;
    if (release == null) return;
    final asset = release.preferredAssetForPlatform();
    if (asset == null) {
      state = state.copyWith(
        status: AppUpdateStatus.error,
        errorMessage:
            'No hay instalador compatible en la release ${release.tagName}.',
      );
      return;
    }

    if (Platform.isWindows) {
      final canWrite =
          await AppUpdateService.instance.canWriteWindowsInstallDir();
      if (!canWrite) {
        state = state.copyWith(
          status: AppUpdateStatus.error,
          isReadOnlyWindowsInstall: true,
          errorMessage:
              'La carpeta actual de VaultStudy es de solo lectura. Descarga el ZIP desde GitHub o mueve VaultStudy a una carpeta de usuario.',
        );
        return;
      }
    }

    _cancelRequested = false;
    state = state.copyWith(
      status: AppUpdateStatus.downloading,
      downloadProgress: 0.0,
      downloadedBytes: 0,
      totalBytes: asset.sizeBytes,
      clearError: true,
    );

    try {
      final filePath = await AppUpdateService.instance.downloadAsset(
        asset,
        tagName: release.tagName,
        isCancelled: () => _cancelRequested,
        onProgress: (received, total) {
          final pct = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
          state = state.copyWith(
            status: AppUpdateStatus.downloading,
            downloadedBytes: received,
            totalBytes: total,
            downloadProgress: pct,
          );
        },
      );

      if (Platform.isWindows) {
        state = state.copyWith(
          status: AppUpdateStatus.preparing,
          downloadedFilePath: filePath,
          downloadProgress: 1.0,
        );
        final extractedDir =
            await AppUpdateService.instance.extractWindowsZip(filePath);
        state = state.copyWith(
          status: AppUpdateStatus.installing,
          extractedDirPath: extractedDir,
        );
        await AppUpdateService.instance.launchWindowsSelfUpdaterAndExit(
          extractedDir: extractedDir,
        );
      } else if (Platform.isAndroid) {
        state = state.copyWith(
          status: AppUpdateStatus.readyToInstall,
          downloadedFilePath: filePath,
          downloadProgress: 1.0,
        );
        await retryPendingInstall();
      }
    } catch (e) {
      if (_cancelRequested) {
        state = state.copyWith(
          status: AppUpdateStatus.available,
          downloadProgress: 0.0,
          downloadedBytes: 0,
          clearError: true,
        );
        return;
      }
      state = state.copyWith(
        status: AppUpdateStatus.error,
        errorMessage: 'Error durante la actualización: $e',
      );
    }
  }

  Future<void> retryPendingInstall() async {
    final filePath = state.downloadedFilePath;
    if (filePath == null || !File(filePath).existsSync()) {
      await downloadAndInstallUpdate();
      return;
    }

    if (Platform.isWindows) {
      final extractedDir = state.extractedDirPath ??
          await AppUpdateService.instance.extractWindowsZip(filePath);
      state = state.copyWith(
        status: AppUpdateStatus.installing,
        extractedDirPath: extractedDir,
      );
      await AppUpdateService.instance.launchWindowsSelfUpdaterAndExit(
        extractedDir: extractedDir,
      );
      return;
    }

    if (Platform.isAndroid) {
      try {
        final outcome =
            await AppUpdateService.instance.installAndroidApk(filePath);
        if (outcome == 'NEEDS_PERMISSION') {
          state = state.copyWith(
            status: AppUpdateStatus.needsPermission,
            clearError: true,
          );
        } else {
          state = state.copyWith(
            status: AppUpdateStatus.readyToInstall,
            clearError: true,
          );
        }
      } catch (e) {
        state = state.copyWith(
          status: AppUpdateStatus.error,
          errorMessage: 'No se pudo abrir el instalador APK: $e',
        );
      }
    }
  }

  void cancelDownload() {
    _cancelRequested = true;
  }

  void dismissBanner() {
    final tag = state.latestRelease?.tagName;
    if (tag == null) return;
    state = state.copyWith(dismissedTag: tag);
  }
}
