import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'app_logger.dart';

/// Construit l'environnement à passer aux sous-processus Python 3.12.
///
/// Priorité :
///   1. $SNAP/pyenv  — contexte snap (PYTHONPATH + LD_LIBRARY_PATH déjà définis)
///   2. <exe_dir>/pyenv — bundle extrait ou run hors-snap depuis le répertoire snap
///   3. Environnement hérité inchangé — Python système ou venv activé manuellement
Map<String, String> _buildPythonEnv() {
  final env = Map<String, String>.from(Platform.environment);
  if (env.containsKey('PYTHONPATH')) return env;

  final exeDir = p.dirname(Platform.resolvedExecutable);
  final localPyenv = p.join(exeDir, 'pyenv');
  if (!Directory(localPyenv).existsSync()) return env;

  env['PYTHONPATH'] = localPyenv;

  // Les wheels Python (paddle, numpy, opencv…) bundlent leurs libs C sans
  // RUNPATH — elles nécessitent que leurs répertoires *.libs soient dans
  // LD_LIBRARY_PATH pour que le dynamic linker les trouve au runtime.
  final wheelLibDirs = [
    p.join(localPyenv, 'numpy.libs'),
    p.join(localPyenv, 'opencv_python.libs'),
    p.join(localPyenv, 'ctranslate2.libs'),
    p.join(localPyenv, 'pillow.libs'),
    p.join(localPyenv, 'shapely.libs'),
  ].where((d) => Directory(d).existsSync()).join(':');

  if (wheelLibDirs.isNotEmpty) {
    final existing = env['LD_LIBRARY_PATH'] ?? '';
    env['LD_LIBRARY_PATH'] =
        existing.isEmpty ? wheelLibDirs : '$wheelLibDirs:$existing';
  }

  return env;
}

// ─── Fonctions top-level (isolate-safe) ───────────────────────────────────────

/// Corrige l'inclinaison de l'image (deskew 3 passes ±85°) dans un isolate.
/// Retourne les bytes PNG corrigés + métadonnées de transformation.
Map<String, dynamic> _deskewOnly(Uint8List srcBytes) {
  final logs = <String>[];
  final t0 = DateTime.now();
  int ms() => DateTime.now().difference(t0).inMilliseconds;

  final src = img.decodeImage(srcBytes);
  if (src == null) {
    return {
      'processedBytes': srcBytes,
      'skewAngle': 0.0,
      'origWidth': 0, 'origHeight': 0,
      'rotWidth': 0,  'rotHeight': 0,
      'elapsedMs': 0, 'logs': logs,
    };
  }

  final origW = src.width;
  final origH = src.height;
  logs.add('i:Deskew — image ${origW}×${origH} px');

  // Niveau de gris normalisé pour la détection d'angle (pas besoin de Sauvola)
  final gray = img.normalize(img.grayscale(src), min: 0, max: 255);
  final deskewData = _ppDeskew(gray, logs: logs);
  final angle = deskewData.angle;

  Uint8List resultBytes;
  int rotW, rotH;

  if (angle.abs() < 0.1) {
    resultBytes = srcBytes;
    rotW = origW;
    rotH = origH;
    logs.add('i:Deskew: inclinaison négligeable — image non modifiée');
  } else {
    // Rotation appliquée sur l'image originale (couleur ou NdG)
    src.backgroundColor = img.ColorRgb8(255, 255, 255);
    final rotated = img.copyRotate(src, angle: angle,
        interpolation: img.Interpolation.linear);
    src.backgroundColor = null;
    resultBytes = Uint8List.fromList(img.encodePng(rotated));
    rotW = rotated.width;
    rotH = rotated.height;
    logs.add('d:Deskew terminé — ${ms()} ms');
  }

  return {
    'processedBytes': resultBytes,
    'skewAngle': angle,
    'origWidth': origW, 'origHeight': origH,
    'rotWidth': rotW,   'rotHeight': rotH,
    'elapsedMs': ms(),  'logs': logs,
  };
}

