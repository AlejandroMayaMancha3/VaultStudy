import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

class CodeExecutionResult {
  const CodeExecutionResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
    this.timedOut = false,
    this.missingRuntime = false,
    this.errorMessage,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final int durationMs;
  final bool timedOut;
  final bool missingRuntime;
  final String? errorMessage;

  bool get isSuccess =>
      !timedOut && !missingRuntime && errorMessage == null && exitCode == 0;

  bool get isHtmlOutput => VaultCodeExecutionService.looksLikeHtml(stdout);
}

/// Runs local code snippets (`java`, `php`, `python`, `javascript`, `dart`) in an
/// isolated temporary directory and serves HTML previews strictly on `127.0.0.1`.
class VaultCodeExecutionService {
  VaultCodeExecutionService._();

  static final VaultCodeExecutionService instance =
      VaultCodeExecutionService._();

  static const Duration defaultTimeout = Duration(seconds: 10);

  HttpServer? _activePreviewServer;
  Timer? _previewShutdownTimer;

  static const Set<String> _runnableLanguages = {
    'java',
    'php',
    'phtml',
    'python',
    'py',
    'javascript',
    'js',
    'dart',
  };

  static const Set<String> _webLanguages = {'html', 'htm'};

  static final RegExp _htmlTagRx = RegExp(
    r'<!doctype\s+html|<html\b|<body\b|<h[1-6]\b|<div\b|<p\b|<table\b|<ul\b|<ol\b|<form\b|<span\b|<strong\b|<a\s+href',
    caseSensitive: false,
  );

  static final RegExp _javaPublicClassRx = RegExp(
    r'\bpublic\s+class\s+([A-Za-z_][A-Za-z0-9_]*)',
  );

  static final RegExp _javaAnyClassRx = RegExp(
    r'\bclass\s+([A-Za-z_][A-Za-z0-9_]*)',
  );

  static bool get canExecuteOnCurrentPlatform =>
      !Platform.isAndroid && !Platform.isIOS;

  static bool isRunnableLanguage(String language) =>
      _runnableLanguages.contains(language.trim().toLowerCase());

  static bool isWebPreviewLanguage(String language) =>
      _webLanguages.contains(language.trim().toLowerCase());

  static bool looksLikeHtml(String output) => _htmlTagRx.hasMatch(output);

