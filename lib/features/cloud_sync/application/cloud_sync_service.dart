import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/storage/vault_storage_service.dart';
import '../../vault_tree/application/vault_providers.dart';
import '../../vault_tree/domain/vault_item.dart';
import '../../workspace_desktop/application/workspace_state.dart';
import '../data/secure_session_store.dart';
import '../data/supabase_cloud_client.dart';

class CloudSyncState {
  const CloudSyncState({
    this.session,
    this.isSyncing = false,
    this.isWaitingOAuth = false,
    this.isOffline = false,
    this.lastSyncedAt,
    this.pendingChangesCount = 0,
    this.syncProgressLabel,
    this.errorMessage,
    this.infoMessage,
    this.hasInitialized = false,
  });

  final CloudSession? session;
  final bool isSyncing;
  final bool isWaitingOAuth;
  final bool isOffline;
  final DateTime? lastSyncedAt;
  final int pendingChangesCount;
  final String? syncProgressLabel;
  final String? errorMessage;
  final String? infoMessage;
  final bool hasInitialized;

  bool get isSignedIn => session != null;
  String? get userEmail => session?.email;

  CloudSyncState copyWith({
    Object? session = _syncSentinel,
    bool? isSyncing,
    bool? isWaitingOAuth,
    bool? isOffline,
    Object? lastSyncedAt = _syncSentinel,
    int? pendingChangesCount,
    Object? syncProgressLabel = _syncSentinel,
    Object? errorMessage = _syncSentinel,
    Object? infoMessage = _syncSentinel,
    bool? hasInitialized,
  }) {
    return CloudSyncState(
      session: identical(session, _syncSentinel)
          ? this.session
          : session as CloudSession?,
      isSyncing: isSyncing ?? this.isSyncing,
      isWaitingOAuth: isWaitingOAuth ?? this.isWaitingOAuth,
      isOffline: isOffline ?? this.isOffline,
      lastSyncedAt: identical(lastSyncedAt, _syncSentinel)
          ? this.lastSyncedAt
          : lastSyncedAt as DateTime?,
      pendingChangesCount: pendingChangesCount ?? this.pendingChangesCount,
      syncProgressLabel: identical(syncProgressLabel, _syncSentinel)
          ? this.syncProgressLabel
          : syncProgressLabel as String?,
      errorMessage: identical(errorMessage, _syncSentinel)
          ? this.errorMessage
          : errorMessage as String?,
      infoMessage: identical(infoMessage, _syncSentinel)
          ? this.infoMessage
          : infoMessage as String?,
      hasInitialized: hasInitialized ?? this.hasInitialized,
    );
  }
}

const Object _syncSentinel = Object();

class CloudSyncNotifier extends Notifier<CloudSyncState> {
  static const String mobileOAuthRedirectUrl = 'vaultstudy://login-callback';

  final SupabaseCloudClient _client = SupabaseCloudClient();
  final SecureSessionStore _sessionStore = SecureSessionStore();
  Timer? _autoSyncDebounce;
  Future<void>? _initFuture;
  Future<bool>? _activeSyncFuture;
  HttpServer? _oauthServer;
  StreamSubscription<Uri>? _appLinksSub;
  Completer<String>? _oauthCompleter;

  @override
  CloudSyncState build() {
    ref.onDispose(() {
      _autoSyncDebounce?.cancel();
      unawaited(_closeOAuthServer());
    });
    _initFuture = _initialize();
    return const CloudSyncState();
  }