// ─── Correction d'inclinaison (deskew) ────────────────────────────────────────
// Recherche en 3 passes pour couvrir ±85° sans exploser en temps de calcul :
//   1. ±85° step 5°  sur image 1/12  — repère le cadrant (ex : scan à 35°)
//   2. ±8°  step 0.3° sur image 1/6  — affine autour du meilleur candidat
//   3. ±0.5° step 0.05° sur image 1/6 — précision sub-degré finale
({img.Image image, double angle, int prepW, int prepH}) _ppDeskew(
    img.Image binary, {List<String>? logs}) {
  // Passe 1 — très grossière sur image 1/12 (rapide, tolérant les grands angles)
  const tinyDiv = 12;
  final tiny = img.copyResize(
    binary,
    width: max(1, binary.width ~/ tinyDiv),
    height: max(1, binary.height ~/ tinyDiv),
    interpolation: img.Interpolation.average,
  );
  tiny.backgroundColor = img.ColorRgb8(255, 255, 255);

  double bestAngle = 0.0;
  double bestScore = -1.0;
  for (double a = -85.0; a <= 85.0; a += 5.0) {
    final score = _ppProjectionVariance(img.copyRotate(tiny, angle: a));
    if (score > bestScore) { bestScore = score; bestAngle = a; }
  }

  // Passe 2 — intermédiaire sur image 1/6 (±8° autour du meilleur candidat)
  const sampleDiv = 6;
  final small = img.copyResize(
    binary,
    width: binary.width ~/ sampleDiv,
    height: binary.height ~/ sampleDiv,
    interpolation: img.Interpolation.average,
  );
  small.backgroundColor = img.ColorRgb8(255, 255, 255);

  double medScore = -1.0;
  double medAngle = bestAngle;
  for (double a = bestAngle - 8.0; a <= bestAngle + 8.0; a += 0.3) {
    final score = _ppProjectionVariance(img.copyRotate(small, angle: a));
    if (score > medScore) { medScore = score; medAngle = a; }
  }
  bestAngle = medAngle;
  bestScore = medScore;

  // Passe 3 — affinage fin (±0.5° step 0.05°)
  for (double a = bestAngle - 0.5; a <= bestAngle + 0.5; a += 0.05) {
    final score = _ppProjectionVariance(img.copyRotate(small, angle: a));
    if (score > bestScore) { bestScore = score; bestAngle = a; }
  }

  logs?.add('d:Deskew: angle optimal = ${bestAngle.toStringAsFixed(2)}° '
      '(variance=${bestScore.toStringAsFixed(0)})');
  if (bestAngle.abs() < 0.1) {
    logs?.add('i:Deskew: inclinaison négligeable (< 0.1°), pas de correction');
    return (image: binary, angle: 0.0, prepW: binary.width, prepH: binary.height);
  }

  binary.backgroundColor = img.ColorRgb8(255, 255, 255);
  final deskewed = img.copyRotate(binary, angle: bestAngle,
      interpolation: img.Interpolation.linear);
  binary.backgroundColor = null;

  logs?.add('i:Deskew: correction ${bestAngle > 0 ? "+" : ""}${bestAngle.toStringAsFixed(2)}° '
      '→ image ${deskewed.width}×${deskewed.height} px '
      '(était ${binary.width}×${binary.height})');
  return (image: deskewed, angle: bestAngle, prepW: deskewed.width, prepH: deskewed.height);
}

double _ppProjectionVariance(img.Image binary) {
  final w = binary.width;
  final h = binary.height;
  var sum = 0;
  var sumSq = 0;
  for (int y = 0; y < h; y++) {
    var row = 0;
    for (int x = 0; x < w; x++) {
      if (binary.getPixel(x, y).r.toInt() < 128) row++;
    }
    sum += row;
    sumSq += row * row;
  }
  final mean = sum / h;
  return sumSq / h - mean * mean;
}

// ─── OCRService ───────────────────────────────────────────────────────────────

class OCRService {
  final logger = AppLogger.build();

  static String? _fastTextModelPath;
  static String? _fastTextScriptPath;
  static String? _ocrScriptPath;

  // ─── Initialisation ────────────────────────────────────────────────────────

  /// Extrait le modèle FastText LID et le script de détection depuis les assets.
  static Future<void> initFastTextModel() async {
    try {
      final appDir = await getApplicationSupportDirectory();

      final modelFile = File(p.join(appDir.path, 'lid.176.ftz'));
      if (!await modelFile.exists()) {
        final data = await rootBundle.load('assets/models/lid.176.ftz');
        await modelFile.writeAsBytes(data.buffer.asUint8List());
      }
      _fastTextModelPath = modelFile.path;

      final scriptFile = File(p.join(appDir.path, 'fasttext_detect.py'));
      final src = await rootBundle.loadString('assets/scripts/fasttext_detect.py');
      await scriptFile.writeAsString(src);
      _fastTextScriptPath = scriptFile.path;
    } catch (e) {
      _fastTextModelPath = null;
      _fastTextScriptPath = null;
    }
  }

