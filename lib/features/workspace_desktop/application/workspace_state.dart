import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../vault_tree/application/vault_providers.dart';
import '../../vault_tree/domain/vault_item.dart';
import 'workspace_persistence.dart';

class WorkspaceTab {
  const WorkspaceTab({required this.itemId, this.targetPage = 1});

  final String itemId;
  final int targetPage;

  WorkspaceTab copyWith({int? targetPage}) {
    return WorkspaceTab(
      itemId: itemId,
      targetPage: targetPage ?? this.targetPage,
    );
  }

  Map<String, Object?> toJson() => {
        'itemId': itemId,
        'targetPage': targetPage,
      };

  factory WorkspaceTab.fromJson(Map<String, dynamic> json) {
    return WorkspaceTab(
      itemId: json['itemId'] as String,
      targetPage: ((json['targetPage'] as num?)?.toInt() ?? 1).clamp(1, 99999),
    );
  }
}

class WorkspaceState {
  const WorkspaceState({
    this.tabs = const [],
    this.leftItemId,
    this.rightItemId,
    this.activeSingleItemId,
    this.isSplitMode = true,
    this.isExamFullscreen = false,
    this.isSidebarVisible = true,
    this.selectedFolderId,
    this.expandedFolderIds = const {},
    this.splitRatio = 0.5,
  });

  /// Initial state shown only on first launch before the user saves any layout.
  factory WorkspaceState.defaults() => const WorkspaceState(
        tabs: [
          WorkspaceTab(itemId: 'doc-boletin-1', targetPage: 3),
          WorkspaceTab(itemId: 'note-apuntes-sql'),
        ],
        leftItemId: 'doc-boletin-1',
        rightItemId: 'note-apuntes-sql',
        activeSingleItemId: 'note-apuntes-sql',
        isSplitMode: true,
        isExamFullscreen: false,
        isSidebarVisible: true,
        selectedFolderId: 'topic-dw-tema1',
        expandedFolderIds: {
          'subj-desarrollo-web',
          'topic-dw-tema1',
          'subj-interfaces-web',
          'topic-iw-tema1',
        },
        splitRatio: 0.5,
      );

  final List<WorkspaceTab> tabs;
  final String? leftItemId;
  final String? rightItemId;
  final String? activeSingleItemId;
  final bool isSplitMode;
  final bool isExamFullscreen;
  final bool isSidebarVisible;
  final String? selectedFolderId;
  final Set<String> expandedFolderIds;
  final double splitRatio;

  int targetPageFor(String itemId) {
    return tabs
            .where((t) => t.itemId == itemId)
            .firstOrNull
            ?.targetPage ??
        1;
  }

  WorkspaceState copyWith({
    List<WorkspaceTab>? tabs,
    Object? leftItemId = _sentinel,
    Object? rightItemId = _sentinel,
    Object? activeSingleItemId = _sentinel,
    bool? isSplitMode,
    bool? isExamFullscreen,
    bool? isSidebarVisible,
    Object? selectedFolderId = _sentinel,
    Set<String>? expandedFolderIds,
    double? splitRatio,
  }) {
    return WorkspaceState(
      tabs: tabs ?? this.tabs,
      leftItemId: identical(leftItemId, _sentinel)
          ? this.leftItemId
          : leftItemId as String?,
      rightItemId: identical(rightItemId, _sentinel)
          ? this.rightItemId
          : rightItemId as String?,
      activeSingleItemId: identical(activeSingleItemId, _sentinel)
          ? this.activeSingleItemId
          : activeSingleItemId as String?,
      isSplitMode: isSplitMode ?? this.isSplitMode,
      isExamFullscreen: isExamFullscreen ?? this.isExamFullscreen,
      isSidebarVisible: isSidebarVisible ?? this.isSidebarVisible,
      selectedFolderId: identical(selectedFolderId, _sentinel)
          ? this.selectedFolderId
          : selectedFolderId as String?,
      expandedFolderIds: expandedFolderIds ?? this.expandedFolderIds,
      splitRatio: splitRatio ?? this.splitRatio,
    );
  }

  Map<String, Object?> toJson() => {
        'tabs': tabs.map((t) => t.toJson()).toList(),
        'leftItemId': leftItemId,
        'rightItemId': rightItemId,
        'activeSingleItemId': activeSingleItemId,
        'isSplitMode': isSplitMode,
        'isSidebarVisible': isSidebarVisible,
        'selectedFolderId': selectedFolderId,
        'expandedFolderIds': expandedFolderIds.toList(),
        'splitRatio': splitRatio,
      };

