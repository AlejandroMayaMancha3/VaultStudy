import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

/// Stub implementation on non-FFI targets.
class FlutterSecureStorageWindows extends FlutterSecureStoragePlatform {
  FlutterSecureStorageWindows()
      : assert(false, 'Cannot instantiate this class.');

  static void registerWith() {
    FlutterSecureStoragePlatform.instance = FlutterSecureStorageWindows();
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) =>
      Future.value(false);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) =>
      Future.value();

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      Future.value();

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) =>
      Future.value();

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) =>
      Future.value({});

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) =>
      Future.value();
}
