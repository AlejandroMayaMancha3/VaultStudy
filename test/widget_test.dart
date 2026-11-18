import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:vaultstudy/app.dart';
import 'package:vaultstudy/core/database/database_helper.dart';
import 'package:vaultstudy/core/database/minimal_pdf_generator.dart';
import 'package:vaultstudy/core/storage/vault_storage_service.dart';
import 'package:vaultstudy/core/theme/app_theme.dart';
import 'package:vaultstudy/features/cloud_sync/application/cloud_sync_service.dart';
import 'package:vaultstudy/features/cloud_sync/data/secure_session_store.dart';
import 'package:vaultstudy/features/cloud_sync/data/supabase_cloud_client.dart';
import 'package:vaultstudy/features/global_search/domain/search_result.dart';
import 'package:vaultstudy/features/notes_editor/application/code_execution_service.dart';
import 'package:vaultstudy/features/notes_editor/application/markdown_parser.dart';
import 'package:vaultstudy/features/notes_editor/presentation/widgets/code_block_card.dart';
import 'package:vaultstudy/features/notes_editor/presentation/widgets/vault_markdown_reader.dart';
import 'package:vaultstudy/features/pdf_viewer/application/pdf_highlight_utils.dart';
import 'package:vaultstudy/features/vault_tree/application/vault_providers.dart';
import 'package:vaultstudy/features/vault_tree/data/vault_repository.dart';
import 'package:vaultstudy/features/vault_tree/domain/vault_item.dart';
import 'package:vaultstudy/features/vault_tree/presentation/vault_dialogs.dart';
import 'package:vaultstudy/features/workspace_desktop/application/workspace_persistence.dart';
import 'package:vaultstudy/features/workspace_desktop/application/workspace_state.dart';

