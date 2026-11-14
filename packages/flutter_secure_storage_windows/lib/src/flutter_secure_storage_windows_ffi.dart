import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

class _AsyncLock {
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final next = _last.then((_) => fn());
    _last = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}

/// Pure Dart FFI Windows implementation backed by Windows DPAPI
/// (`CryptProtectData` / `CryptUnprotectData`), requiring no Visual Studio ATL.
class FlutterSecureStorageWindows extends FlutterSecureStoragePlatform {
  FlutterSecureStorageWindows() : _storage = DpapiJsonFileMapStorage();

  final DpapiJsonFileMapStorage _storage;
  final _lock = _AsyncLock();

  static void registerWith() {
    FlutterSecureStoragePlatform.instance = FlutterSecureStorageWindows();
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) =>
      _lock.run(() async {
        final map = await _storage.load(options);
        return map.containsKey(key);
      });

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) =>
      _lock.run(() async {
        final map = await _storage.load(options);
        final initialSize = map.length;
        map.remove(key);
        if (map.length != initialSize) {
          await _storage.save(map, options);
        }
      });

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      _lock.run(() async {
        await _storage.clear(options);
      });

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) =>
      _lock.run(() async {
        final map = await _storage.load(options);
        return map[key];
      });

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) =>
      _lock.run(() async => _storage.load(options));

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) =>
      _lock.run(() async {
        final map = await _storage.load(options);
        map[key] = value;
        await _storage.save(map, options);
      });
}

@visibleForTesting
const String encryptedJsonFileName = 'flutter_secure_storage.dat';

class DpapiJsonFileMapStorage {
  FutureOr<String> _getJsonFilePath() async {
    final appDataDirectory = await getApplicationSupportDirectory();
    return path.canonicalize(
      path.join(appDataDirectory.path, encryptedJsonFileName),
    );
  }

  FutureOr<Map<String, String>> load(Map<String, String> options) async {
    final file = File(await _getJsonFilePath());
    if (!file.existsSync()) {
      return {};
    }

    late final Uint8List encryptedText;
    try {
      encryptedText = await file.readAsBytes();
    } on FileSystemException {
      debugPrint('Secure storage read skipped due to file access error.');
      return {};
    }

    late final String plainText;
    try {
      plainText = using((alloc) {
        final pEncryptedText = alloc<Uint8>(encryptedText.length);
        pEncryptedText
            .asTypedList(encryptedText.length)
            .setAll(0, encryptedText);

        final encryptedTextBlob =
            alloc.allocate<CRYPT_INTEGER_BLOB>(sizeOf<CRYPT_INTEGER_BLOB>());
        encryptedTextBlob.ref.cbData = encryptedText.length;
        encryptedTextBlob.ref.pbData = pEncryptedText;

        final plainTextBlob =
            alloc.allocate<CRYPT_INTEGER_BLOB>(sizeOf<CRYPT_INTEGER_BLOB>());
        final Win32Result(value: isUnprotected, error: unprotectError) =
            CryptUnprotectData(
          encryptedTextBlob,
          null,
          null,
          null,
          0,
          plainTextBlob,
        );
        if (!isUnprotected) {
          throw WindowsException(
            unprotectError.toHRESULT(),
            message: 'Failure on CryptUnprotectData()',
          );
        }
        if (plainTextBlob.ref.pbData.address == NULL) {
          throw WindowsException(
            ERROR_OUTOFMEMORY.toHRESULT(),
            message: 'Failure on CryptUnprotectData()',
          );
        }

        try {
          return utf8.decoder.convert(
            plainTextBlob.ref.pbData.asTypedList(plainTextBlob.ref.cbData),
          );
        } finally {
          if (plainTextBlob.ref.pbData.address != NULL) {
            LocalFree(HLOCAL(plainTextBlob.ref.pbData.cast()));
          }
        }
      });
    } on FormatException {
      await file.delete();
      rethrow;
    } on WindowsException {
      await file.delete();
      rethrow;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(plainText);
    } on FormatException {
      await file.delete();
      rethrow;
    }

    if (decoded is! Map) {
      await file.delete();
      throw const FormatException('JSON is not an object.');
    }

    return {
      for (final e
          in decoded.entries.where((x) => x.key is String && x.value is String))
        e.key as String: e.value as String,
    };
  }

  FutureOr<void> save(
    Map<String, String> data,
    Map<String, String> options,
  ) async {
    final file = File(await _getJsonFilePath());
    final plainText = utf8.encode(jsonEncode(data));

    await using<FutureOr<void>>((alloc) async {
      final pPlainText = alloc<Uint8>(plainText.length);
      pPlainText.asTypedList(plainText.length).setAll(0, plainText);

      final plainTextBlob =
          alloc.allocate<CRYPT_INTEGER_BLOB>(sizeOf<CRYPT_INTEGER_BLOB>());
      plainTextBlob.ref.cbData = plainText.length;
      plainTextBlob.ref.pbData = pPlainText;

      final encryptedTextBlob =
          alloc.allocate<CRYPT_INTEGER_BLOB>(sizeOf<CRYPT_INTEGER_BLOB>());
      final Win32Result(value: isProtected, error: protectError) =
          CryptProtectData(
        plainTextBlob,
        null,
        null,
        null,
        0,
        encryptedTextBlob,
      );
      if (!isProtected) {
        throw WindowsException(
          protectError.toHRESULT(),
          message: 'Failure on CryptProtectData()',
        );
      }
      if (encryptedTextBlob.ref.pbData.address == NULL) {
        throw WindowsException(
          ERROR_OUTOFMEMORY.toHRESULT(),
          message: 'Failure on CryptProtectData()',
        );
      }

      try {
        final encryptedText = encryptedTextBlob.ref.pbData
            .asTypedList(encryptedTextBlob.ref.cbData);
        await (await file.create(recursive: true))
            .writeAsBytes(encryptedText, flush: true);
      } finally {
        if (encryptedTextBlob.ref.pbData.address != NULL) {
          LocalFree(HLOCAL(encryptedTextBlob.ref.pbData.cast()));
        }
      }
    });
  }

  FutureOr<void> clear(Map<String, String> options) async {
    final file = File(await _getJsonFilePath());
    if (file.existsSync()) {
      await file.delete();
    }
  }
}
