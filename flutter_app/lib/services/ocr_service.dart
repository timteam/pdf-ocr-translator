import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'app_logger.dart';

/// Lance un tick loop en parallèle d'une opération async longue.
/// Avance la fraction de [start] vers [end] avec une courbe ease-out,
/// sans jamais dépasser [end]. S'arrête dès que [work] se termine.
/// Fonctionne uniquement pour les opérations genuinement async (Process.run).
Future<T> _withSimulatedProgress<T>(
  Future<T> work, {
  required Future<void> Function(double, String)? onProgress,
  required double start,
  required double end,
  required String label,
  required int expectedMs,
}) async {
  if (onProgress == null) return work;
  var active = true;
  final began = DateTime.now();

  Future<void> tick() async {
    while (active) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (!active) break;
      final ms = DateTime.now().difference(began).inMilliseconds;
      // ease-out : rapide au début, ralentit en approchant du seuil haut
      final t = (1.0 - exp(-ms / expectedMs * 2.0)).clamp(0.0, 0.99);
      await onProgress(start + (end - start) * t, label);
    }
  }

  // ignore: unawaited_futures
  tick();
  try {
    return await work;
  } finally {
    active = false;
  }
}

class OCRService {
  final logger = AppLogger.build();

  // Cached path to project-local tessdata_best directory (next to the binary).
  // Empty string means "not found / use system tessdata".
  static String? _localTessdata;