  Future<void> _initialize() async {
    try {
      final session = await _sessionStore.readSession();
      final lastSync = await _sessionStore.readLastSync();

      final pending =
          await ref.read(vaultRepositoryProvider).getPendingSyncCount();
      if (!ref.mounted) return;
      state = state.copyWith(
        session: session,
        lastSyncedAt: lastSync,
        pendingChangesCount: pending,
        hasInitialized: true,
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = state.copyWith(hasInitialized: true);
    }
  }

  Future<void> _ensureInitialized() async {
    final f = _initFuture;
    if (f != null) await f;
  }

  Future<void> refreshPendingCount() async {
    try {
      final pending =
          await ref.read(vaultRepositoryProvider).getPendingSyncCount();
      if (!ref.mounted) return;
      state = state.copyWith(pendingChangesCount: pending);
    } catch (_) {}
  }

  /// Non-blocking startup sync when already signed in; safe if offline.
  Future<void> tryAutoSyncOnStartup() async {
    await _ensureInitialized();
    if (!ref.mounted || !state.isSignedIn) return;
    await syncNow(silentIfOffline: true);
  }

  /// Debounced background sync after local offline/online edits.
  void scheduleAutoSync() {
    unawaited(refreshPendingCount());
    if (!state.isSignedIn) return;
    _autoSyncDebounce?.cancel();
    _autoSyncDebounce = Timer(const Duration(seconds: 2), () {
      if (!ref.mounted || !state.isSignedIn) return;
      unawaited(syncNow(silentIfOffline: true));
    });
  }

  Future<bool> signIn({
    required String email,
    required String password,
  }) async {
    await _ensureInitialized();
    state = state.copyWith(
      isSyncing: true,
      isOffline: false,
      syncProgressLabel: 'Iniciando sesión...',
      errorMessage: null,
      infoMessage: null,
    );

    try {
      final result = await _client.signInWithPassword(
        email: email,
        password: password,
      );
      if (result.session == null) {
        state = state.copyWith(
          isSyncing: false,
          syncProgressLabel: null,
          errorMessage: 'No se pudo obtener una sesión válida.',
        );
        return false;
      }

      await _saveSession(result.session!);
      state = state.copyWith(
        session: result.session,
        isSyncing: false,
        syncProgressLabel: null,
      );
      await syncNow(silentIfOffline: false);
      return state.errorMessage == null;
    } on CloudException catch (e) {
      state = state.copyWith(
        isSyncing: false,
        isOffline: e.isOffline,
        syncProgressLabel: null,
        errorMessage: e.message,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isSyncing: false,
        syncProgressLabel: null,
        errorMessage: 'Error inesperado al iniciar sesión. Inténtalo de nuevo.',
      );
      return false;
    }
  }

  /// Signs in with GitHub via PKCE using deep link (`vaultstudy://login-callback`) on
  /// mobile or localhost loopback redirect (`127.0.0.1`) on desktop.
  Future<bool> signInWithGitHub() async {
    await _ensureInitialized();
    await cancelGitHubSignIn(silent: true);

    HttpServer? server;
    try {
      final isMobile = Platform.isAndroid || Platform.isIOS;
      final completer = Completer<String>();
      _oauthCompleter = completer;
      late final String redirectTo;

      if (isMobile) {
        redirectTo = mobileOAuthRedirectUrl;
        final appLinks = AppLinks();
        _appLinksSub = appLinks.uriLinkStream.listen((uri) {
          if (uri.scheme != 'vaultstudy' || uri.host != 'login-callback') {
            return;
          }
          final params = uri.queryParameters;
          final error = params['error'];
          if (error != null && error.isNotEmpty) {
            final rawDesc = (params['error_description'] ?? error)
                .replaceAll(RegExp(r'[\r\n]+'), ' ')
                .trim();
            if (!completer.isCompleted) {
              completer.completeError(
                CloudException(
                  rawDesc.isEmpty ? 'Acceso denegado por GitHub.' : rawDesc,
                ),
              );
            }
            return;
          }
          final code = params['code'];
          if (code != null && code.isNotEmpty && !completer.isCompleted) {
            completer.complete(code);
          } else if (!completer.isCompleted) {
            completer.completeError(
              const CloudException(
                'No se recibió el código de autorización de Supabase.',
              ),
            );
          }
        });
      } else {
        server = await _bindOAuthLoopbackServer();
        _oauthServer = server;
        redirectTo = 'http://127.0.0.1:${server.port}/callback';
        var handled = false;

        server.listen((HttpRequest req) async {
          try {
            final isLoopback = req.connectionInfo?.remoteAddress.isLoopback ?? true;
            if (!isLoopback) {
              req.response.statusCode = HttpStatus.forbidden;
              await req.response.close();
              return;
            }
            if (req.method != 'GET' || req.uri.path != '/callback') {
              req.response.statusCode = HttpStatus.notFound;
              await req.response.close();
              return;
            }
            if (handled || completer.isCompleted) {
              req.response.statusCode = HttpStatus.conflict;
              await req.response.close();
              return;
            }

            final params = req.uri.queryParameters;
            final error = params['error'];
            final rawErrorDesc = (params['error_description'] ?? error ?? '')
                .replaceAll(RegExp(r'[\r\n]+'), ' ')
                .trim();
            final errorDesc = rawErrorDesc.isEmpty
                ? null
                : (rawErrorDesc.length > 180
                    ? '${rawErrorDesc.substring(0, 180)}...'
                    : rawErrorDesc);
            final code = params['code'];

            if (error != null && error.isNotEmpty) {
              handled = true;
              await _respondHtml(
                req.response,
                success: false,
                message:
                    'No se pudo completar el acceso con GitHub: ${errorDesc ?? 'Acceso denegado.'}',
              );
              if (!completer.isCompleted) {
                completer.completeError(
                  CloudException(errorDesc ?? 'Acceso denegado por GitHub.'),
                );
              }
              return;
            }

            if (code != null && code.isNotEmpty) {
              handled = true;
              await _respondHtml(
                req.response,
                success: true,
                message:
                    'Cuenta de GitHub autorizada en VaultStudy. Ya puedes cerrar esta pestaña y volver a la aplicación.',
              );
              if (!completer.isCompleted) {
                completer.complete(code);
              }
              return;
            }

            handled = true;
            await _respondHtml(
              req.response,
              success: false,
              message:
                  'Faltó el código de autorización. Asegúrate de que $redirectTo esté permitido en Supabase.',
            );
            if (!completer.isCompleted) {
              completer.completeError(
                const CloudException(
                  'No se recibió el código de autorización de Supabase.',
                ),
              );
            }
          } catch (_) {
            // Ignore malformed preflight browser requests.
          }
        });
      }

      final pkce = PkcePair.generate();
      final authUri = _client.buildOAuthAuthorizeUrl(
        provider: 'github',
        redirectTo: redirectTo,
        codeChallenge: pkce.codeChallenge,
      );

      state = state.copyWith(
        isSyncing: true,
        isWaitingOAuth: true,
        isOffline: false,
        syncProgressLabel: 'Esperando autorización de GitHub en tu navegador...',
        errorMessage: null,
        infoMessage: null,
      );

      final launched = await launchUrl(
        authUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw const CloudException(
          'No se pudo abrir el navegador predeterminado para iniciar sesión con GitHub.',
        );
      }

      final authCode = await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => throw const CloudException(
          'Tiempo de espera agotado esperando la respuesta de GitHub.',
        ),
      );

      await _closeOAuthServer();
      if (!ref.mounted) return false;

      state = state.copyWith(
        isWaitingOAuth: false,
        syncProgressLabel: 'Verificando sesión de GitHub...',
      );

      final session = await _client.exchangePkceCode(
        authCode: authCode,
        codeVerifier: pkce.codeVerifier,
      );
      await _saveSession(session);
      if (!ref.mounted) return false;

      state = state.copyWith(
        session: session,
        isSyncing: false,
        isWaitingOAuth: false,
        syncProgressLabel: null,
      );
      await syncNow(silentIfOffline: false);
      return state.errorMessage == null;
    } on CloudException catch (e) {
      await _closeOAuthServer();
      if (!ref.mounted) return false;
      state = state.copyWith(
        isSyncing: false,
        isWaitingOAuth: false,
        isOffline: e.isOffline,
        syncProgressLabel: null,
        errorMessage: e.message,
      );
      return false;
    } catch (_) {
      await _closeOAuthServer();
      if (!ref.mounted) return false;
      state = state.copyWith(
        isSyncing: false,
        isWaitingOAuth: false,
        syncProgressLabel: null,
        errorMessage:
            'No se pudo completar el acceso con GitHub. Inténtalo de nuevo.',
      );
      return false;
    }
  }