void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    WorkspacePersistence.resetCacheForTest();
  });

  group('VaultMarkdownParser', () {
    test('parses headings, paragraphs, code blocks with file path, tips and checklists', () {
      const sample = '''
## Consultas SQL

Texto explicativo con `INNER JOIN`.

```sql
-- file: queries/test.sql
SELECT * FROM estudiantes;
```

> [!TIP]
> Usar alias claros.

- [x] Revisar índices
- [ ] Repasar ACID
''';

      final blocks = VaultMarkdownParser.parse(sample);
      expect(blocks.length, 5);
      expect(blocks[0], isA<MdHeadingBlock>());
      expect((blocks[0] as MdHeadingBlock).text, 'Consultas SQL');
      expect(blocks[1], isA<MdParagraphBlock>());
      expect(blocks[2], isA<MdCodeBlock>());
      final code = blocks[2] as MdCodeBlock;
      expect(code.language, 'sql');
      expect(code.filePath, 'queries/test.sql');
      expect(code.code, 'SELECT * FROM estudiantes;');
      expect(blocks[3], isA<MdCalloutBlock>());
      expect((blocks[3] as MdCalloutBlock).tag, 'TIP');
      expect(blocks[4], isA<MdChecklistBlock>());
      final checklist = blocks[4] as MdChecklistBlock;
      expect(checklist.entries.length, 2);
      expect(checklist.entries[0].checked, isTrue);
      expect(checklist.entries[1].checked, isFalse);
      expect(VaultMarkdownParser.countCodeSnippets(sample), 1);
    });

    test('toggles checklist line cleanly', () {
      const md = '- [ ] Tarea A\n- [x] Tarea B';
      final toggled = VaultMarkdownParser.toggleChecklistLine(md, 0, true);
      expect(toggled, '- [x] Tarea A\n- [x] Tarea B');
    });
  });

  group('MinimalPdfGenerator', () {
    test('generates valid multi-page PDF 1.4 structure', () {
      final bytes = MinimalPdfGenerator.buildPdf(
        title: 'Boletin 1',
        pagesLines: const [
          ['Pagina 1'],
          ['Pagina 2'],
          ['Pagina 3 INNER JOIN'],
        ],
      );
      final text = latin1.decode(bytes);
      expect(text.startsWith('%PDF-1.4'), isTrue);
      expect(text.contains('/Count 3'), isTrue);
      expect(text.contains('INNER JOIN'), isTrue);
      expect(text.trimRight().endsWith('%%EOF'), isTrue);
    });
  });

  group('VaultRepository (SQLite FFI in-memory)', () {
    late Database db;
    late VaultRepository repo;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (d) async => d.execute('PRAGMA foreign_keys = ON'),
          onCreate: (d, _) => DatabaseHelper.createSchema(d),
        ),
      );
      repo = VaultRepository(databaseProvider: () async => db);
    });

    tearDown(() async {
      await db.close();
    });

    test('supports recursive hierarchy, cascade delete, cycle guard and search', () async {
      final now = DateTime.now();
      await repo.insertItem(
        VaultItem(
          id: 'f1',
          parentId: null,
          title: 'Desarrollo Web',
          type: VaultItemType.folder,
          updatedAt: now,
        ),
      );
      await repo.insertItem(
        VaultItem(
          id: 'f2',
          parentId: 'f1',
          title: 'Tema 1',
          type: VaultItemType.folder,
          updatedAt: now,
        ),
      );
      await repo.insertPdfWithPages(
        VaultItem(
          id: 'pdf1',
          parentId: 'f2',
          title: 'Boletín 1.pdf',
          type: VaultItemType.pdf,
          extractedText: 'Consulta con INNER JOIN en pagina 3',
          updatedAt: now,
        ),
        const [
          PdfPageEntry(itemId: 'pdf1', pageNumber: 1, content: 'Portada'),
          PdfPageEntry(
            itemId: 'pdf1',
            pageNumber: 3,
            content: 'Ejercicio con INNER JOIN y HAVING',
          ),
        ],
      );
      await repo.insertItem(
        VaultItem(
          id: 'note1',
          parentId: 'f2',
          title: 'Apuntes SQL',
          type: VaultItemType.note,
          contentMd: 'Texto normal\n```sql\nSELECT * FROM a INNER JOIN b;\n```',
          updatedAt: now,
        ),
      );

      // Search in PDFs finds exact page 3
      final pdfHits = await repo.search('INNER JOIN', filter: SearchFilter.pdfs);
      expect(pdfHits.length, 1);
      expect(pdfHits.first.matchedPageNumber, 3);
      expect(pdfHits.first.breadcrumb, 'Desarrollo Web > Tema 1');

      // Search Solo Código finds fenced block in note1
      final codeHits =
          await repo.search('INNER JOIN', filter: SearchFilter.codeOnly);
      expect(codeHits.length, 1);
      expect(codeHits.first.item.id, 'note1');
      expect(codeHits.first.isCodeMatch, isTrue);

      // Prevent moving folder into its own descendant
      await expectLater(
        () => repo.moveItem('f1', 'f2'),
        throwsArgumentError,
      );

      // Annotations persistence
      await repo.addAnnotation(
        PdfAnnotation(
          id: 'ann1',
          itemId: 'pdf1',
          pageNumber: 3,
          rects: const [
            NormalizedRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.25),
          ],
          selectedText: 'INNER JOIN',
          colorHex: '#4EDEA3',
          createdAt: now,
        ),
      );
      expect((await repo.getAnnotations('pdf1')).length, 1);

      // Cascade delete removes folder, descendants, pages, and annotations
      await repo.deleteItem('f1', deleteStoredFiles: false);
      expect(await repo.getAllItems(), isEmpty);
      expect(await repo.getAnnotations('pdf1'), isEmpty);
    });
  });

  group('Widgets & Adaptive Shell', () {
    testWidgets('CodeBlockCard copies code and shows confirmation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: CodeBlockCard(
              language: 'sql',
              filePath: 'queries/relacionales.sql',
              code: 'SELECT 1;',
            ),
          ),
        ),
      );

      expect(find.text('SQL'), findsOneWidget);
      expect(find.text('queries/relacionales.sql'), findsOneWidget);
      expect(find.text('Copiar código'), findsOneWidget);

      await tester.tap(find.text('Copiar código'));
      await tester.pump();
      expect(find.text('¡Copiado!'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('VaultMarkdownReader toggles interactive checklist', (tester) async {
      int? toggledLine;
      bool? toggledValue;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: VaultMarkdownReader(
              contentMd: '- [ ] Repasar SQL',
              onToggleChecklist: (line, val) {
                toggledLine = line;
                toggledValue = val;
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.check_box_outline_blank_rounded));
      expect(toggledLine, 0);
      expect(toggledValue, isTrue);
    });

    testWidgets('VaultStudyApp switches between Mobile and Desktop at 900px', (tester) async {
      final sampleItems = [
        VaultItem(
          id: 'subj-desarrollo-web',
          parentId: null,
          title: 'Desarrollo Web',
          type: VaultItemType.folder,
          updatedAt: DateTime(2026),
        ),
        VaultItem(
          id: 'note-apuntes-sql',
          parentId: 'subj-desarrollo-web',
          title: 'Apuntes SQL y Consultas',
          type: VaultItemType.note,
          isPinned: true,
          contentMd: '## SQL\nTexto de prueba',
          updatedAt: DateTime(2026),
        ),
      ];

      Widget buildApp(Size size) {
        return ProviderScope(
          overrides: [
            vaultItemsProvider.overrideWith(() => _FakeVaultItemsNotifier(sampleItems)),
            examReadOnlyProvider.overrideWith(() => _FakeExamReadOnlyNotifier()),
          ],
          child: MediaQuery(
            data: MediaQueryData(size: size),
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: const VaultStudyApp(),
            ),
          ),
        );
      }

      // Desktop layout (>= 900px)
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(buildApp(const Size(1280, 800)));
      await tester.pumpAndSettle();
      expect(find.text('ÁRBOL DE BÓVEDA'), findsOneWidget);
      expect(find.text('MODO EXAMEN: OFFLINE 100% LISTO'), findsOneWidget);

      // Mobile layout (< 900px)
      tester.view.physicalSize = const Size(412, 892);
      await tester.pumpWidget(buildApp(const Size(412, 892)));
      await tester.pumpAndSettle();
      expect(find.text('Mis Apuntes'), findsOneWidget);
      expect(find.text('SYNC OFFLINE'), findsOneWidget);
    });
  });

  group('WorkspacePersistence & Session Restore', () {
    test('persists exact opened tabs, PDF page, and closed/open folders across restarts', () async {
      final items = [
        VaultItem(
          id: 'subj-1',
          parentId: null,
          title: 'Sistemas',
          type: VaultItemType.folder,
          updatedAt: DateTime(2026),
        ),
        VaultItem(
          id: 'subj-2',
          parentId: null,
          title: 'Redes',
          type: VaultItemType.folder,
          updatedAt: DateTime(2026),
        ),
        VaultItem(
          id: 'pdf-1',
          parentId: 'subj-1',
          title: 'Tema1.pdf',
          type: VaultItemType.pdf,
          updatedAt: DateTime(2026),
        ),
        VaultItem(
          id: 'note-1',
          parentId: 'subj-2',
          title: 'Resumen',
          type: VaultItemType.note,
          updatedAt: DateTime(2026),
        ),
      ];

      final c1 = ProviderContainer(
        overrides: [
          vaultItemsProvider.overrideWith(() => _FakeVaultItemsNotifier(items)),
        ],
      );
      await c1.read(vaultItemsProvider.future);
      final notifier1 = c1.read(workspaceProvider.notifier);

      // Open specific folder and close another, open custom tabs & page
      notifier1.expandFolder('subj-1');
      notifier1.openItem(items[2], page: 7);
      notifier1.openItem(items[3]);
      notifier1.updateTabPage('pdf-1', 12);
      notifier1.setSplitMode(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c1.dispose();

      // Simulate cold restart
      WorkspacePersistence.resetCacheForTest();
      await WorkspacePersistence.preload();

      final c2 = ProviderContainer(
        overrides: [
          vaultItemsProvider.overrideWith(() => _FakeVaultItemsNotifier(items)),
        ],
      );
      await c2.read(vaultItemsProvider.future);
      final restored = c2.read(workspaceProvider);

      expect(restored.expandedFolderIds, {'subj-1'});
      expect(restored.expandedFolderIds.contains('subj-2'), isFalse);
      expect(restored.tabs.map((t) => t.itemId).toList(), ['pdf-1', 'note-1']);
      expect(restored.targetPageFor('pdf-1'), 12);
      expect(restored.isSplitMode, isFalse);

      // Close all folders and all tabs -> restart must stay closed/empty
      final notifier2 = c2.read(workspaceProvider.notifier);
      notifier2.toggleFolder('subj-1'); // collapses subj-1
      notifier2.closeTab('pdf-1');
      notifier2.closeTab('note-1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c2.dispose();

      WorkspacePersistence.resetCacheForTest();
      await WorkspacePersistence.preload();
      final c3 = ProviderContainer(
        overrides: [
          vaultItemsProvider.overrideWith(() => _FakeVaultItemsNotifier(items)),
        ],
      );
      await c3.read(vaultItemsProvider.future);
      final emptyRestored = c3.read(workspaceProvider);

      expect(emptyRestored.expandedFolderIds, isEmpty);
      expect(emptyRestored.tabs, isEmpty);
      c3.dispose();
    });
  });

  group('PdfHighlightUtils & Undo/Redo', () {
    test('mergeLineRects combines adjacent fragments on same line cleanly', () {
      const frags = [
        NormalizedRect(left: 0.10, top: 0.20, right: 0.20, bottom: 0.22),
        NormalizedRect(left: 0.21, top: 0.20, right: 0.35, bottom: 0.22),
        NormalizedRect(left: 0.10, top: 0.30, right: 0.28, bottom: 0.32),
      ];

      final merged = mergeLineRects(frags);
      expect(merged.length, 2);
      expect(merged[0].left, closeTo(0.10, 0.001));
      expect(merged[0].right, closeTo(0.35, 0.001));
      expect(merged[1].top, closeTo(0.30, 0.001));
    });

    test('strokeToNormalizedRects creates bounded horizontal strip', () {
      final rects = strokeToNormalizedRects(const [
        Offset(0.15, 0.40),
        Offset(0.45, 0.40),
        Offset(0.70, 0.40),
      ]);

      expect(rects.length, 1);
      expect(rects.first.left, lessThan(0.16));
      expect(rects.first.right, greaterThan(0.69));
      expect(rects.first.bottom - rects.first.top, greaterThanOrEqualTo(0.02));
    });

    test('AnnotationHistoryStack supports undo and redo and clears redo on new edit', () {
      final history = AnnotationHistoryStack();
      final ann1 = PdfAnnotation(
        id: 'a1',
        itemId: 'doc-1',
        pageNumber: 1,
        rects: const [
          NormalizedRect(left: 0.1, top: 0.1, right: 0.4, bottom: 0.12),
        ],
        selectedText: 'Uno',
        colorHex: '#4EDEA3',
        createdAt: DateTime(2026),
      );
      final ann2 = PdfAnnotation(
        id: 'a2',
        itemId: 'doc-1',
        pageNumber: 1,
        rects: const [
          NormalizedRect(left: 0.1, top: 0.2, right: 0.5, bottom: 0.22),
        ],
        selectedText: 'Dos',
        colorHex: '#FFD166',
        createdAt: DateTime(2026),
      );

      expect(history.canUndo, isFalse);
      history.recordAdd([ann1]);
      history.recordDelete([ann2]);
      expect(history.canUndo, isTrue);
      expect(history.undoCount, 2);

      final u1 = history.popUndo()!;
      expect(u1.kind, AnnotationActionKind.delete);
      expect(u1.annotations.single.id, 'a2');
      expect(history.canRedo, isTrue);

      final r1 = history.popRedo()!;
      expect(r1.kind, AnnotationActionKind.delete);
      expect(r1.annotations.single.id, 'a2');

      history.popUndo();
      history.recordAdd([ann2]); // should clear redo stack
      expect(history.canRedo, isFalse);
    });
  });

  group('Cloud Sync Schema, DTOs & 3-Warning Sign-Out', () {
    late Database db;
    late VaultRepository repo;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 2,
          onConfigure: (d) async => d.execute('PRAGMA foreign_keys = ON'),
          onCreate: (d, _) => DatabaseHelper.createSchema(d),
        ),
      );
      repo = VaultRepository(databaseProvider: () async => db);
    });

    tearDown(() async {
      await db.close();
    });

    test('tracks dirty state and cascade tombstones for offline cloud sync', () async {
      final now = DateTime.utc(2026, 5, 1, 10);
      await repo.insertItem(
        VaultItem(
          id: 'subj-cloud',
          parentId: null,
          title: 'Algoritmia',
          type: VaultItemType.folder,
          updatedAt: now,
        ),
      );
      await repo.insertItem(
        VaultItem(
          id: 'note-cloud',
          parentId: 'subj-cloud',
          title: 'Complejidad',
          type: VaultItemType.note,
          contentMd: 'O(n log n)',
          updatedAt: now,
        ),
      );
      await repo.addAnnotation(
        PdfAnnotation(
          id: 'ann-cloud',
          itemId: 'note-cloud',
          pageNumber: 1,
          rects: const [
            NormalizedRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.15),
          ],
          selectedText: 'MergeSort',
          colorHex: '#4EDEA3',
          createdAt: now,
        ),
      );

      expect(await repo.getPendingSyncCount(), 3);
      expect((await repo.getDirtyItems()).length, 2);
      expect((await repo.getDirtyAnnotations()).length, 1);

      await repo.markItemsSynced(['subj-cloud', 'note-cloud']);
      await repo.markAnnotationsSynced(['ann-cloud']);
      expect(await repo.getPendingSyncCount(), 0);

      // Deleting parent folder records cascade tombstones for folder, note & annotation
      await repo.deleteItem('subj-cloud', deleteStoredFiles: false);
      final tombstones = await repo.getTombstones();
      expect(tombstones.length, 3);
      expect(
        tombstones.where((t) => t.entityType == 'item').map((t) => t.id).toSet(),
        {'subj-cloud', 'note-cloud'},
      );
      expect(
        tombstones.where((t) => t.entityType == 'annotation').single.id,
        'ann-cloud',
      );

      for (final t in tombstones) {
        await repo.removeTombstone(t.id, t.entityType);
      }
      expect(await repo.getPendingSyncCount(), 0);
    });

    test('serializes CloudSession and Supabase item/annotation DTOs cleanly', () {
      final session = CloudSession(
        accessToken: 'jwt-abc',
        refreshToken: 'ref-xyz',
        userId: '11111111-1111-1111-1111-111111111111',
        email: 'alumno@uni.es',
        expiresAt: DateTime.utc(2026, 12, 1, 12),
      );
      final decodedSession = CloudSession.fromJson(session.toJson());
      expect(decodedSession.userId, session.userId);
      expect(decodedSession.email, 'alumno@uni.es');
      expect(decodedSession.accessToken, 'jwt-abc');

      final item = VaultItem(
        id: 'doc-1',
        parentId: 'subj-1',
        title: 'Libro Sistemas.pdf',
        type: VaultItemType.book,
        filePath: 'vault_files/doc1.pdf',
        fileSize: 2048,
        extractedText: 'Semaforos y mutex',
        isPinned: true,
        sortOrder: 2,
        updatedAt: DateTime.utc(2026, 6, 1, 8, 30),
      );
      final row = CloudVaultItemDto.toCloudMap(
        item,
        userId: session.userId,
        storageObjectPath: '${session.userId}/doc-1/doc1.pdf',
      );
      final dto = CloudVaultItemDto.fromCloudMap(row);
      expect(dto.item.id, 'doc-1');
      expect(dto.item.type, VaultItemType.book);
      expect(dto.item.isPinned, isTrue);
      expect(dto.storageObjectPath, '${session.userId}/doc-1/doc1.pdf');
      expect(dto.isDeleted, isFalse);

      final ann = PdfAnnotation(
        id: 'ann-1',
        itemId: 'doc-1',
        pageNumber: 4,
        rects: const [
          NormalizedRect(left: 0.2, top: 0.3, right: 0.7, bottom: 0.34),
        ],
        selectedText: 'Mutex',
        colorHex: '#7BD0FF',
        createdAt: DateTime.utc(2026, 6, 1, 9),
      );
      final annDto = CloudAnnotationDto.fromCloudMap(
        CloudAnnotationDto.toCloudMap(ann, userId: session.userId),
      );
      expect(annDto.annotation.id, 'ann-1');
      expect(annDto.annotation.pageNumber, 4);
      expect(annDto.annotation.selectedText, 'Mutex');
      expect(annDto.annotation.rects.single.right, closeTo(0.7, 0.0001));
    });

    testWidgets('confirmThreeStepSignOut requires all 3 consecutive confirmations', (tester) async {
      bool? lastResult;

      Future<void> triggerFlow(WidgetTester tester, {int pending = 0}) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      lastResult = await VaultDialogs.confirmThreeStepSignOut(
                        context,
                        pendingCount: pending,
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      }

      // Cancel at warning 1 of 3
      await triggerFlow(tester, pending: 2);
      expect(find.text('Advertencia 1 de 3: Cerrar sesión'), findsOneWidget);
      expect(find.textContaining('2 cambios offline pendientes'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(lastResult, isFalse);

      // Confirm 1, cancel at warning 2 of 3
      await triggerFlow(tester);
      await tester.tap(find.text('Continuar (1/3)'));
      await tester.pumpAndSettle();
      expect(find.text('Advertencia 2 de 3: Borrado local completo'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(lastResult, isFalse);

      // Confirm 1 & 2, cancel at warning 3 of 3
      await triggerFlow(tester);
      await tester.tap(find.text('Continuar (1/3)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sí, entiendo el borrado (2/3)'));
      await tester.pumpAndSettle();
      expect(find.text('Advertencia 3 de 3: Confirmación definitiva'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(lastResult, isFalse);

      // Confirm all 3 consecutive warnings -> returns true
      await triggerFlow(tester);
      await tester.tap(find.text('Continuar (1/3)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sí, entiendo el borrado (2/3)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('BORRAR TODO Y CERRAR SESIÓN'));
      await tester.pumpAndSettle();
      expect(lastResult, isTrue);
    });

    test('PkcePair computes RFC 7636 S256 challenge and builds Supabase GitHub OAuth URL', () {
      const rfcVerifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const expectedChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

      final fixed = PkcePair.fromVerifier(rfcVerifier);
      expect(fixed.codeChallenge, expectedChallenge);

      final generated = PkcePair.generate();
      expect(generated.codeVerifier.length, 64);
      expect(generated.codeChallenge.contains('='), isFalse);

      final client = SupabaseCloudClient(
        baseUrl: 'https://demo.supabase.co',
        publishableKey: 'pk_test',
      );
      final authUrl = client.buildOAuthAuthorizeUrl(
        provider: 'github',
        redirectTo: 'http://127.0.0.1:48912/callback',
        codeChallenge: fixed.codeChallenge,
      );
      expect(authUrl.scheme, 'https');
      expect(authUrl.host, 'demo.supabase.co');
      expect(authUrl.path, '/auth/v1/authorize');
      expect(authUrl.queryParameters['provider'], 'github');
      expect(
        authUrl.queryParameters['redirect_to'],
        'http://127.0.0.1:48912/callback',
      );
      expect(authUrl.queryParameters['code_challenge'], expectedChallenge);
      expect(authUrl.queryParameters['code_challenge_method'], 's256');
      expect(authUrl.queryParameters['scopes'], 'read:user user:email');

      expect(
        () => SupabaseCloudClient(
          baseUrl: 'http://insecure.example.com',
          publishableKey: 'pk_test',
        ),
        throwsArgumentError,
      );
    });

    testWidgets('VaultSettingsDialog displays GitHub OAuth button and Email fallback', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultItemsProvider.overrideWith(() => _FakeVaultItemsNotifier(const [])),
            examReadOnlyProvider.overrideWith(() => _FakeExamReadOnlyNotifier()),
            cloudSyncProvider.overrideWith(() => _FakeCloudSyncNotifier()),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () =>
                        VaultDialogs.showVaultSettingsDialog(context, ref),
                    child: const Text('Abrir Bóveda'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Bóveda'));
      await tester.pumpAndSettle();

      expect(find.text('Continuar con GitHub'), findsOneWidget);
      expect(find.text('Continuar con Google'), findsNothing);
      expect(find.text('O CON CORREO Y CONTRASEÑA (RESPALDO)'), findsOneWidget);
      expect(find.text('Entrar con correo y descargar'), findsOneWidget);
    });

    testWidgets(
        'VaultSettingsDialog enforces strong password on Sign Up but allows legacy Sign In',
        (tester) async {
      final fakeSync = _FakeCloudSyncNotifier();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultItemsProvider.overrideWith(() => _FakeVaultItemsNotifier(const [])),
            examReadOnlyProvider.overrideWith(() => _FakeExamReadOnlyNotifier()),
            cloudSyncProvider.overrideWith(() => fakeSync),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () =>
                        VaultDialogs.showVaultSettingsDialog(context, ref),
                    child: const Text('Abrir Bóveda'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Bóveda'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Crear cuenta'));
      await tester.tap(find.text('Crear cuenta'));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'student@uni.edu');
      await tester.enterText(fields.at(1), '123456');
      await tester.ensureVisible(find.text('Crear cuenta con correo'));
      await tester.tap(find.text('Crear cuenta con correo'));
      await tester.pumpAndSettle();

      expect(
        find.text('Usa al menos 8 caracteres combinando letras y números.'),
        findsOneWidget,
      );
      expect(fakeSync.signUpCalls, 0);

      await tester.enterText(fields.at(1), 'abcdefgh');
      await tester.tap(find.text('Crear cuenta con correo'));
      await tester.pumpAndSettle();
      expect(fakeSync.signUpCalls, 0);

      await tester.enterText(fields.at(1), 'Abcd1234');
      await tester.tap(find.text('Crear cuenta con correo'));
      await tester.pumpAndSettle();
      expect(fakeSync.signUpCalls, 1);

      await tester.ensureVisible(find.text('Iniciar sesión'));
      await tester.tap(find.text('Iniciar sesión'));
      await tester.pumpAndSettle();
      await tester.enterText(fields.at(1), '123456');
      await tester.ensureVisible(find.text('Entrar con correo y descargar'));
      await tester.tap(find.text('Entrar con correo y descargar'));
      await tester.pumpAndSettle();
      expect(fakeSync.signInCalls, 1);
    });
  });

  group('SecureSessionStore', () {
    test('stores session in FlutterSecureStorage and never keeps plaintext in SharedPreferences', () async {
      final session = CloudSession(
        accessToken: 'jwt-access-secret',
        refreshToken: 'refresh-secret',
        userId: 'user-123',
        email: 'user@example.com',
        expiresAt: DateTime.utc(2030, 1, 1),
      );

      final store = SecureSessionStore();
      await store.saveSession(session);
      await store.saveLastSync(DateTime.utc(2026, 11, 14, 5, 0));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SecureSessionStore.sessionKey), isNull);

      final rawSecure =
          await const FlutterSecureStorage().read(key: SecureSessionStore.sessionKey);
      expect(rawSecure, isNotNull);
      expect(rawSecure!.contains('jwt-access-secret'), isTrue);

      final loaded = await store.readSession();
      expect(loaded?.accessToken, 'jwt-access-secret');
      expect(loaded?.refreshToken, 'refresh-secret');
      expect(loaded?.userId, 'user-123');
      expect(await store.readLastSync(), isNotNull);

      await store.clearSession();
      expect(
        await const FlutterSecureStorage().read(key: SecureSessionStore.sessionKey),
        isNull,
      );
      expect(await store.readLastSync(), isNull);
    });

    test('migrates legacy SharedPreferences session into FlutterSecureStorage and deletes plaintext copy', () async {
      final legacySession = CloudSession(
        accessToken: 'legacy-jwt-token',
        refreshToken: 'legacy-refresh',
        userId: 'legacy-user',
        email: 'legacy@example.com',
        expiresAt: DateTime.utc(2030, 1, 1),
      );
      SharedPreferences.setMockInitialValues({
        SecureSessionStore.sessionKey: jsonEncode(legacySession.toJson()),
      });

      final store = SecureSessionStore();
      final migrated = await store.readSession();

      expect(migrated?.accessToken, 'legacy-jwt-token');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SecureSessionStore.sessionKey), isNull);

      final rawSecure =
          await const FlutterSecureStorage().read(key: SecureSessionStore.sessionKey);
      expect(rawSecure, isNotNull);
      expect(rawSecure!.contains('legacy-jwt-token'), isTrue);
    });
  });

  group('Enriched Markdown & TOC', () {
    test('parses Markdown tables, local images, and heading TOC summaries', () {
      const sample = '''
# Introducción

| Algoritmo | Tiempo | Memoria |
| --- | --- | --- |
| Quicksort | O(n log n) | O(log n) |
| Mergesort | O(n log n) | O(n) |

## Diagrama de árbol

![Arbol B](vault_files/arbol.png)

### Detalles finales

Ver [referencia oficial](https://example.com/docs).
''';

      final blocks = VaultMarkdownParser.parse(sample);
      expect(blocks.whereType<MdTableBlock>().length, 1);
      final table = blocks.whereType<MdTableBlock>().first;
      expect(table.headers, ['Algoritmo', 'Tiempo', 'Memoria']);
      expect(table.rows.length, 2);
      expect(table.rows[0], ['Quicksort', 'O(n log n)', 'O(log n)']);

      expect(blocks.whereType<MdImageBlock>().length, 1);
      final image = blocks.whereType<MdImageBlock>().first;
      expect(image.alt, 'Arbol B');
      expect(image.path, 'vault_files/arbol.png');

      final headings = VaultMarkdownParser.extractHeadings(sample);
      expect(headings.length, 3);
      expect(headings[0].level, 1);
      expect(headings[0].text, 'Introducción');
      expect(headings[1].level, 2);
      expect(headings[2].level, 3);
    });

    testWidgets('VaultMarkdownReader renders tables and inline links', (tester) async {
      const md = '''
| Tema | Estado |
| --- | --- |
| Tema 1 | Listo |

Consulta [guía local](https://vault.local/guia).
''';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(
              child: VaultMarkdownReader(contentMd: md),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tema'), findsOneWidget);
      expect(find.text('Quicksort'), findsNothing);
      expect(find.text('Tema 1'), findsOneWidget);
      expect(find.text('Listo'), findsOneWidget);
      expect(find.text('guía local'), findsOneWidget);
    });
  });

  group('Bulk Import & Workspace Navigation', () {
    test('VaultStorageService validates extensions and formats code/md/txt notes', () {
      expect(VaultStorageService.isSupportedImportFile('boletin.pdf'), isTrue);
      expect(VaultStorageService.isSupportedImportFile('tema1.md'), isTrue);
      expect(VaultStorageService.isSupportedImportFile('queries.sql'), isTrue);
      expect(VaultStorageService.isSupportedImportFile('virus.exe'), isFalse);

      final storage = VaultStorageService.instance;
      final mdResult = storage.formatImportedTextAsMarkdown(
        filePath: 'apuntes.md',
        rawText: '# Mi Apunte\nContenido.',
      );
      expect(mdResult, '# Mi Apunte\nContenido.');

      final sqlResult = storage.formatImportedTextAsMarkdown(
        filePath: 'join.sql',
        rawText: 'SELECT * FROM alumnos;',
      );
      expect(sqlResult.contains('```sql'), isTrue);
      expect(sqlResult.contains('file: join.sql'), isTrue);
      expect(sqlResult.contains('SELECT * FROM alumnos;'), isTrue);
    });

    test('WorkspaceNotifier supports toggleSidebar, closeActiveTab and reopenLastClosedTab', () async {
      final note = VaultItem(
        id: 'note-nav-1',
        parentId: null,
        title: 'Nota Test',
        type: VaultItemType.note,
        contentMd: '# Hola',
        updatedAt: DateTime(2026, 1, 1),
      );
      final container = ProviderContainer(
        overrides: [
          vaultItemsProvider.overrideWith(() => _FakeVaultItemsNotifier([note])),
        ],
      );
      addTearDown(container.dispose);

      await container.read(vaultItemsProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final notifier = container.read(workspaceProvider.notifier);

      expect(container.read(workspaceProvider).isSidebarVisible, isTrue);
      notifier.toggleSidebar();
      expect(container.read(workspaceProvider).isSidebarVisible, isFalse);

      final initialCount = container.read(workspaceProvider).tabs.length;

      notifier.openItem(note);
      expect(container.read(workspaceProvider).tabs.length, initialCount + 1);

      notifier.closeActiveTab();
      expect(container.read(workspaceProvider).tabs.length, initialCount);
      expect(
        container
            .read(workspaceProvider)
            .tabs
            .any((t) => t.itemId == 'note-nav-1'),
        isFalse,
      );

      notifier.reopenLastClosedTab();
      expect(container.read(workspaceProvider).tabs.length, initialCount + 1);
      expect(
        container
            .read(workspaceProvider)
            .tabs
            .any((t) => t.itemId == 'note-nav-1'),
        isTrue,
      );
    });
  });

  group('PHP / HTML Import, Web Preview & Code Execution', () {
    test('supports PHP, HTML, Kotlin and PowerShell import formatting', () {
      expect(VaultStorageService.isSupportedImportFile('index.php'), isTrue);
      expect(VaultStorageService.isSupportedImportFile('page.htm'), isTrue);
      expect(VaultStorageService.isSupportedImportFile('Main.kt'), isTrue);
      expect(VaultStorageService.isSupportedImportFile('script.ps1'), isTrue);

      final storage = VaultStorageService.instance;
      final phpMd = storage.formatImportedTextAsMarkdown(
        filePath: 'hola.php',
        rawText: '<?php echo "Hola"; ?>',
      );
      expect(phpMd.contains('```php'), isTrue);
      expect(phpMd.contains('// file: hola.php'), isTrue);

      final htmlMd = storage.formatImportedTextAsMarkdown(
        filePath: 'web.html',
        rawText: '<h1>Titulo</h1>',
      );
      expect(htmlMd.contains('```html'), isTrue);
      expect(htmlMd.contains('<h1>Titulo</h1>'), isTrue);
    });

    test('VaultCodeExecutionService prepares Java/PHP sources and detects HTML output', () async {
      final javaWithClass = VaultCodeExecutionService.prepareJavaSource(
        'public class Calculadora { public static void main(String[] a) {} }',
      );
      expect(javaWithClass.className, 'Calculadora');

      final bareJava = VaultCodeExecutionService.prepareJavaSource(
        'System.out.println(40 + 2);',
      );
      expect(bareJava.className, 'Main');
      expect(bareJava.source.contains('public class Main'), isTrue);

      expect(
        VaultCodeExecutionService.preparePhpSource('echo 1 + 1;').startsWith('<?php'),
        isTrue,
      );
      expect(VaultCodeExecutionService.looksLikeHtml('<h1>Hola</h1>'), isTrue);
      expect(VaultCodeExecutionService.looksLikeHtml('Resultado: 42'), isFalse);

      // Run Python snippet if python is installed on host; otherwise verify graceful missingRuntime
      final runner = VaultCodeExecutionService.instance;
      final pyRes = await runner.runSnippet(
        language: 'python',
        code: 'print(21 * 2)',
      );
      if (pyRes.missingRuntime) {
        expect(pyRes.errorMessage, isNotNull);
      } else {
        expect(pyRes.isSuccess, isTrue);
        expect(pyRes.stdout.trim(), '42');
      }
    });

    testWidgets('CodeBlockCard renders HTML Vista Web toggle and Ejecutar button for Java/PHP', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  CodeBlockCard(
                    language: 'html',
                    filePath: 'demo.html',
                    code: '<h1>Hola Web</h1><p>Contenido HTML offline</p>',
                  ),
                  SizedBox(height: 12),
                  CodeBlockCard(
                    language: 'php',
                    filePath: 'index.php',
                    code: '<?php echo "Hola PHP"; ?>',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Vista Web'), findsOneWidget);
      expect(find.text('Navegador'), findsOneWidget);
      expect(find.text('Ejecutar'), findsOneWidget);

      await tester.tap(find.text('Vista Web'));
      await tester.pumpAndSettle();
      expect(find.text('Código'), findsOneWidget);
    });
  });

  group('Mobile Readiness (360px Portrait & Deep Link OAuth)', () {
    test('defines vaultstudy://login-callback deep link redirect URL', () {
      expect(
        CloudSyncNotifier.mobileOAuthRedirectUrl,
        'vaultstudy://login-callback',
      );
    });

    testWidgets(
      'MobileShell renders subjects and loose root files on 360x780 phone without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final folder = VaultItem(
          id: 'subj-mob-1',
          parentId: null,
          title: 'Sistemas Operativos',
          type: VaultItemType.folder,
          updatedAt: DateTime(2026, 1, 1),
        );
        final rootNote = VaultItem(
          id: 'root-note-1',
          parentId: null,
          title: 'Resumen Rápido',
          type: VaultItemType.note,
          contentMd: '# Hola móvil',
          updatedAt: DateTime(2026, 1, 1),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              vaultItemsProvider.overrideWith(
                () => _FakeVaultItemsNotifier([folder, rootNote]),
              ),
              examReadOnlyProvider.overrideWith(
                () => _FakeExamReadOnlyNotifier(),
              ),
              cloudSyncProvider.overrideWith(() => _FakeCloudSyncNotifier()),
            ],
            child: const VaultStudyApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Mis Apuntes'), findsOneWidget);
        expect(find.text('Sistemas Operativos'), findsOneWidget);
        expect(find.text('ARCHIVOS EN RAÍZ (1)'), findsOneWidget);
        expect(find.text('Resumen Rápido'), findsOneWidget);
      },
    );

    testWidgets(
      'CodeBlockCard wraps HTML/PHP header actions cleanly at 360px phone width',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: CodeBlockCard(
                  language: 'html',
                  filePath: 'muy/largo/directorio/ejemplo_largo_movil.html',
                  code: '<h1>Vista Móvil</h1>',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Vista Web'), findsOneWidget);
        expect(find.text('Navegador'), findsOneWidget);
        expect(find.text('Copiar código'), findsOneWidget);
      },
    );
  });

  group('Startup Performance Optimizations', () {
    test(
      'getAllItems(includeExtractedText: false) omits bulky extractedText while preserving metadata',
      () async {
        DatabaseHelper.ensureFfiInitialized();
        final db = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 2,
            onConfigure: (db) async =>
                db.execute('PRAGMA foreign_keys = ON'),
            onCreate: (db, _) async => DatabaseHelper.createSchema(db),
          ),
        );
        final repo = VaultRepository(databaseProvider: () async => db);

        final pdf = VaultItem(
          id: 'perf-pdf-1',
          parentId: null,
          title: 'Manual Extenso.pdf',
          type: VaultItemType.pdf,
          filePath: 'vault_files/manual.pdf',
          fileSize: 4096,
          extractedText: 'Contenido muy extenso de muchas páginas para búsqueda',
          isPinned: true,
          sortOrder: 0,
          updatedAt: DateTime(2026, 2, 1),
        );
        await repo.insertItem(pdf);

        final lightList = await repo.getAllItems(includeExtractedText: false);
        expect(lightList, hasLength(1));
        expect(lightList.first.title, 'Manual Extenso.pdf');
        expect(lightList.first.filePath, 'vault_files/manual.pdf');
        expect(lightList.first.isPinned, isTrue);
        expect(lightList.first.extractedText, isEmpty);

        final fullList = await repo.getAllItems(includeExtractedText: true);
        expect(
          fullList.first.extractedText,
          'Contenido muy extenso de muchas páginas para búsqueda',
        );

        await db.close();
      },
    );
  });

  group('PDF Zoom & Selection Copy Helpers', () {
    test('parsePdfZoomPercent parses numeric/percent inputs and clamps bounds', () {
      expect(parsePdfZoomPercent('120'), closeTo(1.20, 0.0001));
      expect(parsePdfZoomPercent('185%'), closeTo(1.85, 0.0001));
      expect(parsePdfZoomPercent(' 85,5 % '), closeTo(0.855, 0.0001));
      expect(parsePdfZoomPercent('10'), closeTo(0.25, 0.0001));
      expect(parsePdfZoomPercent('900'), closeTo(5.0, 0.0001));
      expect(parsePdfZoomPercent(''), isNull);
      expect(parsePdfZoomPercent('abc'), isNull);
      expect(parsePdfZoomPercent('0'), isNull);
      expect(parsePdfZoomPercent('-50'), isNull);
    });

    test('parsePdfPageInput parses 1-based page numbers and clamps to totalPages', () {
      expect(parsePdfPageInput('15', totalPages: 42), 15);
      expect(parsePdfPageInput(' 1 ', totalPages: 42), 1);
      expect(parsePdfPageInput('999', totalPages: 42), 42);
      expect(parsePdfPageInput('0', totalPages: 42), isNull);
      expect(parsePdfPageInput('-3', totalPages: 42), isNull);
      expect(parsePdfPageInput('abc', totalPages: 42), isNull);
      expect(parsePdfPageInput('', totalPages: 42), isNull);
      expect(parsePdfPageInput('5', totalPages: 0), isNull);
    });

    test('findWordRangeAt & findLineRangeAt isolate clicked word and line cleanly', () {
      const sample = '1. Fundamentos de Algebra\nSELECT * FROM alumnos;';
      // Click inside "Fundamentos" (index 5)
      final wordRange = findWordRangeAt(sample, 5);
      expect(wordRange, isNotNull);
      expect(sample.substring(wordRange!.start, wordRange.end + 1), 'Fundamentos');

      // Click inside "Algebra" (index 20)
      final wordRange2 = findWordRangeAt(sample, 20);
      expect(wordRange2, isNotNull);
      expect(sample.substring(wordRange2!.start, wordRange2.end + 1), 'Algebra');

      // Triple click on first line -> full first line
      final lineRange = findLineRangeAt(sample, 5);
      expect(lineRange, isNotNull);
      expect(
        sample.substring(lineRange!.start, lineRange.end + 1),
        '1. Fundamentos de Algebra',
      );
    });

    test('findClosestCharIndex snaps cleanly from left/right margins and inter-line gaps', () {
      // Line 1 (y: 700..712), two chars: [100..110], [110..120]
      // Line 2 (y: 680..692), two chars: [100..110], [110..120]
      const rects = [
        PdfCharBounds(left: 100, top: 712, right: 110, bottom: 700), // 0: line 1 start
        PdfCharBounds(left: 110, top: 712, right: 120, bottom: 700), // 1: line 1 end
        PdfCharBounds(left: 100, top: 692, right: 110, bottom: 680), // 2: line 2 start
        PdfCharBounds(left: 110, top: 692, right: 120, bottom: 680), // 3: line 2 end
      ];

      // Direct hit inside char 1
      expect(findClosestCharIndex(rects, 115, 706), 1);
      // 30pt to the left of line 1 in the margin -> snaps to line 1 start (0)
      expect(findClosestCharIndex(rects, 70, 706), 0);
      // 30pt to the right of line 2 -> snaps to line 2 end (3)
      expect(findClosestCharIndex(rects, 150, 686), 3);
      // Unbounded drag far outside right margin on line 1 -> stays on line 1 end (1)
      expect(findClosestCharIndex(rects, 300, 705, maxMargin: double.infinity), 1);
      // Slightly above line 1 within margin -> snaps to line 1
      expect(findClosestCharIndex(rects, 105, 735, maxMargin: 44), 0);
      // Too far away -> null
      expect(findClosestCharIndex(rects, 300, 500, maxMargin: 44), isNull);
    });
  });
}

class _FakeVaultItemsNotifier extends VaultItemsNotifier {
  _FakeVaultItemsNotifier(this._items);
  final List<VaultItem> _items;

  @override
  Future<List<VaultItem>> build() async => _items;
}

class _FakeExamReadOnlyNotifier extends ExamReadOnlyNotifier {
  @override
  Future<bool> build() async => false;
}

class _FakeCloudSyncNotifier extends CloudSyncNotifier {
  int signUpCalls = 0;
  int signInCalls = 0;

  @override
  CloudSyncState build() => const CloudSyncState(hasInitialized: true);

  @override
  Future<bool> signUp({required String email, required String password}) async {
    signUpCalls++;
    return true;
  }

  @override
  Future<bool> signIn({required String email, required String password}) async {
    signInCalls++;
    return true;
  }
}