  factory WorkspaceState.fromJson(Map<String, dynamic> json) {
    final rawTabs = (json['tabs'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(WorkspaceTab.fromJson)
        .toList();
    final rawExpanded = (json['expandedFolderIds'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toSet();
    final ratio = ((json['splitRatio'] as num?)?.toDouble() ?? 0.5)
        .clamp(0.25, 0.75);

    return WorkspaceState(
      tabs: rawTabs,
      leftItemId: json['leftItemId'] as String?,
      rightItemId: json['rightItemId'] as String?,
      activeSingleItemId: json['activeSingleItemId'] as String?,
      isSplitMode: (json['isSplitMode'] as bool?) ?? true,
      isExamFullscreen: false,
      isSidebarVisible: (json['isSidebarVisible'] as bool?) ?? true,
      selectedFolderId: json['selectedFolderId'] as String?,
      expandedFolderIds: rawExpanded,
      splitRatio: ratio,
    );
  }
}

const Object _sentinel = Object();

enum TargetPane { auto, left, right }

class WorkspaceNotifier extends Notifier<WorkspaceState> {
  bool _userMutated = false;
  final List<WorkspaceTab> _closedTabsHistory = [];

  @override
  WorkspaceState build() {
    ref.listen<AsyncValue<List<VaultItem>>>(vaultItemsProvider, (_, next) {
      final items = next.value;
      if (items != null) {
        _pruneDeletedItems(items);
      }
    });

    if (!WorkspacePersistence.hasPreloaded) {
      unawaited(_loadSavedAsync());
    }
    final initial = WorkspacePersistence.cachedDesktopState;
    final existingItems = ref.read(vaultItemsProvider).value;
    if (existingItems != null) {
      return _computePruned(initial, existingItems) ?? initial;
    }
    return initial;
  }

  Future<void> _loadSavedAsync() async {
    final saved = await WorkspacePersistence.loadDesktopState();
    if (saved == null || _userMutated || !ref.mounted) return;
    final items = ref.read(vaultItemsProvider).value;
    state = (items != null ? _computePruned(saved, items) : null) ?? saved;
  }

  void _commit(WorkspaceState next, {bool persist = true}) {
    _userMutated = true;
    state = next;
    if (persist) {
      unawaited(WorkspacePersistence.saveDesktopState(next));
    }
  }

  WorkspaceState? _computePruned(
    WorkspaceState candidate,
    List<VaultItem> items,
  ) {
    final byId = {for (final i in items) i.id: i};
    final validTabs =
        candidate.tabs.where((t) => byId.containsKey(t.itemId)).toList();
    final validLeft =
        candidate.leftItemId != null && byId.containsKey(candidate.leftItemId)
            ? candidate.leftItemId
            : null;
    final validRight = candidate.rightItemId != null &&
            byId.containsKey(candidate.rightItemId)
        ? candidate.rightItemId
        : null;
    final validSingle = candidate.activeSingleItemId != null &&
            byId.containsKey(candidate.activeSingleItemId)
        ? candidate.activeSingleItemId
        : null;
    final validSelectedFolder = candidate.selectedFolderId != null &&
            byId[candidate.selectedFolderId]?.type == VaultItemType.folder
        ? candidate.selectedFolderId
        : null;
    final validExpanded = candidate.expandedFolderIds
        .where((id) => byId[id]?.type == VaultItemType.folder)
        .toSet();

    final changed = validTabs.length != candidate.tabs.length ||
        validLeft != candidate.leftItemId ||
        validRight != candidate.rightItemId ||
        validSingle != candidate.activeSingleItemId ||
        validSelectedFolder != candidate.selectedFolderId ||
        validExpanded.length != candidate.expandedFolderIds.length;

    if (!changed) return null;

    return candidate.copyWith(
      tabs: validTabs,
      leftItemId: validLeft,
      rightItemId: validRight,
      activeSingleItemId: validSingle,
      selectedFolderId: validSelectedFolder,
      expandedFolderIds: validExpanded,
    );
  }

  void _pruneDeletedItems(List<VaultItem> items) {
    final pruned = _computePruned(state, items);
    if (pruned == null) return;
    state = pruned;
    unawaited(WorkspacePersistence.saveDesktopState(pruned));
  }

  void toggleFolder(String folderId) {
    final next = Set<String>.from(state.expandedFolderIds);
    if (next.contains(folderId)) {
      next.remove(folderId);
    } else {
      next.add(folderId);
    }
    _commit(
      state.copyWith(
        expandedFolderIds: next,
        selectedFolderId: folderId,
      ),
    );
  }

  void expandFolder(String folderId) {
    final next = Set<String>.from(state.expandedFolderIds)..add(folderId);
    _commit(
      state.copyWith(
        expandedFolderIds: next,
        selectedFolderId: folderId,
      ),
    );
  }

  void selectFolder(String? folderId) {
    _commit(state.copyWith(selectedFolderId: folderId));
  }

  void expandAncestors(List<VaultItem> allItems, VaultItem item) {
    final byId = {for (final i in allItems) i.id: i};
    final next = Set<String>.from(state.expandedFolderIds);
    String? cursor = item.parentId;
    while (cursor != null) {
      next.add(cursor);
      cursor = byId[cursor]?.parentId;
    }
    _commit(state.copyWith(expandedFolderIds: next));
  }

  void openItem(
    VaultItem item, {
    int? page,
    TargetPane pane = TargetPane.auto,
    bool? forceSplit,
  }) {
    if (item.type == VaultItemType.folder) {
      toggleFolder(item.id);
      return;
    }

    final existingIdx = state.tabs.indexWhere((t) => t.itemId == item.id);
    final nextTabs = List<WorkspaceTab>.from(state.tabs);
    if (existingIdx >= 0) {
      if (page != null) {
        nextTabs[existingIdx] = nextTabs[existingIdx].copyWith(targetPage: page);
      }
    } else {
      nextTabs.add(WorkspaceTab(itemId: item.id, targetPage: page ?? 1));
    }

    final resolvedPane = switch (pane) {
      TargetPane.left => TargetPane.left,
      TargetPane.right => TargetPane.right,
      TargetPane.auto =>
        item.type.isDocument ? TargetPane.left : TargetPane.right,
    };

    _commit(
      state.copyWith(
        tabs: nextTabs,
        leftItemId:
            resolvedPane == TargetPane.left ? item.id : state.leftItemId,
        rightItemId:
            resolvedPane == TargetPane.right ? item.id : state.rightItemId,
        activeSingleItemId: item.id,
        isSplitMode: forceSplit ?? state.isSplitMode,
      ),
    );
  }

  void updateTabPage(String itemId, int page) {
    final clamped = page.clamp(1, 99999);
    final idx = state.tabs.indexWhere((t) => t.itemId == itemId);
    if (idx < 0 || state.tabs[idx].targetPage == clamped) return;
    final nextTabs = List<WorkspaceTab>.from(state.tabs);
    nextTabs[idx] = nextTabs[idx].copyWith(targetPage: clamped);
    _commit(state.copyWith(tabs: nextTabs));
  }

  void closeTab(String itemId) {
    final closed = state.tabs.where((t) => t.itemId == itemId).firstOrNull;
    if (closed != null) {
      _closedTabsHistory.removeWhere((t) => t.itemId == itemId);
      _closedTabsHistory.add(closed);
      if (_closedTabsHistory.length > 15) {
        _closedTabsHistory.removeAt(0);
      }
    }
    final nextTabs = state.tabs.where((t) => t.itemId != itemId).toList();
    String? nextLeft = state.leftItemId == itemId ? null : state.leftItemId;
    String? nextRight = state.rightItemId == itemId ? null : state.rightItemId;
    String? nextSingle =
        state.activeSingleItemId == itemId ? null : state.activeSingleItemId;

    if (nextSingle == null && nextTabs.isNotEmpty) {
      nextSingle = nextTabs.last.itemId;
    }
    final allItems = ref.read(vaultItemsProvider).value ?? [];
    nextLeft ??= nextTabs
        .where((t) =>
            allItems.any((i) => i.id == t.itemId && i.type.isDocument))
        .firstOrNull
        ?.itemId;
    nextRight ??= nextTabs
        .where((t) =>
            allItems.any((i) => i.id == t.itemId && i.type == VaultItemType.note))
        .firstOrNull
        ?.itemId;

    _commit(
      state.copyWith(
        tabs: nextTabs,
        leftItemId: nextLeft,
        rightItemId: nextRight,
        activeSingleItemId: nextSingle,
      ),
    );
  }

  void closeActiveTab() {
    final targetId = state.activeSingleItemId ??
        state.rightItemId ??
        state.leftItemId ??
        state.tabs.lastOrNull?.itemId;
    if (targetId != null) {
      closeTab(targetId);
    }
  }

  void reopenLastClosedTab() {
    final allItems = ref.read(vaultItemsProvider).value ?? [];
    final byId = {for (final i in allItems) i.id: i};
    while (_closedTabsHistory.isNotEmpty) {
      final candidate = _closedTabsHistory.removeLast();
      final item = byId[candidate.itemId];
      if (item != null) {
        openItem(item, page: candidate.targetPage);
        return;
      }
    }
  }

  void toggleSidebar() {
    _commit(state.copyWith(isSidebarVisible: !state.isSidebarVisible));
  }

  void setSidebarVisible(bool visible) {
    _commit(state.copyWith(isSidebarVisible: visible));
  }

  void setSplitMode(bool split) {
    _commit(state.copyWith(isSplitMode: split));
  }

  void toggleExamFullscreen() {
    state = state.copyWith(isExamFullscreen: !state.isExamFullscreen);
  }

  void setExamFullscreen(bool value) {
    state = state.copyWith(isExamFullscreen: value);
  }

  void setSplitRatio(double ratio) {
    _commit(state.copyWith(splitRatio: ratio.clamp(0.25, 0.75)));
  }

  Future<void> resetToEmptyAfterSignOut() async {
    _closedTabsHistory.clear();
    const empty = WorkspaceState();
    _commit(empty, persist: true);
    await WorkspacePersistence.clearAllLayouts();
  }
}

final workspaceProvider =
    NotifierProvider<WorkspaceNotifier, WorkspaceState>(WorkspaceNotifier.new);