  Future<void> cancelGitHubSignIn({bool silent = false}) async {
    final completer = _oauthCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        const CloudException('Inicio de sesión con GitHub cancelado.'),
      );
    }
    _oauthCompleter = null;
    await _closeOAuthServer();
    if (!silent && ref.mounted) {
      state = state.copyWith(
        isSyncing: false,
        isWaitingOAuth: false,
        syncProgressLabel: null,
        errorMessage: null,
      );
    }
  }

  Future<HttpServer> _bindOAuthLoopbackServer() async {
    for (final port in const [48912, 48913, 48914, 0]) {
      try {
        return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      } on SocketException {
        continue;
      }
    }
    throw const CloudException(
      'No se pudo abrir un puerto local para recibir el acceso de GitHub.',
    );
  }

  Future<void> _closeOAuthServer() async {
    final sub = _appLinksSub;
    _appLinksSub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    final s = _oauthServer;
    _oauthServer = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> _respondHtml(
    HttpResponse response, {
    required bool success,
    required String message,
  }) async {
    final safeMsg = const HtmlEscape().convert(message);
    final accent = success ? '#4edea3' : '#ffb4ab';
    final heading = success ? 'Acceso autorizado' : 'Error de acceso';
    response.statusCode = success ? HttpStatus.ok : HttpStatus.badRequest;
    response.headers.contentType = ContentType.html;
    response.write('''
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8" />
  <title>VaultStudy • Auth</title>
  <style>
    body { margin:0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
           background:#0a0e14; color:#e6edf3; display:flex; align-items:center;
           justify-content:center; min-height:100vh; }
    .card { max-width:460px; padding:28px; background:#101419; border-radius:12px;
            border:1px solid $accent; box-shadow:0 16px 40px rgba(0,0,0,0.45); }
    h1 { margin:0 0 12px 0; font-size:20px; color:$accent; }
    p { margin:0; line-height:1.5; color:#c9d1d9; font-size:14px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>$heading</h1>
    <p>$safeMsg</p>
  </div>
</body>
</html>
''');
    await response.close();
  }

  Future<bool> signUp({
    required String email,
    required String password,
  }) async {
    await _ensureInitialized();
    state = state.copyWith(
      isSyncing: true,
      isOffline: false,
      syncProgressLabel: 'Creando cuenta...',
      errorMessage: null,
      infoMessage: null,
    );

    try {
      final result = await _client.signUp(
        email: email,
        password: password,
      );
      if (result.needsEmailConfirmation || result.session == null) {
        state = state.copyWith(
          isSyncing: false,
          syncProgressLabel: null,
          infoMessage:
              'Cuenta creada. Revisa ${result.email} para confirmar tu correo y luego inicia sesión.',
        );
        return true;
      }

      await _saveSession(result.session!);
      state = state.copyWith(
        session: result.session,
        isSyncing: false,
        syncProgressLabel: null,
      );
      await syncNow(silentIfOffline: false);
      return state.errorMessage == null;
    } on CloudException catch (e) {
      state = state.copyWith(
        isSyncing: false,
        isOffline: e.isOffline,
        syncProgressLabel: null,
        errorMessage: e.message,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isSyncing: false,
        syncProgressLabel: null,
        errorMessage: 'Error inesperado al crear la cuenta. Inténtalo de nuevo.',
      );
      return false;
    }
  }

  Future<bool> syncNow({bool silentIfOffline = false}) async {
    await _ensureInitialized();
    if (_activeSyncFuture != null) {
      return _activeSyncFuture!;
    }
    final completer = Completer<bool>();
    _activeSyncFuture = completer.future;

    try {
      final ok = await _runSyncCycle(silentIfOffline: silentIfOffline);
      completer.complete(ok);
      return ok;
    } catch (e) {
      if (!completer.isCompleted) completer.complete(false);
      return false;
    } finally {
      _activeSyncFuture = null;
    }
  }

  Future<bool> _runSyncCycle({required bool silentIfOffline}) async {
    var session = state.session;
    if (session == null) return false;

    state = state.copyWith(
      isSyncing: true,
      syncProgressLabel: 'Conectando con la nube...',
      errorMessage: null,
      infoMessage: null,
    );

    try {
      session = await _ensureValidSession(session);
      final repo = ref.read(vaultRepositoryProvider);
      final token = session.accessToken;
      final userId = session.userId;

      // 1. Push local deletions (tombstones) first
      final tombstones = await repo.getTombstones();
      if (tombstones.isNotEmpty) {
        state = state.copyWith(
          syncProgressLabel: 'Aplicando borrados pendientes...',
        );
      }
      for (final tomb in tombstones) {
        final deletedAt = tomb.deletedAt.toUtc();
        if (tomb.entityType == 'item') {
          await _client.softDeleteItem(
            token,
            id: tomb.id,
            deletedAt: deletedAt,
          );
          final objects = await _client.listItemStorageObjects(
            token,
            userId: userId,
            itemId: tomb.id,
          );
          if (objects.isNotEmpty) {
            await _client.deleteStorageObjects(token, objectPaths: objects);
          }
        } else if (tomb.entityType == 'annotation') {
          await _client.softDeleteAnnotation(
            token,
            id: tomb.id,
            deletedAt: deletedAt,
          );
        }
        await repo.removeTombstone(tomb.id, tomb.entityType);
      }

      // 2. Pull cloud state
      state = state.copyWith(syncProgressLabel: 'Descargando índice de la nube...');
      final remoteItems = await _client.fetchItems(token);
      final remoteAnnotations = await _client.fetchAnnotations(token);

      final localItems = await repo.getAllItems(includeExtractedText: false);
      final localById = {for (final i in localItems) i.id: i};
      final dirtyItems = await repo.getDirtyItems();
      final dirtyItemIds = {for (final i in dirtyItems) i.id};
      final remainingTombstones = await repo.getTombstones();
      final tombstoneItemIds = {
        for (final t in remainingTombstones)
          if (t.entityType == 'item') t.id,
      };
      final tombstoneAnnIds = {
        for (final t in remainingTombstones)
          if (t.entityType == 'annotation') t.id,
      };

      final deletedRemoteItemIds = {
        for (final dto in remoteItems)
          if (dto.isDeleted) dto.item.id,
      };
      final remoteItemMap = {for (final dto in remoteItems) dto.item.id: dto};

      final touchedAnnotationItemIds = <String>{};
      var vaultMutated = false;

      // Apply remote soft-deletions first
      for (final dto in remoteItems) {
        if (!dto.isDeleted) continue;
        final local = localById[dto.item.id];
        if (local == null) continue;
        final cloudTs = dto.deletedAt ?? dto.item.updatedAt;
        final localIsNewerDirty = dirtyItemIds.contains(local.id) &&
            local.updatedAt.toUtc().isAfter(cloudTs.toUtc());
        if (localIsNewerDirty) continue;

        await repo.deleteItem(
          local.id,
          deleteStoredFiles: true,
          recordTombstone: false,
        );
        localById.remove(local.id);
        vaultMutated = true;
      }

      // Apply active remote items topologically (parents before children)
      final activeRemoteItems = _sortRemoteParentsFirst(
        remoteItems.where((d) => !d.isDeleted).toList(),
      );
      final docsToDownload = <CloudVaultItemDto>[];
      final existingAfterDeletes = {
        for (final i in await repo.getAllItems(includeExtractedText: false))
          i.id: i,
      };

      for (final dto in activeRemoteItems) {
        final remote = dto.item;
        if (tombstoneItemIds.contains(remote.id)) continue;
        if (remote.parentId != null &&
            deletedRemoteItemIds.contains(remote.parentId)) {
          continue;
        }

        final local = existingAfterDeletes[remote.id];
        final localWins = local != null &&
            dirtyItemIds.contains(remote.id) &&
            !remote.updatedAt.toUtc().isAfter(local.updatedAt.toUtc());
        if (localWins) continue;

        final safeParentId = (remote.parentId != null &&
                existingAfterDeletes.containsKey(remote.parentId))
            ? remote.parentId
            : (remote.parentId == null ? null : null);

        if (remote.type.isDocument) {
          final needsBinary = await _needsLocalPdfBinary(
            local: local,
            remote: remote,
            hasStoragePath: (dto.storageObjectPath ?? '').isNotEmpty,
          );
          if (needsBinary) {
            docsToDownload.add(
              CloudVaultItemDto(
                item: remote.copyWith(parentId: safeParentId),
                storageObjectPath: dto.storageObjectPath,
              ),
            );
            // Temporarily keep parent existence map consistent if anything references it
            existingAfterDeletes[remote.id] =
                remote.copyWith(parentId: safeParentId);
            continue;
          }

          final preservedItem = remote.copyWith(
            parentId: safeParentId,
            filePath: local?.filePath ?? remote.filePath,
          );
          final needsDbUpdate = local == null ||
              local.title != preservedItem.title ||
              local.parentId != preservedItem.parentId ||
              local.type != preservedItem.type ||
              local.isPinned != preservedItem.isPinned ||
              local.sortOrder != preservedItem.sortOrder ||
              dirtyItemIds.contains(remote.id);

          if (needsDbUpdate) {
            await repo.insertItem(preservedItem, syncDirty: false);
            existingAfterDeletes[preservedItem.id] = preservedItem;
            vaultMutated = true;
          }
        } else {
          final normalized = remote.copyWith(parentId: safeParentId);
          final needsDbUpdate = local == null ||
              local.title != normalized.title ||
              local.parentId != normalized.parentId ||
              local.contentMd != normalized.contentMd ||
              local.isPinned != normalized.isPinned ||
              local.sortOrder != normalized.sortOrder ||
              local.updatedAt.toUtc() != normalized.updatedAt.toUtc() ||
              dirtyItemIds.contains(normalized.id);
          if (needsDbUpdate) {
            await repo.insertItem(normalized, syncDirty: false);
            existingAfterDeletes[normalized.id] = normalized;
            vaultMutated = true;
          }
        }
      }

      // Download missing/updated PDF binaries and extract offline page index
      for (var i = 0; i < docsToDownload.length; i++) {
        final dto = docsToDownload[i];
        final remote = dto.item;
        final objectPath = dto.storageObjectPath;
        if (objectPath == null || objectPath.isEmpty) continue;

        state = state.copyWith(
          syncProgressLabel:
              'Descargando PDF (${i + 1}/${docsToDownload.length}): ${remote.title}',
        );

        final bytes = await _client.downloadPdfBytes(
          token,
          objectPath: objectPath,
        );
        if (bytes == null || bytes.isEmpty || !_looksLikePdf(bytes)) {
          continue;
        }

        final filesDir = await DatabaseHelper.instance.getVaultFilesDir();
        final base = p.basename(objectPath).replaceAll(
              RegExp(r'[^a-zA-Z0-9._-]'),
              '_',
            );
        final prefix = remote.id.length >= 8
            ? remote.id.substring(0, 8)
            : remote.id;
        final fileName = base.startsWith('${prefix}_') ? base : '${prefix}_$base';
        final fullPath = p.join(filesDir, fileName);
        await File(fullPath).writeAsBytes(bytes, flush: true);

        final relativePath = p.join(
          DatabaseHelper.vaultFilesFolderName,
          fileName,
        );
        final extraction =
            await VaultStorageService.instance.extractTextAndPagesFromFile(
          itemId: remote.id,
          fullPath: fullPath,
        );

        final savedItem = remote.copyWith(
          filePath: relativePath,
          fileSize: bytes.length,
          extractedText: extraction.fullText.isNotEmpty
              ? extraction.fullText
              : remote.extractedText,
        );
        await repo.insertPdfWithPages(
          savedItem,
          extraction.pages,
          syncDirty: false,
        );
        vaultMutated = true;
      }

      // 3. Apply remote PDF annotations
      final currentItemIds = {
        for (final i in await repo.getAllItems(includeExtractedText: false))
          i.id,
      };
      final localAnns = await repo.getAllAnnotations();
      final localAnnById = {for (final a in localAnns) a.id: a};
      final dirtyAnns = await repo.getDirtyAnnotations();
      final dirtyAnnIds = {for (final a in dirtyAnns) a.id};

      for (final dto in remoteAnnotations) {
        final ann = dto.annotation;
        if (dto.isDeleted) {
          if (localAnnById.containsKey(ann.id) && !dirtyAnnIds.contains(ann.id)) {
            await repo.deleteAnnotation(ann.id, recordTombstone: false);
            touchedAnnotationItemIds.add(ann.itemId);
          }
          continue;
        }
        if (tombstoneAnnIds.contains(ann.id)) continue;
        if (!currentItemIds.contains(ann.itemId)) continue;
        if (dirtyAnnIds.contains(ann.id)) continue;

        if (!localAnnById.containsKey(ann.id)) {
          await repo.addAnnotation(ann, syncDirty: false);
          touchedAnnotationItemIds.add(ann.itemId);
        }
      }

      // 4. Push local dirty items (+ PDF binaries)
      final remainingDirtyItems = _sortLocalParentsFirst(
        await repo.getDirtyItems(),
      );
      if (remainingDirtyItems.isNotEmpty) {
        final cloudRows = <Map<String, dynamic>>[];
        final pushedIds = <String>[];

        for (var i = 0; i < remainingDirtyItems.length; i++) {
          final item = remainingDirtyItems[i];
          final existingCloud = remoteItemMap[item.id];
          var storageObjectPath = existingCloud?.storageObjectPath;

          if (item.type.isDocument && item.filePath != null) {
            final fullPath =
                await DatabaseHelper.instance.resolveVaultFilePath(item.filePath!);
            final file = File(fullPath);
            if (await file.exists()) {
              final bytes = await file.readAsBytes();
              final mustUpload = storageObjectPath == null ||
                  storageObjectPath.isEmpty ||
                  existingCloud == null ||
                  existingCloud.item.fileSize != bytes.length ||
                  existingCloud.isDeleted;

              if (mustUpload) {
                state = state.copyWith(
                  syncProgressLabel: 'Subiendo PDF: ${item.title}',
                );
                final cleanName = p.basename(fullPath).replaceAll(
                      RegExp(r'[^a-zA-Z0-9._-]'),
                      '_',
                    );
                storageObjectPath = '$userId/${item.id}/$cleanName';
                await _client.uploadPdfBytes(
                  token,
                  objectPath: storageObjectPath,
                  bytes: bytes,
                );
              }
            }
          }

          cloudRows.add(
            CloudVaultItemDto.toCloudMap(
              item,
              userId: userId,
              storageObjectPath: storageObjectPath,
            ),
          );
          pushedIds.add(item.id);
        }

        state = state.copyWith(syncProgressLabel: 'Guardando cambios en la nube...');
        for (var offset = 0; offset < cloudRows.length; offset += 50) {
          final end = (offset + 50 > cloudRows.length)
              ? cloudRows.length
              : offset + 50;
          await _client.upsertItems(token, cloudRows.sublist(offset, end));
        }
        await repo.markItemsSynced(pushedIds);
      }

      // 5. Push local dirty PDF annotations
      final remainingDirtyAnns = await repo.getDirtyAnnotations();
      if (remainingDirtyAnns.isNotEmpty) {
        final validDirtyAnns = remainingDirtyAnns
            .where((a) => currentItemIds.contains(a.itemId))
            .toList();
        if (validDirtyAnns.isNotEmpty) {
          final rows = validDirtyAnns
              .map((a) => CloudAnnotationDto.toCloudMap(a, userId: userId))
              .toList();
          for (var offset = 0; offset < rows.length; offset += 100) {
            final end =
                (offset + 100 > rows.length) ? rows.length : offset + 100;
            await _client.upsertAnnotations(token, rows.sublist(offset, end));
          }
          await repo.markAnnotationsSynced(
            validDirtyAnns.map((a) => a.id).toList(),
          );
        }
      }

      // 6. Finalize state & refresh Riverpod consumers
      final now = DateTime.now();
      await _sessionStore.saveLastSync(now);
      final pendingLeft = await repo.getPendingSyncCount();

      if (vaultMutated) {
        ref.invalidate(vaultItemsProvider);
      }
      for (final itemId in touchedAnnotationItemIds) {
        ref.invalidate(pdfAnnotationsProvider(itemId));
      }

      if (!ref.mounted) return true;
      state = state.copyWith(
        session: session,
        isSyncing: false,
        isOffline: false,
        lastSyncedAt: now,
        pendingChangesCount: pendingLeft,
        syncProgressLabel: null,
        errorMessage: null,
      );
      return true;
    } on CloudException catch (e) {
      final pendingLeft = await ref
          .read(vaultRepositoryProvider)
          .getPendingSyncCount()
          .catchError((_) => state.pendingChangesCount);
      if (!ref.mounted) return false;

      if (e.isUnauthorized) {
        // Session revoked or expired permanently
        await _clearPersistedSessionOnly();
        state = state.copyWith(
          session: null,
          isSyncing: false,
          isOffline: false,
          pendingChangesCount: pendingLeft,
          syncProgressLabel: null,
          errorMessage:
              'La sesión ha expirado. Vuelve a iniciar sesión para sincronizar.',
        );
        return false;
      }

      state = state.copyWith(
        isSyncing: false,
        isOffline: e.isOffline,
        pendingChangesCount: pendingLeft,
        syncProgressLabel: null,
        errorMessage: (e.isOffline && silentIfOffline) ? null : e.message,
      );
      return false;
    } catch (_) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        isSyncing: false,
        syncProgressLabel: null,
        errorMessage:
            'Error inesperado durante la sincronización. Comprueba tu conexión.',
      );
      return false;
    }
  }

  /// Signs out of Supabase AND wipes all local vault data, files, and tabs.
  /// Must ONLY be called after the 3 consecutive user confirmation warnings.
  Future<void> signOutAndWipeLocal() async {
    _autoSyncDebounce?.cancel();
    final activeSync = _activeSyncFuture;
    if (activeSync != null) {
      await activeSync.catchError((_) => false);
    }

    var remoteRevoked = true;
    final currentSession = state.session;
    if (currentSession != null) {
      remoteRevoked = await _client.signOutRemote(currentSession.accessToken);
    }

    await _clearPersistedSessionOnly();
    await ref.read(workspaceProvider.notifier).resetToEmptyAfterSignOut();
    await DatabaseHelper.instance.clearAllLocalVaultData();

    ref.invalidate(vaultItemsProvider);
    ref.invalidate(pdfAnnotationsProvider);

    if (!ref.mounted) return;
    state = CloudSyncState(
      hasInitialized: true,
      infoMessage: (currentSession != null && !remoteRevoked)
          ? 'Datos y PDFs locales borrados. Sin conexión para revocar el token en el servidor; caducará automáticamente.'
          : 'Sesión cerrada. Todos los datos y PDFs locales han sido borrados.',
    );
  }

  void clearMessages() {
    state = state.copyWith(errorMessage: null, infoMessage: null);
  }

  Future<CloudSession> _ensureValidSession(CloudSession current) async {
    if (!current.isExpiredOrNearExpiry) return current;
    if (current.refreshToken.isEmpty) return current;
    final refreshed = await _client.refreshSession(current.refreshToken);
    await _saveSession(refreshed);
    if (ref.mounted) {
      state = state.copyWith(session: refreshed);
    }
    return refreshed;
  }

  Future<bool> _needsLocalPdfBinary({
    required VaultItem? local,
    required VaultItem remote,
    required bool hasStoragePath,
  }) async {
    if (!hasStoragePath) return false;
    if (local == null || local.filePath == null || local.filePath!.isEmpty) {
      return true;
    }
    final resolved =
        await DatabaseHelper.instance.resolveVaultFilePath(local.filePath!);
    final file = File(resolved);
    if (!await file.exists()) return true;
    if (remote.updatedAt.toUtc().isAfter(local.updatedAt.toUtc()) &&
        remote.fileSize != local.fileSize) {
      return true;
    }
    return false;
  }

  Future<void> _saveSession(CloudSession session) =>
      _sessionStore.saveSession(session);

  Future<void> _clearPersistedSessionOnly() => _sessionStore.clearSession();

  bool _looksLikePdf(List<int> bytes) {
    // PDF header `%PDF-` must appear within the first 1024 bytes per PDF spec.
    if (bytes.length < 5) return false;
    final limit = bytes.length < 1024 ? bytes.length - 4 : 1020;
    for (var i = 0; i <= limit; i++) {
      if (bytes[i] == 0x25 && // %
          bytes[i + 1] == 0x50 && // P
          bytes[i + 2] == 0x44 && // D
          bytes[i + 3] == 0x46 && // F
          bytes[i + 4] == 0x2D) {
        return true;
      }
    }
    return false;
  }

  List<CloudVaultItemDto> _sortRemoteParentsFirst(
    List<CloudVaultItemDto> items,
  ) {
    final byId = {for (final dto in items) dto.item.id: dto};
    final visited = <String>{};
    final ordered = <CloudVaultItemDto>[];

    void visit(CloudVaultItemDto dto) {
      if (!visited.add(dto.item.id)) return;
      final parentId = dto.item.parentId;
      if (parentId != null && byId.containsKey(parentId)) {
        visit(byId[parentId]!);
      }
      ordered.add(dto);
    }

    for (final dto in items) {
      visit(dto);
    }
    return ordered;
  }

  List<VaultItem> _sortLocalParentsFirst(List<VaultItem> items) {
    final byId = {for (final item in items) item.id: item};
    final visited = <String>{};
    final ordered = <VaultItem>[];

    void visit(VaultItem item) {
      if (!visited.add(item.id)) return;
      final parentId = item.parentId;
      if (parentId != null && byId.containsKey(parentId)) {
        visit(byId[parentId]!);
      }
      ordered.add(item);
    }

    for (final item in items) {
      visit(item);
    }
    return ordered;
  }
}

final cloudSyncProvider =
    NotifierProvider<CloudSyncNotifier, CloudSyncState>(CloudSyncNotifier.new);
