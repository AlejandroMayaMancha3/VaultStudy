import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../../core/config/supabase_config.dart';
import '../../vault_tree/domain/vault_item.dart';

/// Cryptographic PKCE verifier & S256 challenge pair (RFC 7636).
class PkcePair {
  const PkcePair({required this.codeVerifier, required this.codeChallenge});

  final String codeVerifier;
  final String codeChallenge;

  static const String _charset =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  factory PkcePair.generate({int length = 64}) {
    final rng = Random.secure();
    final verifier = List<String>.generate(
      length,
      (_) => _charset[rng.nextInt(_charset.length)],
    ).join();
    return PkcePair.fromVerifier(verifier);
  }

  factory PkcePair.fromVerifier(String verifier) {
    final digest = sha256.convert(ascii.encode(verifier));
    final challenge = base64UrlEncode(digest.bytes).replaceAll('=', '');
    return PkcePair(codeVerifier: verifier, codeChallenge: challenge);
  }
}

/// Error thrown by [SupabaseCloudClient] with offline detection.
class CloudException implements Exception {
  const CloudException(
    this.message, {
    this.statusCode,
    this.isOffline = false,
  });

  final String message;
  final int? statusCode;
  final bool isOffline;

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'CloudException($statusCode, offline=$isOffline): $message';
}

/// Persisted Supabase Auth session.
class CloudSession {
  const CloudSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.email,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String email;
  final DateTime expiresAt;

