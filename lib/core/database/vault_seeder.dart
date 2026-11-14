import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../features/vault_tree/domain/vault_item.dart';
import 'database_helper.dart';
import 'minimal_pdf_generator.dart';

/// Seeds the initial hierarchical vault when the `items` table is empty.
class VaultSeeder {
  VaultSeeder._();

  static const _uuid = Uuid();

  static Future<void> seedIfEmpty(Database db) async {
    final skip = await DatabaseHelper.instance.getSkipSeedAfterSignOut();
    if (skip) return;

    final countResult = await db.rawQuery('SELECT COUNT(*) as c FROM items');
    final count = (countResult.first['c'] as int?) ?? 0;
    if (count > 0) return;

    await seedForce(db);
  }

  static Future<void> seedForce(Database db) async {
    final filesDir = await DatabaseHelper.instance.getVaultFilesDir();
    final now = DateTime.utc(2025, 1, 1, 12);

    // Folders
    const dwId = 'subj-desarrollo-web';
    const dwT1Id = 'topic-dw-tema1';
    const dwT2Id = 'topic-dw-tema2';
    const iwId = 'subj-interfaces-web';
    const iwT1Id = 'topic-iw-tema1';

    final folders = [
      VaultItem(
        id: dwId,
        parentId: null,
        title: 'Desarrollo Web',
        type: VaultItemType.folder,
        sortOrder: 0,
        updatedAt: now.subtract(const Duration(hours: 6)),
      ),
      VaultItem(
        id: dwT1Id,
        parentId: dwId,
        title: 'Tema 1: Arquitectura y BD',
        type: VaultItemType.folder,
        sortOrder: 0,
        updatedAt: now.subtract(const Duration(hours: 2)),
      ),
      VaultItem(
        id: dwT2Id,
        parentId: dwId,
        title: 'Tema 2: Backend Node & APIs',
        type: VaultItemType.folder,
        sortOrder: 1,
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
      VaultItem(
        id: iwId,
        parentId: null,
        title: 'Interfaces Web',
        type: VaultItemType.folder,
        sortOrder: 1,
        updatedAt: now.subtract(const Duration(days: 2)),
      ),
      VaultItem(
        id: iwT1Id,
        parentId: iwId,
        title: 'Tema 1: Diseño y CSS',
        type: VaultItemType.folder,
        sortOrder: 0,
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
    ];

    for (final folder in folders) {
      await db.insert('items', folder.toMap());
    }

    // Generate real local PDF files for seeded documents so PDF viewer works 100% offline
    await _insertSeededPdf(
      db: db,
      filesDir: filesDir,
      id: 'doc-boletin-1',
      parentId: dwT1Id,
      title: 'Boletín 1.pdf',
      type: VaultItemType.pdf,
      isPinned: true,
      sortOrder: 0,
      updatedAt: now.subtract(const Duration(minutes: 45)),
      pages: _boletin1Pages,
    );

    await _insertSeededPdf(
      db: db,
      filesDir: filesDir,
      id: 'doc-boletin-2',
      parentId: dwT1Id,
      title: 'Boletín 2.pdf',
      type: VaultItemType.pdf,
      isPinned: false,
      sortOrder: 1,
      updatedAt: now.subtract(const Duration(hours: 5)),
      pages: _boletin2Pages,
    );

    await _insertSeededPdf(
      db: db,
      filesDir: filesDir,
      id: 'doc-libro-texto',
      parentId: dwT1Id,
      title: 'Libro de texto.pdf',
      type: VaultItemType.book,
      isPinned: false,
      sortOrder: 2,
      updatedAt: now.subtract(const Duration(days: 3)),
      pages: _libroTextoPages,
    );

    await _insertSeededPdf(
      db: db,
      filesDir: filesDir,
      id: 'doc-formulario-ux',
      parentId: iwT1Id,
      title: 'Formulario UX.pdf',
      type: VaultItemType.pdf,
      isPinned: true,
      sortOrder: 0,
      updatedAt: now.subtract(const Duration(hours: 12)),
      pages: _formularioUxPages,
    );

    // Seeded Notes
    final notes = [
      VaultItem(
        id: 'note-apuntes-sql',
        parentId: dwT1Id,
        title: 'Apuntes SQL y Consultas',
        type: VaultItemType.note,
        contentMd: _sqlNoteMd,
        isPinned: true,
        sortOrder: 3,
        updatedAt: now.subtract(const Duration(minutes: 15)),
      ),
      VaultItem(
        id: 'note-node-express',
        parentId: dwT2Id,
        title: 'Guía Express y Middlewares',
        type: VaultItemType.note,
        contentMd: _nodeNoteMd,
        isPinned: false,
        sortOrder: 0,
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
      VaultItem(
        id: 'note-css-grid',
        parentId: iwT1Id,
        title: 'Guía CSS Grid y Flexbox',
        type: VaultItemType.note,
        contentMd: _cssNoteMd,
        isPinned: false,
        sortOrder: 1,
        updatedAt: now.subtract(const Duration(days: 2)),
      ),
    ];

    for (final note in notes) {
      await db.insert('items', note.toMap());
    }

    // Seed one sample PDF highlight on Boletín 1 Page 3
    await db.insert('pdf_annotations', {
      'id': _uuid.v4(),
      'item_id': 'doc-boletin-1',
      'page_number': 3,
      'rects_json': '[{"l":0.09,"t":0.30,"r":0.88,"b":0.35}]',
      'selected_text':
          'GROUP BY con condicion HAVING count(*) > 2 garantizando WHERE previo',
      'color_hex': '#4EDEA3',
      'note': 'Clave para pregunta 3.1 del examen',
      'created_at': now.toIso8601String(),
    });
  }

  static Future<void> _insertSeededPdf({
    required Database db,
    required String filesDir,
    required String id,
    required String parentId,
    required String title,
    required VaultItemType type,
    required bool isPinned,
    required int sortOrder,
    required DateTime updatedAt,
    required List<List<String>> pages,
  }) async {
    final safeName = '${id}_${title.replaceAll(' ', '_')}';
    final fullPath = p.join(filesDir, safeName);
    final bytes = MinimalPdfGenerator.buildPdf(title: title, pagesLines: pages);
    await File(fullPath).writeAsBytes(bytes, flush: true);

    final relativePath = p.join(DatabaseHelper.vaultFilesFolderName, safeName);
    final fullExtracted = pages.map((lines) => lines.join(' ')).join('\n');

    final item = VaultItem(
      id: id,
      parentId: parentId,
      title: title,
      type: type,
      filePath: relativePath,
      fileSize: bytes.length,
      extractedText: fullExtracted,
      isPinned: isPinned,
      sortOrder: sortOrder,
      updatedAt: updatedAt,
    );

    await db.insert('items', item.toMap());
    final batch = db.batch();
    for (var i = 0; i < pages.length; i++) {
      batch.insert('pdf_pages', {
        'item_id': id,
        'page_number': i + 1,
        'content': pages[i].join('\n'),
      });
    }
    await batch.commit(noResult: true);
  }

  static final List<List<String>> _boletin1Pages = [
    [
      'UNIVERSIDAD POLITECNICA - INGENIERIA INFORMATICA',
      'GRADO EN INFORMATICA - DESARROLLO WEB - BOLETIN 1',
      '',
      '1. Fundamentos de Algebra Relacional',
      'Proyeccion, seleccion y producto cartesiano sobre esquemas normalizados.',
      'Revisa las dependencias funcionales antes de aplicar 3FN y BCNF.',
    ],
    [
      '2. Modelado Entidad-Relacion y Claves Foraneas',
      '',
      'Tablas involucradas:',
      ' - estudiantes(id_estudiante PK, nombre, email, fecha_alta)',
      ' - matriculas(id_matricula PK, id_estudiante FK, id_asig FK, semestre, estado)',
      ' - asignaturas(id_asig PK, creditos, nombre_asig, depto)',
    ],
    [
      'PREGUNTA 3.1 [VALOR: 2.5 PTOS]  ID: SQL-REL-2024-Q3',
      '',
      'Realizar una consulta analitica que devuelva todos los estudiantes',
      'matriculados en mas de dos asignaturas dentro del semestre lectivo',
      'SEMESTRE_B, asegurando que solo se contabilicen expedientes activos.',
      '',
      'Ejercicio 4: Desarrollar una sentencia con INNER JOIN multiple entre',
      'tablas clientes, pedidos y matriculas usando GROUP BY con HAVING count(*) > 2.',
      'Comprobar el plan de ejecucion para evitar Seq Scan en matriculas.',
    ],
    [
      '4. Transacciones ACID e Integridad Referencial',
      'Niveles de aislamiento: READ COMMITTED, REPEATABLE READ y SERIALIZABLE.',
      'Evitar lecturas sucias y fantasmas mediante bloqueos adecuados.',
    ],
  ];

  static final List<List<String>> _boletin2Pages = [
    [
      'BOLETIN 2 - EJERCICIOS RESUELTOS DE TRANSACCIONES Y TRIGGERS',
      '',
      'Ejercicio 1: Crear un indice B-Tree compuesto en matriculas(id_estudiante, estado).',
      'Ejercicio 2: Trigger BEFORE INSERT para validar creditos maximos por semestre.',
    ],
    [
      'Ejercicio 3: Subconsultas correlacionadas vs EXISTS',
      'Cuando solo importa comprobar existencia, EXISTS evita materializar filas extra.',
    ],
  ];

  static final List<List<String>> _libroTextoPages = List.generate(145, (index) {
    final page = index + 1;
    if (page == 142) {
      return [
        'CAPITULO 6: OPTIMIZACION DE CONSULTAS RELACIONALES',
        '',
        '6.4 Ordenacion de Reuniones (Join Reordering)',
        'El optimizador de consultas reordena las clausulas INNER JOIN para',
        'minimizar el producto cartesiano intermedio y aprovechar indices B-Tree.',
        'Cuando las estadisticas de cardinalidad estan actualizadas (ANALYZE),',
        'el planificador selecciona Hash Join o Merge Join segun memoria disponible.',
      ];
    }
    return [
      'LIBRO DE TEXTO: SISTEMAS DE BASES DE DATOS Y DESARROLLO WEB',
      'Seccion de referencia rapida - Pagina $page.',
      'Conceptos de arquitectura cliente-servidor, SQL estandar ANSI-92 e indices.',
    ];
  });

  static final List<List<String>> _formularioUxPages = [
    [
      'FORMULARIO UX - HEURISTICAS DE NIELSEN Y ACCESIBILIDAD WCAG',
      '1. Visibilidad del estado del sistema.',
      '2. Coincidencia entre el sistema y el mundo real.',
      '3. Control y libertad del usuario.',
      '4. Consistencia y estandares (contraste minimo AA 4.5:1).',
    ],
    [
      'Resumen de Flexbox y Grid para maquetacion responsive:',
      'Breakpoints recomendados: < 900px movil / >= 900px escritorio.',
    ],
  ];

  static const String _sqlNoteMd = '''
Para combinar tablas relacionadas garantizando la integridad de datos utilizamos `JOINS`. En exámenes prácticos recordar que el `INNER JOIN` excluye valores nulos y registros que no satisfacen la igualdad formal de claves foráneas.

Al calcular agregados agrupados por múltiples entidades (como estudiante y nombre), toda columna en el `SELECT` que no esté contenida dentro de una función de agregación (`COUNT`, `SUM`, `AVG`) debe declararse expresamente en el `GROUP BY`.

```sql
-- file: queries/relacionales.sql
SELECT e.id_estudiante, e.nombre, COUNT(m.id_asignatura) AS total_asignaturas
FROM estudiantes e
INNER JOIN matriculas m ON e.id_estudiante = m.id_estudiante
WHERE m.estado = 'ACTIVO'
GROUP BY e.id_estudiante, e.nombre
HAVING COUNT(m.id_asignatura) >= 2
ORDER BY total_asignaturas DESC;
```

> [!TIP]
> **TIP DE EXAMEN // SQL ENGINE:** Utilizar siempre alias claros (`e` para estudiantes, `m` para matriculas) para evitar ambigüedades en columnas compartidas. Si la prueba penaliza sintaxis implícita, evita comas en el `FROM`.

## Bitácora rápida de dudas (Local)
- [x] Revisar diferencia de costo computacional entre `LEFT JOIN` y `EXISTS`.
- [x] Comprobar índices B-Tree creados en la clave foránea `matriculas.id_estudiante`.
- [ ] Repasar el ejercicio 4 del Boletín 2 sobre transacciones ACID con nivel `SERIALIZABLE`.
''';

  static const String _nodeNoteMd = '''
## Middlewares y Rutas en Express

Cada middleware recibe `(req, res, next)` y debe invocar `next()` o cerrar la respuesta con `res.json(...)` / `res.status(...)`.

```javascript
// file: src/middlewares/auth.js
export function requireLocalToken(req, res, next) {
  const token = req.headers['x-exam-token'];
  if (!token) {
    return res.status(401).json({ error: 'Token requerido' });
  }
  next();
}
```

> [!TIP]
> **TIP DE EXAMEN // EXPRESS:** El middleware de manejo de errores lleva **4 parámetros** `(err, req, res, next)` y siempre se registra al final de las rutas.

- [ ] Repasar códigos HTTP idempotentes (`PUT` vs `PATCH` vs `POST`).
''';

  static const String _cssNoteMd = '''
## Patrón Adaptive Shell con CSS Grid

Para interfaces de estudio multi-panel, `grid-template-columns` con `minmax()` evita desbordamientos horizontales.

```css
/* file: styles/layout.css */
.vault-grid {
  display: grid;
  grid-template-columns: 260px minmax(0, 1fr);
  gap: 1rem;
}
```

- [x] Verificar contraste AA en modo oscuro (`#101419` sobre `#E0E2EA`).
- [ ] Revisar propiedades `align-items` vs `justify-content`.
''';
}
