import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_cloud_client.dart';

/// Encrypted OS-backed storage for the user's Supabase OAuth / JWT session
/// (Windows DPAPI, macOS/iOS Keychain, Android Keystore, Linux libsecret).
class SecureSessionStore {
  SecureSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String sessionKey = 'vault_cloud_session_v1';
  static const String lastSyncKey = 'vault_cloud_last_sync_v1';

  final FlutterSecureStorage _storage;

  Future<CloudSession?> readSession() async {
    final prefs = await SharedPreferences.getInstance();
    final legacyRaw = prefs.getString(sessionKey);

    try {
      final secureRaw = await _storage.read(key: sessionKey);
      if (secureRaw != null && secureRaw.isNotEmpty) {
        if (legacyRaw != null) {
          await prefs.remove(sessionKey);
        }
        return CloudSession.fromJson(
          jsonDecode(secureRaw) as Map<String, dynamic>,
        );
      }

      // One-time transparent migration from legacy plaintext SharedPreferences
      if (legacyRaw != null && legacyRaw.isNotEmpty) {
        final migrated = CloudSession.fromJson(
          jsonDecode(legacyRaw) as Map<String, dynamic>,
        );
        await _storage.write(key: sessionKey, value: legacyRaw);
        await prefs.remove(sessionKey);
        return migrated;
      }
      return null;
    } catch (_) {
      // Corrupt or unreadable secure store entry -> force clean re-auth.
      await prefs.remove(sessionKey);
      return null;
    }
  }

  Future<void> saveSession(CloudSession session) async {
    final encoded = jsonEncode(session.toJson());
    await _storage.write(key: sessionKey, value: encoded);

    // Ensure no plaintext token remains in SharedPreferences.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(sessionKey);
  }

  Future<void> clearSession() async {
    try {
      await _storage.delete(key: sessionKey);
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(sessionKey);
    await prefs.remove(lastSyncKey);
  }

  Future<DateTime?> readLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(lastSyncKey);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  Future<void> saveLastSync(DateTime timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(lastSyncKey, timestamp.toUtc().toIso8601String());
  }
}