  bool get isExpiredOrNearExpiry => DateTime.now()
      .toUtc()
      .isAfter(expiresAt.toUtc().subtract(const Duration(seconds: 90)));

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'user_id': userId,
        'email': email,
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  factory CloudSession.fromJson(Map<String, dynamic> json) {
    return CloudSession(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      userId: json['user_id'] as String,
      email: (json['email'] as String?) ?? '',
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  factory CloudSession.fromAuthResponse(Map<String, dynamic> json) {
    final user = (json['user'] as Map<String, dynamic>?) ?? const {};
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    final rawExpiresAt = json['expires_at'] as num?;
    final expiresAt = rawExpiresAt != null
        ? DateTime.fromMillisecondsSinceEpoch(
            rawExpiresAt.toInt() * 1000,
            isUtc: true,
          )
        : DateTime.now().toUtc().add(Duration(seconds: expiresIn));

    return CloudSession(
      accessToken: json['access_token'] as String,
      refreshToken: (json['refresh_token'] as String?) ?? '',
      userId: (user['id'] as String?) ?? '',
      email: (user['email'] as String?) ?? '',
      expiresAt: expiresAt,
    );
  }
}

class CloudAuthResult {
  const CloudAuthResult({
    this.session,
    required this.email,
    this.needsEmailConfirmation = false,
  });

  final CloudSession? session;
  final String email;
  final bool needsEmailConfirmation;
}

class CloudVaultItemDto {
  const CloudVaultItemDto({
    required this.item,
    this.storageObjectPath,
    this.deletedAt,
  });

  final VaultItem item;
  final String? storageObjectPath;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  factory CloudVaultItemDto.fromCloudMap(Map<String, dynamic> map) {
    final updatedAt =
        DateTime.tryParse(map['updated_at'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc();
    final deletedAtRaw = map['deleted_at'] as String?;
    return CloudVaultItemDto(
      item: VaultItem(
        id: map['id'] as String,
        parentId: map['parent_id'] as String?,
        title: (map['title'] as String?) ?? 'Sin título',
        type: VaultItemType.fromDb((map['type'] as String?) ?? 'note'),
        filePath: map['file_path'] as String?,
        fileSize: (map['file_size'] as num?)?.toInt() ?? 0,
        extractedText: (map['extracted_text'] as String?) ?? '',
        contentMd: (map['content_md'] as String?) ?? '',
        isPinned: (map['is_pinned'] as bool?) ?? false,
        sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
        updatedAt: updatedAt,
      ),
      storageObjectPath: map['storage_object_path'] as String?,
      deletedAt: deletedAtRaw != null
          ? DateTime.tryParse(deletedAtRaw)?.toUtc()
          : null,
    );
  }

  static Map<String, dynamic> toCloudMap(
    VaultItem item, {
    required String userId,
    String? storageObjectPath,
    DateTime? deletedAt,
  }) {
    return {
      'id': item.id,
      'user_id': userId,
      'parent_id': item.parentId,
      'title': item.title,
      'type': item.type.dbValue,
      'file_path': item.filePath,
      'storage_object_path': storageObjectPath,
      'file_size': item.fileSize,
      'extracted_text': item.extractedText,
      'content_md': item.contentMd,
      'is_pinned': item.isPinned,
      'sort_order': item.sortOrder,
      'updated_at': item.updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
    };
  }
}

class CloudAnnotationDto {
  const CloudAnnotationDto({
    required this.annotation,
    required this.updatedAt,
    this.deletedAt,
  });

  final PdfAnnotation annotation;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  factory CloudAnnotationDto.fromCloudMap(Map<String, dynamic> map) {
    final rectsRaw = map['rects_json'] as String? ?? '[]';
    final decoded = jsonDecode(rectsRaw) as List<dynamic>;
    final createdAt =
        DateTime.tryParse(map['created_at'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc();
    final updatedAt =
        DateTime.tryParse(map['updated_at'] as String? ?? '')?.toUtc() ??
            createdAt;
    final deletedAtRaw = map['deleted_at'] as String?;
    return CloudAnnotationDto(
      annotation: PdfAnnotation(
        id: map['id'] as String,
        itemId: map['item_id'] as String,
        pageNumber: (map['page_number'] as num).toInt(),
        rects: decoded
            .map((e) => NormalizedRect.fromJson(e as Map<String, dynamic>))
            .toList(),
        selectedText: (map['selected_text'] as String?) ?? '',
        colorHex: (map['color_hex'] as String?) ?? '#4EDEA3',
        note: (map['note'] as String?) ?? '',
        createdAt: createdAt,
      ),
      updatedAt: updatedAt,
      deletedAt: deletedAtRaw != null
          ? DateTime.tryParse(deletedAtRaw)?.toUtc()
          : null,
    );
  }

  static Map<String, dynamic> toCloudMap(
    PdfAnnotation annotation, {
    required String userId,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    final ts = (updatedAt ?? annotation.createdAt).toUtc().toIso8601String();
    return {
      'id': annotation.id,
      'user_id': userId,
      'item_id': annotation.itemId,
      'page_number': annotation.pageNumber,
      'rects_json': jsonEncode(annotation.rects.map((r) => r.toJson()).toList()),
      'selected_text': annotation.selectedText,
      'color_hex': annotation.colorHex,
      'note': annotation.note,
      'created_at': annotation.createdAt.toUtc().toIso8601String(),
      'updated_at': ts,
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
    };
  }
}

/// Pure-Dart HTTP client for Supabase Auth, PostgREST, and Storage.
/// Avoids native C++ plugin overhead and keeps offline exam launches instant.
class SupabaseCloudClient {
  SupabaseCloudClient({String? baseUrl, String? publishableKey})
      : baseUrl = (baseUrl ?? SupabaseConfig.projectUrl).replaceAll(RegExp(r'/+$'), ''),
        publishableKey = publishableKey ?? SupabaseConfig.publishableKey {
    final uri = Uri.tryParse(this.baseUrl);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      throw ArgumentError.value(
        this.baseUrl,
        'baseUrl',
        'Debe ser una URL HTTPS válida.',
      );
    }
  }

  final String baseUrl;
  final String publishableKey;

  static const Duration _timeout = Duration(seconds: 15);
  static const int _maxResponseBytes = 60 * 1024 * 1024; // 60 MB

  HttpClient _newHttpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    return client;
  }

  // ---------------------------------------------------------------------------
  // AUTH
  // ---------------------------------------------------------------------------

  Future<CloudAuthResult> signInWithPassword({
    required String email,
    required String password,
  }) async {
    final res = await _requestJson(
      'POST',
      '/auth/v1/token?grant_type=password',
      body: {'email': email.trim(), 'password': password},
    );
    return CloudAuthResult(
      session: CloudSession.fromAuthResponse(res as Map<String, dynamic>),
      email: email.trim(),
    );
  }

  Uri buildOAuthAuthorizeUrl({
    required String provider,
    required String redirectTo,
    required String codeChallenge,
  }) {
    return Uri.parse('$baseUrl/auth/v1/authorize').replace(
      queryParameters: {
        'provider': provider,
        'redirect_to': redirectTo,
        'code_challenge': codeChallenge,
        'code_challenge_method': 's256',
        if (provider == 'github') 'scopes': 'read:user user:email',
      },
    );
  }

  Future<CloudSession> exchangePkceCode({
    required String authCode,
    required String codeVerifier,
  }) async {
    final res = await _requestJson(
      'POST',
      '/auth/v1/token?grant_type=pkce',
      body: {
        'auth_code': authCode,
        'code_verifier': codeVerifier,
      },
    );
    return CloudSession.fromAuthResponse(res as Map<String, dynamic>);
  }

  Future<CloudAuthResult> signUp({
    required String email,
    required String password,
  }) async {
    final res = await _requestJson(
      'POST',
      '/auth/v1/signup',
      body: {'email': email.trim(), 'password': password},
    ) as Map<String, dynamic>;

    if (res.containsKey('access_token')) {
      return CloudAuthResult(
        session: CloudSession.fromAuthResponse(res),
        email: email.trim(),
      );
    }

    return CloudAuthResult(
      session: null,
      email: (res['email'] as String?) ?? email.trim(),
      needsEmailConfirmation: true,
    );
  }

  Future<CloudSession> refreshSession(String refreshToken) async {
    final res = await _requestJson(
      'POST',
      '/auth/v1/token?grant_type=refresh_token',
      body: {'refresh_token': refreshToken},
    );
    return CloudSession.fromAuthResponse(res as Map<String, dynamic>);
  }

  Future<bool> signOutRemote(String accessToken) async {
    try {
      await _requestBytes(
        'POST',
        '/auth/v1/logout',
        accessToken: accessToken,
      );
      return true;
    } catch (_) {
      // Best-effort remote logout; local wipe always proceeds.
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // VAULT ITEMS (PostgREST)
  // ---------------------------------------------------------------------------

  Future<List<CloudVaultItemDto>> fetchItems(String accessToken) async {
    final res = await _requestJson(
      'GET',
      '/rest/v1/vault_items?select=*&order=sort_order.asc',
      accessToken: accessToken,
    );
    final list = res as List<dynamic>;
    return list
        .map((e) => CloudVaultItemDto.fromCloudMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> upsertItems(
    String accessToken,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;
    await _requestBytes(
      'POST',
      '/rest/v1/vault_items?on_conflict=user_id,id',
      accessToken: accessToken,
      headers: const {
        'Prefer': 'resolution=merge-duplicates,return=minimal',
        'Content-Type': 'application/json',
      },
      bodyBytes: utf8.encode(jsonEncode(rows)),
    );
  }

  Future<void> softDeleteItem(
    String accessToken, {
    required String id,
    required DateTime deletedAt,
  }) async {
    final iso = deletedAt.toUtc().toIso8601String();
    final encodedId = Uri.encodeQueryComponent(id);
    await _requestBytes(
      'PATCH',
      '/rest/v1/vault_items?id=eq.$encodedId',
      accessToken: accessToken,
      headers: const {
        'Prefer': 'return=minimal',
        'Content-Type': 'application/json',
      },
      bodyBytes: utf8.encode(jsonEncode({'deleted_at': iso, 'updated_at': iso})),
    );
  }

  // ---------------------------------------------------------------------------
  // PDF ANNOTATIONS (PostgREST)
  // ---------------------------------------------------------------------------

  Future<List<CloudAnnotationDto>> fetchAnnotations(String accessToken) async {
    final res = await _requestJson(
      'GET',
      '/rest/v1/vault_pdf_annotations?select=*',
      accessToken: accessToken,
    );
    final list = res as List<dynamic>;
    return list
        .map((e) => CloudAnnotationDto.fromCloudMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> upsertAnnotations(
    String accessToken,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;
    await _requestBytes(
      'POST',
      '/rest/v1/vault_pdf_annotations?on_conflict=user_id,id',
      accessToken: accessToken,
      headers: const {
        'Prefer': 'resolution=merge-duplicates,return=minimal',
        'Content-Type': 'application/json',
      },
      bodyBytes: utf8.encode(jsonEncode(rows)),
    );
  }

  Future<void> softDeleteAnnotation(
    String accessToken, {
    required String id,
    required DateTime deletedAt,
  }) async {
    final iso = deletedAt.toUtc().toIso8601String();
    final encodedId = Uri.encodeQueryComponent(id);
    await _requestBytes(
      'PATCH',
      '/rest/v1/vault_pdf_annotations?id=eq.$encodedId',
      accessToken: accessToken,
      headers: const {
        'Prefer': 'return=minimal',
        'Content-Type': 'application/json',
      },
      bodyBytes: utf8.encode(jsonEncode({'deleted_at': iso, 'updated_at': iso})),
    );
  }

  // ---------------------------------------------------------------------------
  // PDF STORAGE
  // ---------------------------------------------------------------------------

  Future<void> uploadPdfBytes(
    String accessToken, {
    required String objectPath,
    required Uint8List bytes,
  }) async {
    final encodedObject = _encodeStoragePath(objectPath);
    await _requestBytes(
      'POST',
      '/storage/v1/object/${SupabaseConfig.storageBucket}/$encodedObject',
      accessToken: accessToken,
      headers: const {
        'x-upsert': 'true',
        'Content-Type': 'application/pdf',
      },
      bodyBytes: bytes,
    );
  }

  Future<Uint8List?> downloadPdfBytes(
    String accessToken, {
    required String objectPath,
  }) async {
    final encodedObject = _encodeStoragePath(objectPath);
    try {
      return await _requestBytes(
        'GET',
        '/storage/v1/object/authenticated/${SupabaseConfig.storageBucket}/$encodedObject',
        accessToken: accessToken,
      );
    } on CloudException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 400) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> deleteStorageObjects(
    String accessToken, {
    required List<String> objectPaths,
  }) async {
    if (objectPaths.isEmpty) return;
    try {
      await _requestBytes(
        'DELETE',
        '/storage/v1/object/${SupabaseConfig.storageBucket}',
        accessToken: accessToken,
        headers: const {'Content-Type': 'application/json'},
        bodyBytes: utf8.encode(jsonEncode({'prefixes': objectPaths})),
      );
    } on CloudException catch (e) {
      if (e.statusCode == 404) return;
      rethrow;
    }
  }

  Future<List<String>> listItemStorageObjects(
    String accessToken, {
    required String userId,
    required String itemId,
  }) async {
    final prefix = '$userId/$itemId/';
    try {
      final res = await _requestJson(
        'POST',
        '/storage/v1/object/list/${SupabaseConfig.storageBucket}',
        accessToken: accessToken,
        body: {'prefix': prefix, 'limit': 100, 'offset': 0},
      );
      if (res is! List) return const [];
      return res
          .whereType<Map<String, dynamic>>()
          .map((e) => e['name'] as String?)
          .whereType<String>()
          .map((name) => '$prefix$name')
          .toList();
    } on CloudException catch (e) {
      if (e.statusCode == 404) return const [];
      rethrow;
    }
  }

  String _encodeStoragePath(String objectPath) {
    return objectPath.split('/').map(Uri.encodeComponent).join('/');
  }

  // ---------------------------------------------------------------------------
  // LOW-LEVEL HTTP
  // ---------------------------------------------------------------------------

  Future<dynamic> _requestJson(
    String method,
    String pathAndQuery, {
    String? accessToken,
    Map<String, dynamic>? body,
  }) async {
    final bytes = await _requestBytes(
      method,
      pathAndQuery,
      accessToken: accessToken,
      headers: body != null ? const {'Content-Type': 'application/json'} : null,
      bodyBytes: body != null ? utf8.encode(jsonEncode(body)) : null,
    );
    if (bytes.isEmpty) return const {};
    return jsonDecode(utf8.decode(bytes));
  }

  Future<Uint8List> _requestBytes(
    String method,
    String pathAndQuery, {
    String? accessToken,
    Map<String, String>? headers,
    List<int>? bodyBytes,
  }) async {
    final client = _newHttpClient();
    try {
      final uri = Uri.parse('$baseUrl$pathAndQuery');
      final request = await client.openUrl(method, uri).timeout(_timeout);
      request.followRedirects = false;
      request.maxRedirects = 0;
      request.headers.set('apikey', publishableKey);
      if (accessToken != null && accessToken.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $accessToken');
      }
      if (headers != null) {
        headers.forEach((k, v) => request.headers.set(k, v));
      }
      if (bodyBytes != null) {
        request.add(bodyBytes);
      }

      final response = await request.close().timeout(_timeout);
      final responseBytes = await _collectBytes(response).timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CloudException(
          _extractErrorMessage(response.statusCode, responseBytes),
          statusCode: response.statusCode,
        );
      }
      return responseBytes;
    } on SocketException {
      throw const CloudException(
        'Sin conexión a internet. VaultStudy sigue operando en modo offline.',
        isOffline: true,
      );
    } on TimeoutException {
      throw const CloudException(
        'Tiempo de espera agotado al conectar con la nube. Trabajando en modo offline.',
        isOffline: true,
      );
    } on HandshakeException {
      throw const CloudException(
        'No se pudo establecer conexión segura con Supabase.',
        isOffline: true,
      );
    } on HttpException catch (e) {
      throw CloudException('Error de red HTTP: ${e.message}', isOffline: true);
    } finally {
      client.close();
    }
  }

  Future<Uint8List> _collectBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response) {
      total += chunk.length;
      if (total > _maxResponseBytes) {
        throw const CloudException(
          'La respuesta del servidor supera el tamaño máximo permitido.',
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  String _extractErrorMessage(int statusCode, Uint8List bytes) {
    if (bytes.isEmpty) return 'Error HTTP $statusCode';
    try {
      final raw = utf8.decode(bytes);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final msg = decoded['msg'] ??
            decoded['message'] ??
            decoded['error_description'] ??
            decoded['error'];
        if (msg is String && msg.isNotEmpty) {
          return _localizeAuthMessage(msg);
        }
      }
      return 'Error HTTP $statusCode al comunicar con el servidor.';
    } catch (_) {
      return 'Error HTTP $statusCode';
    }
  }

  String _localizeAuthMessage(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('invalid login credentials')) {
      return 'Correo o contraseña incorrectos.';
    }
    if (lower.contains('email not confirmed')) {
      return 'Debes confirmar tu correo electrónico antes de iniciar sesión.';
    }
    if (lower.contains('user already registered')) {
      return 'Ese correo ya está registrado. Prueba a iniciar sesión.';
    }
    if (lower.contains('password should be at least')) {
      return 'La contraseña debe tener al menos 6 caracteres.';
    }
    return message;
  }
}