  Future<Map<String, String>?> _tessdataEnv() async {
    // Snap : TESSDATA_PREFIX déjà défini dans l'environnement → modèles bundlés.
    if (Platform.environment.containsKey('TESSDATA_PREFIX')) {
      logger.i('TESSDATA_PREFIX (snap): ${Platform.environment['TESSDATA_PREFIX']}');
      return null;
    }
    if (_localTessdata == null) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final candidate = p.join(exeDir, 'tessdata');
      _localTessdata = await Directory(candidate).exists() ? candidate : '';
    }
    if (_localTessdata!.isEmpty) {
      throw Exception(
        'Modèles Tesseract introuvables.\n'
        'Lancez ./scripts/setup_tessdata_best.sh puis rebuilder l\'application.',
      );
    }
    logger.i('TESSDATA_PREFIX (bundle): $_localTessdata');
    return {'TESSDATA_PREFIX': _localTessdata!};
  }

  static const Map<String, String> _langMap = {
    'en': 'eng', 'fr': 'fra', 'es': 'spa', 'de': 'deu',
    'it': 'ita', 'pt': 'por', 'nl': 'nld', 'pl': 'pol',
    'ru': 'rus', 'ja': 'jpn+jpn_vert', 'zh': 'chi_sim', 'ko': 'kor',
    'ar': 'ara', 'hi': 'hin', 'th': 'tha', 'vi': 'vie',
  };

  String _toTesseractLang(String bcp47) => _langMap[bcp47] ?? 'eng';

  Future<List<OCRTextBlock>> extractTextBlocks(
    File imageFile, {
    String language = 'en',
    Future<void> Function(double fraction, String stepName)? onProgress,
  }) async {
    final tessLang = _toTesseractLang(language);
    final tempDir = await getTemporaryDirectory();
    final ownTempFiles = <String>[];

    try {
      // Étape 1 : prétraitement (~4s, 2% du temps total OCR)
      await onProgress?.call(0.00, 'Prétraitement de l\'image…');
      final preprocessed = await _preprocessImage(imageFile, tempDir);
      ownTempFiles.add(preprocessed.path);

      // Étape 2 : passe 1 — détection des régions sur image normale (~20% du temps total)
      await onProgress?.call(0.02, 'Détection des zones de texte…');
      var blockRects = await _withSimulatedProgress(
        _detectBlockRects(preprocessed, tessLang, tempDir),
        onProgress: onProgress, start: 0.02, end: 0.22,
        label: 'Détection des zones de texte…', expectedMs: 20000,
      );
      logger.i('Passe 1 (normale) — régions détectées: ${blockRects.length}');

      // Passe 1 bis sur image inversée : capte les zones à texte blanc sur fond sombre
      // Inversion+écriture (~3s, 1.5%) puis tesseract (~26% du temps total)
      await onProgress?.call(0.22, 'Inversion de l\'image…');
      final srcBytes = await preprocessed.readAsBytes();
      final srcDecoded = img.decodeImage(srcBytes);
      if (srcDecoded != null) {
        final inverted = img.invert(img.copyCrop(srcDecoded,
            x: 0, y: 0, width: srcDecoded.width, height: srcDecoded.height));
        final invPath = p.join(tempDir.path, 'inv_${DateTime.now().millisecondsSinceEpoch}.png');
        await File(invPath).writeAsBytes(img.encodePng(inverted));
        ownTempFiles.add(invPath);
        await onProgress?.call(0.25, 'Détection des zones sombres…');
        final invRects = await _withSimulatedProgress(
          _detectBlockRects(File(invPath), tessLang, tempDir),
          onProgress: onProgress, start: 0.25, end: 0.50,
          label: 'Détection des zones sombres…', expectedMs: 25000,
        );
        if (invRects.isNotEmpty) {
          final added = _mergeRects(blockRects, invRects);
          logger.i('Passe 1 (inversée) — ${invRects.length} régions → ${added.length - blockRects.length} nouvelles');
          blockRects = added;
        }
      }

      logger.i('Passe 1 total — ${blockRects.length} région(s)');

      if (blockRects.isEmpty) {
        // Fallback pleine page : PSM 3 puis PSM 11 (sparse text) si toujours vide
        logger.w('Aucune région détectée — fallback pleine page');
        await onProgress?.call(0.52, 'OCR pleine page (fallback)…');
        var fallback = await _withSimulatedProgress(
          _runOCR(preprocessed, tessLang, tempDir, psm: '3'),
          onProgress: onProgress, start: 0.52, end: 0.80,
          label: 'OCR pleine page (fallback)…', expectedMs: 20000,
        );
        if (fallback.isEmpty) {
          logger.w('PSM 3 vide — essai PSM 11 (sparse text)');
          await onProgress?.call(0.80, 'OCR pleine page (sparse)…');
          fallback = await _withSimulatedProgress(
            _runOCR(preprocessed, tessLang, tempDir, psm: '11'),
            onProgress: onProgress, start: 0.80, end: 1.00,
            label: 'OCR pleine page (sparse)…', expectedMs: 15000,
          );
        }
        logger.i('Fallback pleine page: ${fallback.length} bloc(s)');
        await onProgress?.call(1.00, 'Extraction terminée');
        return fallback;
      }

      // Étape 3 : passe 2 — OCR par région (--psm 6) (~50% du temps total, uniforme par région)
      final n = blockRects.length;
      final result = <OCRTextBlock>[];
      for (int ri = 0; ri < n; ri++) {
        final blockStart = 0.50 + 0.50 * ri / n;
        final blockEnd   = 0.50 + 0.50 * (ri + 1) / n;
        await onProgress?.call(blockStart, 'OCR zone ${ri + 1}/$n…');
        final rect = blockRects[ri];
        if (srcDecoded == null) break;
        final crop = _cropRegion(srcDecoded, rect);
        if (crop == null) continue;

        // Inverser le crop si le fond est majoritairement sombre (texte blanc sur noir)
        final dark = _isDarkRegion(crop.image);
        final cropImage = dark
            ? img.invert(img.copyCrop(crop.image, x: 0, y: 0,
                width: crop.image.width, height: crop.image.height))
            : crop.image;
        if (dark) logger.d('  région[$ri]: fond sombre → inversion appliquée');

        final cropPath = p.join(
          tempDir.path,
          'crop_${rect.left.toInt()}_${rect.top.toInt()}_${DateTime.now().microsecondsSinceEpoch}.png',
        );
        await File(cropPath).writeAsBytes(img.encodePng(cropImage));
        ownTempFiles.add(cropPath);

        final blocks = await _withSimulatedProgress(
          _runOCR(File(cropPath), tessLang, tempDir, psm: '6',
              offsetX: crop.originX, offsetY: crop.originY),
          onProgress: onProgress, start: blockStart, end: blockEnd,
          label: 'OCR zone ${ri + 1}/$n…', expectedMs: 2500,
        );
        logger.d('  région[$ri] ${rect.width.toInt()}×${rect.height.toInt()} → ${blocks.length} bloc(s)');
        result.addAll(blocks);
      }

      await onProgress?.call(1.00, 'Extraction terminée');
      logger.i('Passe 2 — total blocs avant filtrage garbage: ${result.length}');
      return result;
    } finally {
      for (final path in ownTempFiles) {
        try { await File(path).delete(); } catch (_) {}
      }
    }
  }

  // Retourne true si la luminance moyenne de l'image est < 127 (fond sombre)
  bool _isDarkRegion(img.Image image) {
    int sum = 0;
    int count = 0;
    final stepX = max(1, image.width ~/ 20);
    final stepY = max(1, image.height ~/ 20);
    for (int y = 0; y < image.height; y += stepY) {
      for (int x = 0; x < image.width; x += stepX) {
        sum += image.getPixel(x, y).r.toInt();
        count++;
      }
    }
    return count > 0 && (sum ~/ count) < 127;
  }

  // Fusionne deux listes de Rect en écartant les doublons (IoU > 0.3)
  List<Rect> _mergeRects(List<Rect> base, List<Rect> additional) {
    final result = List<Rect>.from(base);
    for (final newRect in additional) {
      final overlap = base.any((r) => _iou(r, newRect) > 0.3);
      if (!overlap) result.add(newRect);
    }
    return result;
  }

  double _iou(Rect a, Rect b) {
    final il = max(a.left, b.left);
    final it = max(a.top, b.top);
    final ir = min(a.right, b.right);
    final ib = min(a.bottom, b.bottom);
    if (ir <= il || ib <= it) return 0;
    final inter = (ir - il) * (ib - it);
    return inter / (a.width * a.height + b.width * b.height - inter);
  }

  // Niveaux de gris + normalisation pour améliorer le contraste des scans
  Future<File> _preprocessImage(File imageFile, Directory tempDir) async {
    final bytes = await imageFile.readAsBytes();
    final src = img.decodeImage(bytes);
    if (src == null) return imageFile;

    var processed = img.grayscale(src);
    processed = img.normalize(processed, min: 0, max: 255);

    final outPath = p.join(tempDir.path, 'prep_${DateTime.now().millisecondsSinceEpoch}.png');
    await File(outPath).writeAsBytes(img.encodePng(processed));
    return File(outPath);
  }

  // Passe 1 : récupère les bounding boxes de niveau 2 (blocs Tesseract)
  Future<List<Rect>> _detectBlockRects(
    File imageFile, String tessLang, Directory tempDir,
  ) async {
    final outputBase = p.join(tempDir.path, 'det_${DateTime.now().millisecondsSinceEpoch}');
    final env = await _tessdataEnv();
    final args1 = [imageFile.path, outputBase, '-l', tessLang, 'tsv'];
    logger.d('tesseract (passe1) ${args1.join(' ')}');
    var result = await Process.run('tesseract', args1, environment: env);
    logger.d('tesseract passe1 exit=${result.exitCode}');
    if ((result.stderr as String).isNotEmpty) logger.d('tesseract passe1 stderr: ${result.stderr}');

    if (result.exitCode != 0 && tessLang.contains('+')) {
      final baseLang = tessLang.split('+').first;
      logger.w('Tesseract: "$tessLang" indisponible, fallback vers "$baseLang"');
      final args2 = [imageFile.path, outputBase, '-l', baseLang, 'tsv'];
      logger.d('tesseract (passe1-fallback) ${args2.join(' ')}');
      result = await Process.run('tesseract', args2, environment: env);
      logger.d('tesseract passe1-fallback exit=${result.exitCode}');
      if ((result.stderr as String).isNotEmpty) logger.d('tesseract passe1-fallback stderr: ${result.stderr}');
    }

    final tsvFile = File('$outputBase.tsv');
    if (result.exitCode != 0 || !await tsvFile.exists()) {
      logger.e('tesseract passe1 échoué — pas de TSV généré');
      return [];
    }

    final tsv = await tsvFile.readAsString();
    await tsvFile.delete();

    return _parseBlockRects(tsv);
  }

  List<Rect> _parseBlockRects(String tsv) {
    final rects = <Rect>[];
    for (final line in tsv.split('\n').skip(1)) {
      final parts = line.split('\t');
      if (parts.length < 10) continue;
      if ((int.tryParse(parts[0]) ?? 0) != 2) continue; // niveau 2 = bloc

      final left   = double.tryParse(parts[6]) ?? 0;
      final top    = double.tryParse(parts[7]) ?? 0;
      final width  = double.tryParse(parts[8]) ?? 0;
      final height = double.tryParse(parts[9]) ?? 0;

      if (width < 20 || height < 20) continue;
      rects.add(Rect.fromLTWH(left, top, width, height));
    }
    return rects;
  }

  static const int _cropPad = 8;

  // Recadre une région avec padding; retourne null si dimensions invalides
  _CropResult? _cropRegion(img.Image src, Rect rect) {
    final x = max(0, rect.left.toInt() - _cropPad);
    final y = max(0, rect.top.toInt() - _cropPad);
    final w = min(src.width  - x, rect.width.toInt()  + 2 * _cropPad);
    final h = min(src.height - y, rect.height.toInt() + 2 * _cropPad);
    if (w <= 0 || h <= 0) return null;

    return _CropResult(
      image:   img.copyCrop(src, x: x, y: y, width: w, height: h),
      originX: x.toDouble(),
      originY: y.toDouble(),
    );
  }

  // Lance Tesseract sur un fichier image et retourne les blocs texte
  Future<List<OCRTextBlock>> _runOCR(
    File imageFile, String tessLang, Directory tempDir, {
    required String psm,
    double offsetX = 0,
    double offsetY = 0,
  }) async {
    final outputBase = p.join(tempDir.path, 'ocr_${DateTime.now().millisecondsSinceEpoch}');
    final env = await _tessdataEnv();
    final args1 = [imageFile.path, outputBase, '-l', tessLang, '--psm', psm, 'tsv'];
    logger.d('tesseract (passe2 psm=$psm) ${args1.join(' ')}');
    var result = await Process.run('tesseract', args1, environment: env);
    logger.d('tesseract passe2 exit=${result.exitCode}');
    if ((result.stderr as String).isNotEmpty) logger.d('tesseract passe2 stderr: ${result.stderr}');

    if (result.exitCode != 0 && tessLang.contains('+')) {
      final baseLang = tessLang.split('+').first;
      logger.w('Tesseract: "$tessLang" indisponible, fallback vers "$baseLang"');
      final args2 = [imageFile.path, outputBase, '-l', baseLang, '--psm', psm, 'tsv'];
      logger.d('tesseract (passe2-fallback psm=$psm) ${args2.join(' ')}');
      result = await Process.run('tesseract', args2, environment: env);
      logger.d('tesseract passe2-fallback exit=${result.exitCode}');
      if ((result.stderr as String).isNotEmpty) logger.d('tesseract passe2-fallback stderr: ${result.stderr}');
    }

    if (result.exitCode != 0) {
      logger.e('Tesseract error (psm $psm): ${result.stderr}');
      return [];
    }

    final tsvFile = File('$outputBase.tsv');
    if (!await tsvFile.exists()) return [];

    final tsv = await tsvFile.readAsString();
    await tsvFile.delete();

    return _parseTSV(tsv, offsetX: offsetX, offsetY: offsetY);
  }

  List<OCRTextBlock> _parseTSV(String tsv, {double offsetX = 0, double offsetY = 0}) {
    final lines = tsv.split('\n');
    if (lines.length < 2) {
      logger.w('TSV vide ou invalide (${lines.length} ligne(s))');
      return [];
    }

    final Map<String, _ParagraphGroup> groups = {};
    int wordsTotal = 0;
    int wordsLowConf = 0;

    for (final line in lines.skip(1)) {
      final parts = line.split('\t');
      if (parts.length < 12) continue;

      final level = int.tryParse(parts[0]) ?? 0;
      if (level != 5) continue; // niveau 5 = mots

      wordsTotal++;
      final pageNum  = parts[1];
      final blockNum = parts[2];
      final parNum   = parts[3];
      final left   = (double.tryParse(parts[6]) ?? 0) + offsetX;
      final top    = (double.tryParse(parts[7]) ?? 0) + offsetY;
      final width  = double.tryParse(parts[8]) ?? 0;
      final height = double.tryParse(parts[9]) ?? 0;
      final conf   = double.tryParse(parts[10]) ?? -1;
      final text   = parts[11].trim();

      if (conf < 50 || text.isEmpty) { wordsLowConf++; continue; }

      final key = '$pageNum-$blockNum-$parNum';
      groups.putIfAbsent(key, () => _ParagraphGroup());
      groups[key]!.addWord(text, conf, left, top, left + width, top + height);
    }

    logger.d('TSV: $wordsTotal mots lus, $wordsLowConf filtrés (conf<50), ${groups.length} groupes formés');

    final all        = groups.values.where((g) => g.words.isNotEmpty).toList();
    final confOk     = all.where((g) => g.avgConf >= 40).toList();
    final sizeOk     = confOk.where((g) => g.bbox.width >= 20 && g.bbox.height >= 10).toList();
    final notGarbage = sizeOk.where((g) => !_isGarbageText(g.text)).toList();

    logger.d('Filtrage: ${all.length} groupes → conf≥40: ${confOk.length} → taille ok: ${sizeOk.length} → non-garbage: ${notGarbage.length}');

    return notGarbage
        .map((g) => OCRTextBlock(text: g.text, boundingBox: g.bbox))
        .toList();
  }

  // Détecte les chaînes sans contenu significatif (artefacts OCR dans les illustrations)
  bool _isGarbageText(String text) {
    final stripped = text.trim();
    if (stripped.isEmpty) return true;

    final nonSpace = stripped.replaceAll(' ', '');
    if (nonSpace.isEmpty) return true;

    // Compte les caractères significatifs : lettres latines, japonais, chiffres
    int meaningful = 0;
    final charFreq = <String, int>{};
    for (final rune in stripped.runes) {
      final c = String.fromCharCode(rune);
      if (c == ' ') continue;
      charFreq[c] = (charFreq[c] ?? 0) + 1;
      if ((rune >= 0x41  && rune <= 0x5A)  || // A–Z
          (rune >= 0x61  && rune <= 0x7A)  || // a–z
          (rune >= 0x30  && rune <= 0x39)  || // 0–9
          (rune >= 0x3040 && rune <= 0x309F) || // hiragana
          (rune >= 0x30A0 && rune <= 0x30FF) || // katakana
          (rune >= 0xFF65 && rune <= 0xFF9F) || // katakana demi-largeur
          (rune >= 0x4E00 && rune <= 0x9FFF)) { // kanji
        meaningful++;
      }
    }

    // A : trop peu de caractères significatifs
    if (meaningful < 3) return true;

    // B : trop de caractères parasites (> 40 % du total hors espaces)
    if ((nonSpace.length - meaningful) / nonSpace.length > 0.4) return true;

    // C : un seul caractère domine à > 50 % → hachure/bord OCR ("XXXXXXXX")
    for (final entry in charFreq.entries) {
      if (entry.key != '.' && entry.value > 4 && entry.value / nonSpace.length > 0.5) {
        return true;
      }
    }

    // D : majorité de mots d'une seule lettre → lignes d'illustration ("N Stylo O N")
    final words = stripped.split(RegExp(r'\s+'));
    if (words.length >= 3) {
      final singleChar = words.where((w) => w.length == 1).length;
      if (singleChar / words.length > 0.6) return true;
    }

    return false;
  }
}

class _CropResult {
  final img.Image image;
  final double originX;
  final double originY;
  const _CropResult({required this.image, required this.originX, required this.originY});
}

class _ParagraphGroup {
  final List<String> words = [];
  double left   = double.infinity;
  double top    = double.infinity;
  double right  = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  double _totalConf = 0;
  int _wordCount = 0;

  void addWord(String word, double conf, double l, double t, double r, double b) {
    words.add(word);
    _totalConf += conf;
    _wordCount++;
    if (l < left)   left   = l;
    if (t < top)    top    = t;
    if (r > right)  right  = r;
    if (b > bottom) bottom = b;
  }

  double get avgConf => _wordCount > 0 ? _totalConf / _wordCount : 0;
  String get text => words.join(' ');
  Rect get bbox => Rect.fromLTRB(left, top, right, bottom);
}

class OCRTextBlock {
  final String text;
  final Rect boundingBox;

  OCRTextBlock({required this.text, required this.boundingBox});
}
