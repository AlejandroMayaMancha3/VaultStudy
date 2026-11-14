import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'workspace_state.dart';

/// Persisted session state for Mobile (< 900px) explorer and reader.
class MobileSessionState {
  const MobileSessionState({
    this.tabIndex = 0,
    this.expandedSubjectIds = const {'subj-desarrollo-web'},
    this.activeReaderItemId,
    this.activeReaderPage = 1,
  });

  factory MobileSessionState.defaults() => const MobileSessionState();

  final int tabIndex;
  final Set<String> expandedSubjectIds;
  final String? activeReaderItemId;
  final int activeReaderPage;

  MobileSessionState copyWith({
    int? tabIndex,
    Set<String>? expandedSubjectIds,
    Object? activeReaderItemId = _mobileSentinel,
    int? activeReaderPage,
  }) {
    return MobileSessionState(
      tabIndex: tabIndex ?? this.tabIndex,
      expandedSubjectIds: expandedSubjectIds ?? this.expandedSubjectIds,
      activeReaderItemId: identical(activeReaderItemId, _mobileSentinel)
          ? this.activeReaderItemId
          : activeReaderItemId as String?,
      activeReaderPage: activeReaderPage ?? this.activeReaderPage,
    );
  }

  Map<String, Object?> toJson() => {
        'tabIndex': tabIndex,
        'expandedSubjectIds': expandedSubjectIds.toList(),
        'activeReaderItemId': activeReaderItemId,
        'activeReaderPage': activeReaderPage,
      };

  factory MobileSessionState.fromJson(Map<String, dynamic> json) {
    final rawIds = (json['expandedSubjectIds'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toSet();
    return MobileSessionState(
      tabIndex: (json['tabIndex'] as num?)?.toInt().clamp(0, 2) ?? 0,
      expandedSubjectIds: rawIds,
      activeReaderItemId: json['activeReaderItemId'] as String?,
      activeReaderPage: (json['activeReaderPage'] as num?)?.toInt() ?? 1,
    );
  }
}

const Object _mobileSentinel = Object();

/// Persists open tabs, active panes, current PDF pages, and folder expand/collapse
/// states in `SharedPreferences` across app restarts.
class WorkspacePersistence {
  WorkspacePersistence._();

  static const String _desktopKey = 'vault_workspace_state_v1';
  static const String _mobileKey = 'vault_mobile_state_v1';

  static WorkspaceState? _cachedDesktop;
  static MobileSessionState? _cachedMobile;
  static bool _preloaded = false;
  static Future<void>? _preloadFuture;

  static bool get hasPreloaded => _preloaded;

  static WorkspaceState get cachedDesktopState =>
      _cachedDesktop ?? WorkspaceState.defaults();

  static MobileSessionState get cachedMobileState =>
      _cachedMobile ?? MobileSessionState.defaults();

  /// Loads persisted desktop and mobile session state before `runApp` or concurrently.
  static Future<void> preload() {
    return _preloadFuture ??= _performPreload();
  }

  static Future<void> _performPreload() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final desktopRaw = prefs.getString(_desktopKey);
      if (desktopRaw != null && desktopRaw.isNotEmpty) {
        final map = jsonDecode(desktopRaw) as Map<String, dynamic>;
        _cachedDesktop = WorkspaceState.fromJson(map);
      } else {
        _cachedDesktop = WorkspaceState.defaults();
      }

      final mobileRaw = prefs.getString(_mobileKey);
      if (mobileRaw != null && mobileRaw.isNotEmpty) {
        final map = jsonDecode(mobileRaw) as Map<String, dynamic>;
        _cachedMobile = MobileSessionState.fromJson(map);
      } else {
        _cachedMobile = MobileSessionState.defaults();
      }
    } catch (_) {
      _cachedDesktop ??= WorkspaceState.defaults();
      _cachedMobile ??= MobileSessionState.defaults();
    } finally {
      _preloaded = true;
    }
  }

  static Future<WorkspaceState?> loadDesktopState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_desktopKey);
      if (raw == null || raw.isEmpty) return null;
      final loaded = WorkspaceState.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      _cachedDesktop = loaded;
      return loaded;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveDesktopState(WorkspaceState state) async {
    _cachedDesktop = state;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_desktopKey, jsonEncode(state.toJson()));
    } catch (_) {
      // Ignore persistence errors cleanly in restricted/headless contexts.
    }
  }

  static Future<MobileSessionState?> loadMobileState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_mobileKey);
      if (raw == null || raw.isEmpty) return null;
      final loaded = MobileSessionState.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      _cachedMobile = loaded;
      return loaded;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveMobileState(MobileSessionState state) async {
    _cachedMobile = state;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_mobileKey, jsonEncode(state.toJson()));
    } catch (_) {
      // Ignore persistence errors cleanly in restricted/headless contexts.
    }
  }

  /// Clears persisted open tabs and expanded folders cleanly (e.g., on Sign Out).
  static Future<void> clearAllLayouts() async {
    const emptyDesktop = WorkspaceState();
    const emptyMobile = MobileSessionState(
      tabIndex: 0,
      expandedSubjectIds: <String>{},
    );
    await saveDesktopState(emptyDesktop);
    await saveMobileState(emptyMobile);
  }

  /// Resets in-memory cache (for tests).
  static void resetCacheForTest() {
    _cachedDesktop = null;
    _cachedMobile = null;
    _preloaded = false;
    _preloadFuture = null;
  }
}