  /// Extrait le script Python PaddleOCR depuis les assets vers le répertoire de données.
  static Future<void> initPaddleOCR() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      // Supprimer l'ancien script paddleocr.py s'il existe : un fichier portant
      // ce nom dans le même répertoire ombre le vrai package paddleocr dans sys.path.
      final legacy = File(p.join(appDir.path, 'paddleocr.py'));
      if (await legacy.exists()) await legacy.delete();

      final scriptPath = p.join(appDir.path, 'paddle_runner.py');
      // Toujours réécrire pour refléter la version embarquée dans l'app
      final src = await rootBundle.loadString('assets/scripts/paddle_runner.py');
      await File(scriptPath).writeAsString(src);
      _ocrScriptPath = scriptPath;
    } catch (e) {
      _ocrScriptPath = null;
    }
  }

  // ─── API publique ──────────────────────────────────────────────────────────

  /// Extrait les blocs de texte d'une image de page PDF.
  /// Applique le deskew avant PaddleOCR, puis inverse la transformation
  /// pour que les bounding boxes soient dans l'espace de l'image originale.
  Future<List<OCRTextBlock>> extractTextBlocks(
    File imageFile, {
    String language = 'en',
    int dpi = 600,
    Future<void> Function(double fraction, String stepName)? onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final ownTempFiles = <String>[];

    try {
      await onProgress?.call(0.0, 'Correction d\'inclinaison…');

      final srcBytes = await imageFile.readAsBytes();
      final deskewResult = await compute(_deskewOnly, srcBytes);

      for (final msg in (deskewResult['logs'] as List).cast<String>()) {
        if (msg.startsWith('d:')) logger.d(msg.substring(2));
        else if (msg.startsWith('i:')) logger.i(msg.substring(2));
        else if (msg.startsWith('w:')) logger.w(msg.substring(2));
        else logger.i(msg);
      }

      final angle    = deskewResult['skewAngle'] as double;
      final origW    = deskewResult['origWidth']  as int;
      final origH    = deskewResult['origHeight'] as int;
      final rotW     = deskewResult['rotWidth']   as int;
      final rotH     = deskewResult['rotHeight']  as int;
      final elapsedMs = deskewResult['elapsedMs'] as int;
      logger.i('Deskew: ${elapsedMs} ms — angle=${angle.toStringAsFixed(2)}°');

      File ocrFile;
      if (angle.abs() >= 0.1) {
        final processedBytes = deskewResult['processedBytes'] as Uint8List;
        final outPath = p.join(tempDir.path, 'deskewed_${DateTime.now().millisecondsSinceEpoch}.png');
        await File(outPath).writeAsBytes(processedBytes);
        ownTempFiles.add(outPath);
        ocrFile = File(outPath);
      } else {
        ocrFile = imageFile;
      }

      // Mode debug : copie de l'image prétraitée
      final debugDir = AppLogger.debugDir;
      if (debugDir != null) {
        final m = RegExp(r'page_(\d+)_').firstMatch(p.basename(imageFile.path));
        final name = 'prep_page_${m?.group(1) ?? DateTime.now().millisecondsSinceEpoch}.png';
        try { await File(ocrFile.path).copy(p.join(debugDir, name)); } catch (_) {}
      }

      await onProgress?.call(0.15, 'OCR (PaddleOCR)…');
      final raw = await _callPaddleOCR(ocrFile, language);
      logger.i('PaddleOCR: ${raw.length} bloc(s) extraits (lang=$language)');

      // Filtre texte garbage
      final filtered = raw.where((b) => !_isGarbageText(b.text)).toList();
      logger.i('Filtrage garbage: ${raw.length} → ${filtered.length} blocs valides');

      // Inverse-rotation des bounding boxes si l'image a été pivotée
      final blocks = (angle.abs() >= 0.1)
          ? filtered.map((b) => OCRTextBlock(
                text: b.text,
                boundingBox: _inverseRotateRect(b.boundingBox, angle, origW, origH, rotW, rotH),
              )).toList()
          : filtered;

      await onProgress?.call(1.0, 'Extraction terminée');
      return blocks;
    } finally {
      for (final path in ownTempFiles) {
        try { await File(path).delete(); } catch (_) {}
      }
    }
  }

  /// Détecte la langue dominante d'une page via PaddleOCR + FastText.
  Future<String> detectPageLanguage(File imageFile, {int dpi = 150}) async {
    try {
      // Copie l'image de détection dans le répertoire debug si activé
      final debugDir = AppLogger.debugDir;
      if (debugDir != null) {
        final m = RegExp(r'thumb_(\d+)_').firstMatch(p.basename(imageFile.path));
        final name = 'detect_page_${m?.group(1) ?? DateTime.now().millisecondsSinceEpoch}.png';
        try { await imageFile.copy(p.join(debugDir, name)); } catch (_) {}
        logger.d('Détection lang — image copiée : $name');
      }

      final (text, script) = await _callPaddleDetect(imageFile);
      logger.d('Détection lang — script=$script, ${text.length} car. extraits'
          '${text.isNotEmpty ? " : « ${text.substring(0, text.length.clamp(0, 60))}… »" : ""}');

      // Scripts non-latins : la détection Unicode est fiable, pas besoin de FastText
      switch (script) {
        case 'japanese':
          logger.i('Détection lang → ja (hiragana/katakana)');
          return 'ja';
        case 'cjk':
          logger.i('Détection lang → zh (CJK)');
          return 'zh';
        case 'korean':
          logger.i('Détection lang → ko (hangul)');
          return 'ko';
        case 'arabic':
          logger.i('Détection lang → ar (arabe)');
          return 'ar';
        case 'cyrillic':
          logger.i('Détection lang → ru (cyrillique)');
          return 'ru';
        case 'devanagari':
          logger.i('Détection lang → hi (devanagari)');
          return 'hi';
        case 'thai':
          logger.i('Détection lang → th (thaï)');
          return 'th';
      }

      // Script latin → FastText pour distinguer fr/de/es/nl/pl/en…
      if (text.trim().length < 20) {
        logger.i('Détection lang → en (texte insuffisant : ${text.trim().length} car.)');
        return 'en';
      }
      final lang = await _classifyWithFastText(text);
      logger.i('Détection lang → $lang (FastText, script latin)');
      return lang;
    } catch (e) {
      logger.w('Détection langue échouée: $e');
      return 'en';
    }
  }

  // ─── Subprocesses PaddleOCR ────────────────────────────────────────────────

  Future<List<OCRTextBlock>> _callPaddleOCR(File imageFile, String language) async {
    if (_ocrScriptPath == null) throw Exception('Script PaddleOCR non initialisé.');

    final process = await Process.start(
      'python3.12', [_ocrScriptPath!, 'ocr', imageFile.path, language],
      environment: _buildPythonEnv(),
    );

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    process.stderr.transform(utf8.decoder).forEach((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.trim().isNotEmpty) logger.w('paddleocr ocr: $line');
      }
    });

    final output = await stdoutFuture;
    final exitCode = await process.exitCode;
    if (exitCode != 0) throw Exception('paddle_runner.py ocr: exit $exitCode');

    final decoded = json.decode(output) as List;
    return decoded.map((b) {
      final m = b as Map<String, dynamic>;
      return OCRTextBlock(
        text: m['text'] as String,
        boundingBox: Rect.fromLTRB(
          (m['left'] as num).toDouble(),
          (m['top'] as num).toDouble(),
          (m['right'] as num).toDouble(),
          (m['bottom'] as num).toDouble(),
        ),
      );
    }).toList();
  }

  Future<(String text, String script)> _callPaddleDetect(File imageFile) async {
    if (_ocrScriptPath == null) throw Exception('Script PaddleOCR non initialisé.');

    final process = await Process.start(
      'python3.12', [_ocrScriptPath!, 'detect', imageFile.path],
      environment: _buildPythonEnv(),
    );

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    process.stderr.transform(utf8.decoder).forEach((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.trim().isNotEmpty) logger.d('paddleocr detect: $line');
      }
    });

    final output = await stdoutFuture;
    await process.exitCode;

    final data = json.decode(output) as Map<String, dynamic>;
    return (
      (data['text'] as String?) ?? '',
      (data['script'] as String?) ?? 'latin',
    );
  }

  // ─── Transformation inverse (deskew) ──────────────────────────────────────

  /// Transforme un Rect du repère image pivotée vers le repère image originale.
  Rect _inverseRotateRect(
      Rect rect, double angleDeg, int origW, int origH, int rotW, int rotH) {
    final corners = [
      Offset(rect.left,  rect.top),
      Offset(rect.right, rect.top),
      Offset(rect.right, rect.bottom),
      Offset(rect.left,  rect.bottom),
    ];
    final pts = corners
        .map((c) => _inverseRotatePoint(c, angleDeg, origW, origH, rotW, rotH))
        .toList();
    return Rect.fromLTRB(
      pts.map((o) => o.dx).reduce(min),
      pts.map((o) => o.dy).reduce(min),
      pts.map((o) => o.dx).reduce(max),
      pts.map((o) => o.dy).reduce(max),
    );
  }

  /// Rotation inverse d'un point : repère pivotée → repère original.
  /// La rotation CW de θ appliquée à l'image s'inverse par rotation CCW de θ.
  Offset _inverseRotatePoint(
      Offset p, double angleDeg, int origW, int origH, int rotW, int rotH) {
    final theta = angleDeg * pi / 180.0;
    final cosT  = cos(theta);
    final sinT  = sin(theta);
    final dx = p.dx - rotW / 2.0;
    final dy = p.dy - rotH / 2.0;
    return Offset(
      cosT * dx - sinT * dy + origW / 2.0,
      sinT * dx + cosT * dy + origH / 2.0,
    );
  }

  // ─── FastText ─────────────────────────────────────────────────────────────

  Future<String> _classifyWithFastText(String text) async {
    final input = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final snippet = input.length > 1000 ? input.substring(0, 1000) : input;
    if (snippet.isEmpty) return 'en';

    final process = await Process.start(
      'python3.12', [_fastTextScriptPath!, _fastTextModelPath!],
      environment: _buildPythonEnv(),
    );
    process.stdin.writeln(snippet);
    await process.stdin.close();

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    process.stderr.drain<List<int>>();
    final raw = await stdoutFuture;
    await process.exitCode;

    final label = raw.trim().split('\n').first.trim();
    if (!label.startsWith('__label__')) {
      logger.w('FastText: sortie inattendue "$label"');
      return 'en';
    }
    final code = label.substring('__label__'.length).trim();
    final mapped = _mapFastTextCode(code);
    logger.d('FastText: $code → $mapped');
    return mapped;
  }

  String _mapFastTextCode(String code) {
    const supported = {
      'en', 'fr', 'de', 'es', 'it', 'pt', 'nl', 'pl', 'vi',
      'ja', 'zh', 'ko', 'ru', 'ar', 'hi', 'th',
    };
    if (supported.contains(code)) return code;
    switch (code) {
      case 'zh_TW': case 'zh_Hant': case 'zht': return 'zh';
      case 'pt_BR': case 'pt_PT': return 'pt';
      default: return 'en';
    }
  }

  // ─── Filtre texte garbage ──────────────────────────────────────────────────

  bool _isGarbageText(String text) {
    final stripped = text.trim();
    if (stripped.isEmpty) return true;

    final nonSpace = stripped.replaceAll(' ', '');
    if (nonSpace.isEmpty) return true;

    int meaningful = 0;
    final charFreq = <String, int>{};
    for (final rune in stripped.runes) {
      final c = String.fromCharCode(rune);
      if (c == ' ') continue;
      charFreq[c] = (charFreq[c] ?? 0) + 1;
      if ((rune >= 0x41   && rune <= 0x5A)   ||
          (rune >= 0x61   && rune <= 0x7A)   ||
          (rune >= 0x30   && rune <= 0x39)   ||
          (rune >= 0x3040 && rune <= 0x309F) ||
          (rune >= 0x30A0 && rune <= 0x30FF) ||
          (rune >= 0xFF65 && rune <= 0xFF9F) ||
          (rune >= 0x4E00 && rune <= 0x9FFF)) {
        meaningful++;
      }
    }

    if (meaningful < 3) return true;
    if ((nonSpace.length - meaningful) / nonSpace.length > 0.4) return true;

    for (final entry in charFreq.entries) {
      if (entry.key != '.' && entry.value > 4 && entry.value / nonSpace.length > 0.5) {
        return true;
      }
    }

    final words = stripped.split(RegExp(r'\s+'));
    if (words.length >= 3) {
      final singleChar = words.where((w) => w.length == 1).length;
      if (singleChar / words.length > 0.6) return true;
    }

    return false;
  }
}

// ─── Modèle de données ────────────────────────────────────────────────────────

class OCRTextBlock {
  final String text;
  final Rect boundingBox;

  OCRTextBlock({required this.text, required this.boundingBox});
}
