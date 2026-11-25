# VaultStudy

**VaultStudy** es una aplicación multiplataforma (*Windows* y *Android*) diseñada como una **bóveda de estudio jerárquica *offline-first*** para organizar asignaturas, PDFs, libros y apuntes en Markdown con bloques de código ejecutables y sincronización opcional en la nube.

---

## Descarga rápida de la APK (Android)

> **Descarga directa desde el móvil (1 clic):**  
> [**Descargar VaultStudy v1.0.4 (`app-release.apk`)**](https://github.com/AlejandroMayaMancha3/VaultStudy/releases/latest/download/app-release.apk)

Si estás leyendo esto desde el ordenador, escanea este código QR con la cámara de tu móvil para descargar el APK directamente:

<p align="center">
  <a href="https://github.com/AlejandroMayaMancha3/VaultStudy/releases/latest/download/app-release.apk">
    <img src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=https://github.com/AlejandroMayaMancha3/VaultStudy/releases/latest/download/app-release.apk" alt="QR descarga rápida APK VaultStudy" width="200" height="200" />
  </a>
</p>

### Cómo instalarla en Android
1. Pulsa en el enlace directo de arriba (o ve a [**Releases**](https://github.com/AlejandroMayaMancha3/VaultStudy/releases/latest) y descarga `app-release.apk`).
2. Abre el archivo descargado desde tus notificaciones o tu gestor de archivos.
3. Si Android lo solicita la primera vez, habilita **"Instalar aplicaciones desconocidas"** para tu navegador o gestor de archivos.

### Descarga rápida para Windows (`.exe` portable)
* [**Descargar VaultStudy v1.0.4 para Windows (`VaultStudy-Windows-x64.zip`)**](https://github.com/AlejandroMayaMancha3/VaultStudy/releases/latest/download/VaultStudy-Windows-x64.zip) — descomprime la carpeta y ejecuta `vaultstudy.exe`.

> **A partir de `v1.0.4`:** VaultStudy incluye comprobación y descarga automática de futuras actualizaciones desde GitHub Releases (en Windows se actualiza y reinicia sola; en Android descarga el APK y abre el instalador).

---

## Cómo funciona la aplicación

### 1. Bóveda local jerárquica (*Offline-First*)
* Todos tus apuntes, carpetas, libros y PDFs se guardan localmente en **SQLite** (con almacenamiento local de archivos), de modo que la aplicación funciona sin conexión a internet.
* Estructura en árbol con **carpetas anidadas**, **elementos fijados** (*Fijados* / carrusel rápido en móvil), **archivos en raíz**, **seguro anti-movimientos** (candado activo por defecto para evitar mover archivos sin querer al hacer clic) con botón **Deshacer** tras reorganizar, y acciones rápidas para crear, renombrar, mover o eliminar de forma recursiva.
* Exportación e importación de copias portátiles en formato `.vaultpkg` (archivo comprimido con estructura y adjuntos).

### 2. Carga masiva y organización rápida
* **Importación múltiple de archivos** (`.pdf`, `.md` y archivos de código fuente) y **importación de carpetas completas** respetando su jerarquía original.
* En **escritorio (Windows)** permite **arrastrar y soltar (*Drag & Drop*)** archivos directamente sobre la aplicación.
* En **móvil (Android)** todas las acciones de creación e importación están accesibles desde el botón flotante `+` y los menús contextuales de cada carpeta o archivo.

### 3. Editor Markdown, lector PDF y bloques de código
* **Lector y editor Markdown:** vista dual/dividida en escritorio y pantalla de lectura/edición optimizada para móvil con resaltado de sintaxis, selección continua por arrastre o doble clic entre bloques y botón rápido **Copiar selección**.
* **Lector PDF integrado (`pdfrx`):**
  * Selección fluida de texto por arrastre (tolerante en márgenes), doble clic (palabra), triple clic (línea) y copia inmediata (`Ctrl+C`, barra flotante o menú contextual).
  * Zoom numérico editable (`25%`–`500%`), ajustes rápidos (`1:1`, *Ajustar al ancho*, *Página completa*), rotación y salto directo a página (`Ctrl+G`).
  * Desplazamiento adaptado a portátil con **touchpad de 2 dedos**, barra de scroll derecha con página actual y **clic izquierdo mantenido fuera del documento** para arrastrar y hacer scroll cómodamente.
  * **Índice plegable por niveles** (`1, 2, 3…` en temas principales, `a, b, c…` en subapartados y `i, ii, iii…` / `◦` en niveles profundos) con botón **Expandir todo / Contraer todo**, además de marcadores por página y subrayado persistente.
* **Vista web y ejecución de código:**
  * Los bloques **HTML** (`html`, `htm`) cuentan con **Vista Web** integrada y apertura en navegador local (`127.0.0.1`).
  * En **escritorio**, `VaultCodeExecutionService` permite ejecutar fragmentos en **Java**, **PHP**, **Python**, **JavaScript** y **Dart** en un directorio temporal aislado (en Android/iOS el botón `Ejecutar` se oculta automáticamente y se mantiene la vista web/código).

### 4. Búsqueda global
* Buscador unificado para localizar al instante cualquier carpeta, apunte Markdown o PDF buscando tanto por título como por contenido y texto extraído de documentos.

### 5. Sincronización en la nube y seguridad
* **Almacenamiento seguro de sesión:** los tokens de sesión se guardan cifrados mediante `flutter_secure_storage` (DPAPI en Windows, Android Keystore en móvil, Keychain en Apple y `libsecret` en Linux), sin guardar credenciales en texto plano ni exponer secretos en logs.
* **Autenticación con Supabase:** acceso mediante correo/contraseña o **GitHub OAuth con PKCE** (`RFC 7636`):
  * En escritorio usa un servidor loopback temporal en `127.0.0.1`.
  * En móvil usa *deep linking* (`vaultstudy://login-callback` con `app_links`).
* **Aislamiento por usuario:** la sincronización de metadatos (Postgres) y archivos (Supabase Storage privado) se protege mediante políticas **RLS** por usuario autenticado.

### 6. Auto-actualización desde GitHub Releases
* Al abrirse con conexión, la app comprueba silenciosamente si existe una versión más reciente en GitHub Releases (`offline-safe` cuando no hay WiFi) y muestra un aviso discreto o la opción manual desde **Ajustes**.
* **Windows:** descarga `VaultStudy-Windows-x64.zip`, verifica su contenido, sustituye los binarios manteniendo tus datos en `AppData` y reinicia `vaultstudy.exe` automáticamente.
* **Android:** descarga `app-release.apk` dentro de la app con barra de progreso y abre el instalador nativo del sistema mediante `FileProvider` para confirmar en 1 toque.

---

## Arquitectura adaptativa

VaultStudy cambia automáticamente su interfaz según el tamaño de pantalla (`lib/app.dart`):
* **Escritorio (`DesktopShell`)**: barra lateral en árbol, pestañas múltiples, visor dividido y soporte *Drag & Drop*.
* **Móvil (`MobileShell`)**: navegación inferior por pestañas, carrusel de fijados, carpetas desplegables, sección de archivos en raíz y lector dedicado (`MobileReaderScreen`).