  /// Determines the Java target class name from source or file hint.
  static String resolveJavaClassName(String code, {String? filePathHint}) {
    final publicMatch = _javaPublicClassRx.firstMatch(code);
    if (publicMatch != null) return publicMatch.group(1)!;
    final anyMatch = _javaAnyClassRx.firstMatch(code);
    if (anyMatch != null) return anyMatch.group(1)!;
    if (filePathHint != null && filePathHint.trim().isNotEmpty) {
      final stem = p.basenameWithoutExtension(filePathHint.trim());
      if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(stem)) {
        return stem;
      }
    }
    return 'Main';
  }

  /// Prepares raw Java source, auto-wrapping bare statements if no class is declared.
  static ({String className, String source}) prepareJavaSource(
    String code, {
    String? filePathHint,
  }) {
    final trimmed = code.trim();
    if (_javaAnyClassRx.hasMatch(trimmed)) {
      final className = resolveJavaClassName(trimmed, filePathHint: filePathHint);
      return (className: className, source: code);
    }
    final wrapped = '''
public class Main {
  public static void main(String[] args) throws Exception {
$code
  }
}
''';
    return (className: 'Main', source: wrapped);
  }

  /// Prepares raw PHP source, ensuring an opening tag exists for bare snippets.
  static String preparePhpSource(String code) {
    final trimmed = code.trimLeft();
    if (trimmed.startsWith('<?php') || trimmed.startsWith('<?=')) {
      return code;
    }
    return '<?php\n$code\n';
  }

  /// Resolves an executable path from `PATH` or common desktop installation folders.
  Future<String?> findExecutable(String toolName) async {
    final exeName = Platform.isWindows ? '$toolName.exe' : toolName;
    final envPath = Platform.environment['PATH'] ?? '';
    for (final dir in envPath.split(Platform.isWindows ? ';' : ':')) {
      if (dir.trim().isEmpty) continue;
      final candidate = p.join(dir.trim(), exeName);
      if (await File(candidate).exists()) return candidate;
    }

    if (!Platform.isWindows) return null;

    final fallbacks = <String>[];
    if (toolName == 'java' || toolName == 'javac') {
      final javaHome = Platform.environment['JAVA_HOME'];
      if (javaHome != null && javaHome.isNotEmpty) {
        fallbacks.add(p.join(javaHome, 'bin', exeName));
      }
      for (final base in [
        r'C:\Program Files\Java',
        r'C:\Program Files\Eclipse Adoptium',
        r'C:\Program Files\Microsoft',
        r'C:\Program Files\Amazon Corretto',
      ]) {
        final dir = Directory(base);
        if (await dir.exists()) {
          await for (final sub in dir.list(followLinks: false)) {
            if (sub is Directory) {
              fallbacks.add(p.join(sub.path, 'bin', exeName));
            }
          }
        }
      }
    } else if (toolName == 'php') {
      fallbacks.addAll([
        r'C:\php\php.exe',
        r'C:\xampp\php\php.exe',
      ]);
      for (final base in [r'C:\laragon\bin\php', r'C:\tools']) {
        final dir = Directory(base);
        if (await dir.exists()) {
          await for (final sub in dir.list(followLinks: false)) {
            if (sub is Directory) {
              fallbacks.add(p.join(sub.path, 'php.exe'));
            }
          }
        }
      }
    } else if (toolName == 'node') {
      fallbacks.add(r'C:\Program Files\nodejs\node.exe');
    } else if (toolName == 'dart') {
      fallbacks.add(r'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe');
    }

    for (final candidate in fallbacks) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  /// Executes [code] in a sandboxed temporary folder with a strict timeout.
  Future<CodeExecutionResult> runSnippet({
    required String language,
    required String code,
    String? filePathHint,
    Duration timeout = defaultTimeout,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return const CodeExecutionResult(
        exitCode: -1,
        stdout: '',
        stderr: '',
        durationMs: 0,
        errorMessage:
            'La ejecución local de código solo está disponible en escritorio (Windows / Linux / macOS).',
      );
    }

    final norm = language.trim().toLowerCase();
    final sw = Stopwatch()..start();
    final tempDir = await Directory.systemTemp.createTemp('vaultstudy_run_');

    try {
      switch (norm) {
        case 'java':
          return await _runJava(
            tempDir: tempDir,
            code: code,
            filePathHint: filePathHint,
            sw: sw,
            timeout: timeout,
          );
        case 'php':
        case 'phtml':
          final phpExe = await findExecutable('php');
          if (phpExe == null) {
            return _missingBinaryResult(
              runtimeName: 'PHP',
              binaryName: 'php',
              hint:
                  'Instala PHP o XAMPP/Laragon (o añádelo al PATH) para ejecutar código PHP.',
              sw: sw,
            );
          }
          final script = File(p.join(tempDir.path, 'snippet.php'));
          await script.writeAsString(preparePhpSource(code), encoding: utf8);
          return await _execProcess(
            executable: phpExe,
            arguments: [script.path],
            workingDirectory: tempDir.path,
            timeout: timeout,
            sw: sw,
          );
        case 'python':
        case 'py':
          final pyExe = await findExecutable('python') ??
              await findExecutable('python3') ??
              await findExecutable('py');
          if (pyExe == null) {
            return _missingBinaryResult(
              runtimeName: 'Python',
              binaryName: 'python',
              hint: 'Instala Python 3 y añádelo al PATH para ejecutar scripts.',
              sw: sw,
            );
          }
          final script = File(p.join(tempDir.path, 'snippet.py'));
          await script.writeAsString(code, encoding: utf8);
          return await _execProcess(
            executable: pyExe,
            arguments: [script.path],
            workingDirectory: tempDir.path,
            timeout: timeout,
            sw: sw,
          );
        case 'javascript':
        case 'js':
          final nodeExe = await findExecutable('node');
          if (nodeExe == null) {
            return _missingBinaryResult(
              runtimeName: 'Node.js',
              binaryName: 'node',
              hint: 'Instala Node.js para ejecutar fragmentos JavaScript.',
              sw: sw,
            );
          }
          final script = File(p.join(tempDir.path, 'snippet.mjs'));
          await script.writeAsString(code, encoding: utf8);
          return await _execProcess(
            executable: nodeExe,
            arguments: [script.path],
            workingDirectory: tempDir.path,
            timeout: timeout,
            sw: sw,
          );
        case 'dart':
          final dartExe = await findExecutable('dart');
          if (dartExe == null) {
            return _missingBinaryResult(
              runtimeName: 'Dart SDK',
              binaryName: 'dart',
              hint: 'Instala Dart / Flutter SDK y añádelo al PATH.',
              sw: sw,
            );
          }
          final script = File(p.join(tempDir.path, 'snippet.dart'));
          await script.writeAsString(code, encoding: utf8);
          return await _execProcess(
            executable: dartExe,
            arguments: ['run', script.path],
            workingDirectory: tempDir.path,
            timeout: timeout,
            sw: sw,
          );
        default:
          return CodeExecutionResult(
            exitCode: -1,
            stdout: '',
            stderr: '',
            durationMs: sw.elapsedMilliseconds,
            errorMessage: 'El lenguaje "$language" no admite ejecución directa.',
          );
      }
    } finally {
      sw.stop();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<CodeExecutionResult> _runJava({
    required Directory tempDir,
    required String code,
    required String? filePathHint,
    required Stopwatch sw,
    required Duration timeout,
  }) async {
    final javacExe = await findExecutable('javac');
    final javaExe = await findExecutable('java');
    if (javacExe == null || javaExe == null) {
      return _missingBinaryResult(
        runtimeName: 'JDK (Java)',
        binaryName: 'javac / java',
        hint:
            'Instala un JDK (por ejemplo Adoptium Temurin) y configura JAVA_HOME o PATH para compilar y ejecutar Java.',
        sw: sw,
      );
    }

    final prepared = prepareJavaSource(code, filePathHint: filePathHint);
    final javaFile = File(p.join(tempDir.path, '${prepared.className}.java'));
    await javaFile.writeAsString(prepared.source, encoding: utf8);

    final compileRes = await _execProcess(
      executable: javacExe,
      arguments: ['-encoding', 'UTF-8', javaFile.path],
      workingDirectory: tempDir.path,
      timeout: timeout,
      sw: sw,
    );
    if (!compileRes.isSuccess) return compileRes;

    return _execProcess(
      executable: javaExe,
      arguments: ['-cp', tempDir.path, prepared.className],
      workingDirectory: tempDir.path,
      timeout: timeout,
      sw: sw,
    );
  }

  CodeExecutionResult _missingBinaryResult({
    required String runtimeName,
    required String binaryName,
    required String hint,
    required Stopwatch sw,
  }) {
    return CodeExecutionResult(
      exitCode: -1,
      stdout: '',
      stderr: '',
      durationMs: sw.elapsedMilliseconds,
      missingRuntime: true,
      errorMessage: 'No se encontró "$binaryName" ($runtimeName) en este equipo. $hint',
    );
  }

  Future<CodeExecutionResult> _execProcess({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Duration timeout,
    required Stopwatch sw,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuf.write)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuf.write)
        .asFuture<void>();

    try {
      final exitCode = await process.exitCode.timeout(timeout);
      await Future.wait([stdoutDone, stderrDone]);
      return CodeExecutionResult(
        exitCode: exitCode,
        stdout: stdoutBuf.toString().trimRight(),
        stderr: stderrBuf.toString().trimRight(),
        durationMs: sw.elapsedMilliseconds,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return CodeExecutionResult(
        exitCode: -1,
        stdout: stdoutBuf.toString().trimRight(),
        stderr: stderrBuf.toString().trimRight(),
        durationMs: sw.elapsedMilliseconds,
        timedOut: true,
        errorMessage:
            'Tiempo límite excedido (${timeout.inSeconds}s). Proceso detenido.',
      );
    }
  }

  /// Serves [html] strictly on `127.0.0.1` for safe local browser inspection.
  Future<Uri> openHtmlInLocalBrowser(String html) async {
    await stopPreviewServer();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _activePreviewServer = server;

    final documentHtml = looksLikeHtml(html)
        ? html
        : '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body><pre>${const HtmlEscape().convert(html)}</pre></body></html>';

    server.listen((req) async {
      req.response.headers.set('Content-Type', 'text/html; charset=utf-8');
      req.response.headers.set('X-Content-Type-Options', 'nosniff');
      req.response.write(documentHtml);
      await req.response.close();
    });

    _previewShutdownTimer = Timer(const Duration(minutes: 2), () {
      unawaited(stopPreviewServer());
    });

    final uri = Uri.parse('http://127.0.0.1:${server.port}/');
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      throw StateError('No se pudo abrir el navegador local en $uri');
    }
    return uri;
  }

  Future<void> stopPreviewServer() async {
    _previewShutdownTimer?.cancel();
    _previewShutdownTimer = null;
    final current = _activePreviewServer;
    _activePreviewServer = null;
    if (current != null) {
      await current.close(force: true);
    }
  }
}
