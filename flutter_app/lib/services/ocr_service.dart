import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'app_logger.dart';

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

  static String? _localTessdata;

  Future<Map<String, String>?> _tessdataEnv() async {
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
    int dpi = 600,
    Future<void> Function(double fraction, String stepName)? onProgress,
  }) async {
    final tessLang = _toTesseractLang(language);
    final tempDir = await getTemporaryDirectory();
    final ownTempFiles = <String>[];

    try {
      await onProgress?.call(0.00, 'Prétraitement de l\'image…');
      final prep = await _preprocessImage(imageFile, tempDir, dpi,
          onProgress: onProgress == null ? null :
              (frac, step) async { await onProgress(frac * 0.15, step); });
      ownTempFiles.add(prep.file.path);

      await onProgress?.call(0.15, 'Détection des zones de texte…');
      var blockRects = await _withSimulatedProgress(
        _detectBlockRects(prep.file, tessLang, tempDir, dpi: dpi),
        onProgress: onProgress, start: 0.15, end: 0.42,
        label: 'Détection des zones de texte…', expectedMs: 35000,
      );
      blockRects = _selfDeduplicate(blockRects);
      logger.i('Passe 1 (normale) — régions détectées: ${blockRects.length}');

      await onProgress?.call(0.42, 'Inversion de l\'image…');
      final srcBytes = await prep.file.readAsBytes();
      final srcDecoded = img.decodeImage(srcBytes);
      if (srcDecoded != null) {
        final inverted = img.invert(img.copyCrop(srcDecoded,
            x: 0, y: 0, width: srcDecoded.width, height: srcDecoded.height));
        final invPath = p.join(tempDir.path, 'inv_${DateTime.now().millisecondsSinceEpoch}.png');
        await File(invPath).writeAsBytes(img.encodePng(inverted));
        ownTempFiles.add(invPath);
        await onProgress?.call(0.44, 'Détection des zones sombres…');
        final invRects = await _withSimulatedProgress(
          _detectBlockRects(File(invPath), tessLang, tempDir, dpi: dpi),
          onProgress: onProgress, start: 0.44, end: 0.68,
          label: 'Détection des zones sombres…', expectedMs: 40000,
        );
        if (invRects.isNotEmpty) {
          final added = _mergeRects(blockRects, invRects);
          logger.i('Passe 1 (inversée) — ${invRects.length} régions → ${added.length - blockRects.length} nouvelles');
          blockRects = added;
        }
      }

      logger.i('Passe 1 total — ${blockRects.length} région(s)');

      if (blockRects.isEmpty) {
        logger.w('Aucune région détectée — fallback pleine page');
        await onProgress?.call(0.70, 'OCR pleine page (fallback)…');
        var fallback = await _withSimulatedProgress(
          _runOCR(prep.file, tessLang, tempDir, psm: '3', dpi: dpi),
          onProgress: onProgress, start: 0.70, end: 0.88,
          label: 'OCR pleine page (fallback)…', expectedMs: 25000,
        );
        if (fallback.isEmpty) {
          logger.w('PSM 3 vide — essai PSM 11 (sparse text)');
          await onProgress?.call(0.88, 'OCR pleine page (sparse)…');
          fallback = await _withSimulatedProgress(
            _runOCR(prep.file, tessLang, tempDir, psm: '11', dpi: dpi),
            onProgress: onProgress, start: 0.88, end: 1.00,
            label: 'OCR pleine page (sparse)…', expectedMs: 20000,
          );
        }
        logger.i('Fallback pleine page: ${fallback.length} bloc(s)');
        await onProgress?.call(1.00, 'Extraction terminée');
        if (prep.hasTransform) {
          return fallback.map((b) => OCRTextBlock(
            text: b.text,
            boundingBox: _inverseTransformRect(b.boundingBox, prep),
          )).toList();
        }
        return fallback;
      }

      final n = blockRects.length;
      final result = <OCRTextBlock>[];
      for (int ri = 0; ri < n; ri++) {
        final blockStart = 0.68 + 0.32 * ri / n;
        final blockEnd   = 0.68 + 0.32 * (ri + 1) / n;
        await onProgress?.call(blockStart, 'OCR zone ${ri + 1}/$n…');
        final rect = blockRects[ri];
        if (srcDecoded == null) break;
        final crop = _cropRegion(srcDecoded, rect);
        if (crop == null) continue;

        final dark = _isDarkRegion(crop.image);
        final cropImage = dark
            ? img.invert(img.copyCrop(crop.image, x: 0, y: 0,
                width: crop.image.width, height: crop.image.height))
            : crop.image;
        if (dark) logger.d('  région[$ri]: fond sombre → inversion appliquée');

        // Upscale crop 2× (bicubic) pour améliorer l'OCR sur les petits caractères
        final upscaled = img.copyResize(
          cropImage,
          width: cropImage.width * 2,
          height: cropImage.height * 2,
          interpolation: img.Interpolation.cubic,
        );

        final cropPath = p.join(
          tempDir.path,
          'crop_${rect.left.toInt()}_${rect.top.toInt()}_${DateTime.now().microsecondsSinceEpoch}.png',
        );
        await File(cropPath).writeAsBytes(img.encodePng(upscaled));
        ownTempFiles.add(cropPath);

        final blocks = await _withSimulatedProgress(
          _runOCR(File(cropPath), tessLang, tempDir, psm: '6',
              dpi: dpi * 2, offsetX: crop.originX, offsetY: crop.originY,
              scale: 2.0),
          onProgress: onProgress, start: blockStart, end: blockEnd,
          label: 'OCR zone ${ri + 1}/$n…', expectedMs: 6000,
        );
        logger.d('  région[$ri] ${rect.width.toInt()}×${rect.height.toInt()} → ${blocks.length} bloc(s)');
        result.addAll(blocks);
      }

      await onProgress?.call(1.00, 'Extraction terminée');
      logger.i('Passe 2 — total blocs: ${result.length}');

      // Remapper les bboxes depuis l'espace prétraité (deskew+dewarp) vers l'espace original
      if (prep.hasTransform) {
        return result.map((b) => OCRTextBlock(
          text: b.text,
          boundingBox: _inverseTransformRect(b.boundingBox, prep),
        )).toList();
      }
      return result;
    } finally {
      for (final path in ownTempFiles) {
        try { await File(path).delete(); } catch (_) {}
      }
    }
  }

  // ─── Prétraitement ────────────────────────────────────────────────────────

  Future<_PrepResult> _preprocessImage(
      File imageFile, Directory tempDir, int dpi,
      {Future<void> Function(double, String)? onProgress}) async {
    final bytes = await imageFile.readAsBytes();
    final src = img.decodeImage(bytes);
    if (src == null) {
      return _PrepResult(
        file: imageFile, skewAngle: 0.0,
        prepWidth: 0, prepHeight: 0, origWidth: 0, origHeight: 0,
        dewarpStripOffsets: const [], dewarpStripWidth: 1,
      );
    }

    final origW = src.width;
    final origH = src.height;
    final t0 = DateTime.now();
    int ms() => DateTime.now().difference(t0).inMilliseconds;
    logger.i('Prétraitement démarré — image ${origW}×${origH} px');

    var gray = img.grayscale(src);

    await onProgress?.call(0.00, 'Correction d\'éclairage…');
    gray = _subtractBackground(gray);
    logger.d('  correction éclairage      : ${ms()} ms');

    await onProgress?.call(0.15, 'Filtre médian…');
    gray = _medianFilter3x3(gray);
    logger.d('  filtre médian 3×3          : ${ms()} ms');

    await onProgress?.call(0.25, 'Binarisation adaptative…');
    gray = img.normalize(gray, min: 0, max: 255);
    var binary = _adaptiveSauvola(gray);
    logger.d('  binarisation Sauvola       : ${ms()} ms');

    await onProgress?.call(0.60, 'Nettoyage des artefacts…');
    binary = _despeckle(binary);
    logger.d('  despeckle composantes      : ${ms()} ms');

    await onProgress?.call(0.72, 'Épaississement des traits…');
    binary = _dilate(binary);
    logger.d('  dilatation 1 px            : ${ms()} ms');

    await onProgress?.call(0.82, 'Correction d\'inclinaison…');
    final deskewData = _deskew(binary);
    binary = deskewData.image;
    final skewAngle = deskewData.angle;
    final prepW = deskewData.prepW;
    final prepH = deskewData.prepH;
    logger.d('  deskew (${skewAngle.toStringAsFixed(2)}°)              : ${ms()} ms');

    await onProgress?.call(0.92, 'Correction de déformation…');
    final dewarpData = _dewarp(binary);
    binary = dewarpData.image;
    final dewarpOffsets = dewarpData.stripOffsets;
    final dewarpStripW = dewarpData.stripW;
    logger.d('  dewarp (${dewarpOffsets.isEmpty ? "aucun" : "${dewarpOffsets.map((o) => o.toStringAsFixed(1)).join(",")}"}) : ${ms()} ms');

    await onProgress?.call(0.98, 'Sauvegarde image prétraitée…');
    final outPath = p.join(tempDir.path, 'prep_${DateTime.now().millisecondsSinceEpoch}.png');
    await File(outPath).writeAsBytes(img.encodePng(binary));
    logger.i('Prétraitement terminé — durée totale ${ms()} ms | '
        'deskew=${skewAngle.toStringAsFixed(2)}° | '
        'dewarp=${dewarpOffsets.isEmpty ? "non" : "oui (${dewarpOffsets.length} bandes)"}');

    final debugDir = AppLogger.debugDir;
    if (debugDir != null) {
      final m = RegExp(r'page_(\d+)_').firstMatch(p.basename(imageFile.path));
      final name = 'prep_page_${m?.group(1) ?? DateTime.now().millisecondsSinceEpoch}.png';
      try { await File(outPath).copy(p.join(debugDir, name)); } catch (_) {}
    }

    return _PrepResult(
      file: File(outPath),
      skewAngle: skewAngle,
      prepWidth: prepW,
      prepHeight: prepH,
      origWidth: origW,
      origHeight: origH,
      dewarpStripOffsets: dewarpOffsets,
      dewarpStripWidth: dewarpStripW,
    );
  }

  // ─── Correction d'éclairage ───────────────────────────────────────────────
  // Estime le fond (90e percentile par bloc 64×64) et normalise chaque pixel
  // pour neutraliser les gradients d'éclairage (ombre de reliure, etc.).
  img.Image _subtractBackground(img.Image gray) {
    final w = gray.width;
    final h = gray.height;

    final src = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        src[y * w + x] = gray.getPixel(x, y).r.toInt();
      }
    }

    const blockSize = 64;
    final bw = (w + blockSize - 1) ~/ blockSize + 1;
    final bh = (h + blockSize - 1) ~/ blockSize + 1;
    final bgGrid = Float64List(bw * bh);
    for (int i = 0; i < bgGrid.length; i++) bgGrid[i] = 255.0;

    final samples = <int>[];
    for (int by = 0; by < bh; by++) {
      for (int bx = 0; bx < bw; bx++) {
        final x0 = (bx * blockSize).clamp(0, w - 1);
        final y0 = (by * blockSize).clamp(0, h - 1);
        final x1 = min(w, x0 + blockSize);
        final y1 = min(h, y0 + blockSize);
        samples.clear();
        for (int y = y0; y < y1; y += 2) {
          for (int x = x0; x < x1; x += 2) {
            samples.add(src[y * w + x]);
          }
        }
        if (samples.isEmpty) continue;
        samples.sort();
        bgGrid[by * bw + bx] =
            samples[(samples.length * 0.90).floor().clamp(0, samples.length - 1)]
                .toDouble();
      }
    }

    final out = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      final byf = y / blockSize;
      final by0 = byf.floor().clamp(0, bh - 1);
      final by1 = (by0 + 1).clamp(0, bh - 1);
      final ty = byf - by0;
      for (int x = 0; x < w; x++) {
        final bxf = x / blockSize;
        final bx0 = bxf.floor().clamp(0, bw - 1);
        final bx1 = (bx0 + 1).clamp(0, bw - 1);
        final tx = bxf - bx0;
        final bg = bgGrid[by0 * bw + bx0] * (1 - tx) * (1 - ty) +
            bgGrid[by0 * bw + bx1] * tx * (1 - ty) +
            bgGrid[by1 * bw + bx0] * (1 - tx) * ty +
            bgGrid[by1 * bw + bx1] * tx * ty;
        final pix = src[y * w + x];
        final norm = bg > 20 ? ((pix / bg) * 255.0).round().clamp(0, 255) : pix;
        out.setPixelRgb(x, y, norm, norm, norm);
      }
    }
    return out;
  }

  // ─── Filtre médian 3×3 ────────────────────────────────────────────────────
  // Supprime le bruit sel-et-poivre sans flouter les contours, contrairement
  // au gaussien qui détruirait les traits fins.
  img.Image _medianFilter3x3(img.Image gray) {
    final w = gray.width;
    final h = gray.height;

    final src = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        src[y * w + x] = gray.getPixel(x, y).r.toInt();
      }
    }

    final out = img.Image(width: w, height: h, numChannels: 3);
    final win = List<int>.filled(9, 0);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (x == 0 || x == w - 1 || y == 0 || y == h - 1) {
          final v = src[y * w + x];
          out.setPixelRgb(x, y, v, v, v);
          continue;
        }
        int k = 0;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            win[k++] = src[(y + dy) * w + (x + dx)];
          }
        }
        win.sort();
        final med = win[4];
        out.setPixelRgb(x, y, med, med, med);
      }
    }
    return out;
  }

  // ─── Nettoyage par composantes connexes ───────────────────────────────────
  // Supprime les îlots de pixels noirs inférieurs à minSize px² (grain, bruit
  // résiduel après binarisation). Les caractères les plus petits font ~50 px²
  // à 600 DPI, donc minSize=10 est conservateur.
  img.Image _despeckle(img.Image binary, {int minSize = 10}) {
    final w = binary.width;
    final h = binary.height;

    final src = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        src[y * w + x] = binary.getPixel(x, y).r.toInt();
      }
    }

    final visited = Uint8List(w * h);
    final result  = Uint8List.fromList(src);
    final stack   = <int>[];
    final component = <int>[];

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final idx = y * w + x;
        if (src[idx] != 0 || visited[idx] != 0) continue;

        stack.clear();
        component.clear();
        stack.add(idx);
        visited[idx] = 1;
        var large = false;

        while (stack.isNotEmpty) {
          final cur = stack.removeLast();
          if (!large) component.add(cur);
          if (component.length >= minSize) large = true;

          final cx = cur % w;
          final cy = cur ~/ w;
          if (cx > 0) {
            final n = cur - 1;
            if (src[n] == 0 && visited[n] == 0) { visited[n] = 1; stack.add(n); }
          }
          if (cx < w - 1) {
            final n = cur + 1;
            if (src[n] == 0 && visited[n] == 0) { visited[n] = 1; stack.add(n); }
          }
          if (cy > 0) {
            final n = cur - w;
            if (src[n] == 0 && visited[n] == 0) { visited[n] = 1; stack.add(n); }
          }
          if (cy < h - 1) {
            final n = cur + w;
            if (src[n] == 0 && visited[n] == 0) { visited[n] = 1; stack.add(n); }
          }
        }

        if (!large) {
          for (final i in component) result[i] = 255;
        }
      }
    }

    final out = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final v = result[y * w + x];
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    return out;
  }

  // ─── Dilatation morphologique 1 px ────────────────────────────────────────
  // Épaissit les traits fins après binarisation pour combler les micro-coupures
  // dans les caractères. Sans érosion préalable (contrairement à l'ouverture),
  // le despeckle précédent ayant déjà éliminé le grain.
  img.Image _dilate(img.Image binary) {
    final w = binary.width;
    final h = binary.height;

    final src = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        src[y * w + x] = binary.getPixel(x, y).r.toInt();
      }
    }

    final out = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        bool anyBlack = false;
        for (int dy = -1; dy <= 1 && !anyBlack; dy++) {
          for (int dx = -1; dx <= 1 && !anyBlack; dx++) {
            final sy = (y + dy).clamp(0, h - 1);
            final sx = (x + dx).clamp(0, w - 1);
            if (src[sy * w + sx] == 0) anyBlack = true;
          }
        }
        final v = anyBlack ? 0 : 255;
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    return out;
  }

  // ─── Correction d'inclinaison (deskew) ────────────────────────────────────
  // Profil de projection : cherche l'angle (−5° … +5°) qui maximise la variance
  // des projections horizontales (lignes de texte bien horizontales → pics nets).
  // Travaille sur image réduite (1/6) pour la recherche, puis applique au plein.
  ({img.Image image, double angle, int prepW, int prepH}) _deskew(img.Image binary) {
    const sampleDiv = 6;
    final small = img.copyResize(
      binary,
      width: binary.width ~/ sampleDiv,
      height: binary.height ~/ sampleDiv,
      interpolation: img.Interpolation.average,
    );

    // Recherche grossière
    double bestAngle = 0.0;
    double bestScore = -1.0;
    for (double a = -5.0; a <= 5.0; a += 0.3) {
      final score = _projectionVariance(img.copyRotate(small, angle: a));
      if (score > bestScore) { bestScore = score; bestAngle = a; }
    }
    // Affinage
    for (double a = bestAngle - 0.5; a <= bestAngle + 0.5; a += 0.05) {
      final score = _projectionVariance(img.copyRotate(small, angle: a));
      if (score > bestScore) { bestScore = score; bestAngle = a; }
    }

    logger.d('Deskew: angle optimal = ${bestAngle.toStringAsFixed(2)}° '
        '(variance=${bestScore.toStringAsFixed(0)})');
    if (bestAngle.abs() < 0.1) {
      logger.i('Deskew: inclinaison négligeable (< 0.1°), pas de correction');
      return (image: binary, angle: 0.0, prepW: binary.width, prepH: binary.height);
    }

    binary.backgroundColor = img.ColorRgb8(255, 255, 255);
    final deskewed = img.copyRotate(binary, angle: bestAngle,
        interpolation: img.Interpolation.linear);
    binary.backgroundColor = null;

    logger.i('Deskew: correction ${bestAngle > 0 ? "+" : ""}${bestAngle.toStringAsFixed(2)}° '
        '→ image ${deskewed.width}×${deskewed.height} px '
        '(était ${binary.width}×${binary.height})');
    return (image: deskewed, angle: bestAngle, prepW: deskewed.width, prepH: deskewed.height);
  }

  double _projectionVariance(img.Image binary) {
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

  // ─── Correction de déformation de page (dewarp) ───────────────────────────
  // Détecte la courbure des lignes de texte en comparant leur position verticale
  // dans 16 bandes verticales. Applique un décalage par colonne (bilinéaire)
  // pour redresser la courbure. Pas de correction si l'écart max < 3 px.
  ({img.Image image, List<double> stripOffsets, int stripW}) _dewarp(
      img.Image binary) {
    const strips = 16;
    final w = binary.width;
    final h = binary.height;
    final sw = w ~/ strips;
    if (sw == 0) return (image: binary, stripOffsets: const [], stripW: 1);

    final src = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        src[y * w + x] = binary.getPixel(x, y).r.toInt();
      }
    }

    // Projection horizontale par bande
    final stripPeaks = <List<int>>[];
    for (int s = 0; s < strips; s++) {
      final x0 = s * sw;
      final x1 = (s == strips - 1) ? w : x0 + sw;
      final proj = List<int>.filled(h, 0);
      for (int y = 0; y < h; y++) {
        for (int x = x0; x < x1; x++) {
          if (src[y * w + x] == 0) proj[y]++;
        }
      }
      // Lissage (moyenne mobile 5)
      final smooth = List<int>.filled(h, 0);
      for (int y = 0; y < h; y++) {
        var s2 = 0;
        for (int dy = -2; dy <= 2; dy++) {
          s2 += proj[(y + dy).clamp(0, h - 1)];
        }
        smooth[y] = s2 ~/ 5;
      }
      final threshold = (x1 - x0) ~/ 12;
      stripPeaks.add(_findProjectionPeaks(smooth, minValue: threshold, minDist: 60));
    }

    // Référence = bande centrale
    final refIdx = strips ~/ 2;
    final refPeaks = stripPeaks[refIdx];
    if (refPeaks.isEmpty) {
      logger.d('Dewarp: aucune ligne de référence, pas de correction');
      return (image: binary, stripOffsets: const [], stripW: sw);
    }

    // Calcul des décalages par bande (médiane sur les pics appariés)
    final stripOffsets = List<double>.filled(strips, 0.0);
    for (int s = 0; s < strips; s++) {
      if (s == refIdx) continue;
      final peaks = stripPeaks[s];
      if (peaks.isEmpty) continue;
      final offsets = <double>[];
      for (final refY in refPeaks) {
        int? closest;
        int minDist = 80;
        for (final pk in peaks) {
          final d = (pk - refY).abs();
          if (d < minDist) { minDist = d; closest = pk; }
        }
        if (closest != null) offsets.add((refY - closest).toDouble());
      }
      if (offsets.isNotEmpty) {
        offsets.sort();
        stripOffsets[s] = offsets[offsets.length ~/ 2];
      }
    }

    final maxOff = stripOffsets.map((o) => o.abs()).reduce(max);
    final nonZero = stripOffsets.where((o) => o.abs() >= 1).length;
    if (maxOff < 3) {
      logger.i('Dewarp: déformation négligeable (max=${maxOff.toStringAsFixed(1)}px), pas de correction');
      return (image: binary, stripOffsets: const [], stripW: sw);
    }
    logger.i('Dewarp: correction appliquée — déviation max=${maxOff.toStringAsFixed(1)}px '
        'sur $nonZero/$strips bandes (lignes réf: ${refPeaks.length})');

    final out = img.Image(width: w, height: h, numChannels: 3);
    img.fill(out, color: img.ColorRgb8(255, 255, 255));

    for (int x = 0; x < w; x++) {
      final sf = x / sw;
      final s0 = sf.floor().clamp(0, strips - 1);
      final s1 = (s0 + 1).clamp(0, strips - 1);
      final t = sf - s0;
      final offset = (stripOffsets[s0] * (1 - t) + stripOffsets[s1] * t).round();
      for (int y = 0; y < h; y++) {
        final srcY = (y - offset).clamp(0, h - 1);
        final v = src[srcY * w + x];
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    return (image: out, stripOffsets: stripOffsets.toList(), stripW: sw);
  }

  List<int> _findProjectionPeaks(List<int> proj,
      {int minValue = 0, int minDist = 60}) {
    final peaks = <int>[];
    for (int i = 1; i < proj.length - 1; i++) {
      if (proj[i] <= proj[i - 1] || proj[i] <= proj[i + 1]) continue;
      if (proj[i] < minValue) continue;
      if (peaks.isNotEmpty && i - peaks.last < minDist) {
        if (proj[i] > proj[peaks.last]) peaks.removeLast();
        else continue;
      }
      peaks.add(i);
    }
    return peaks;
  }

  // ─── Transformation inverse deskew + dewarp ───────────────────────────────
  // Remapping d'un Rect depuis l'espace de l'image prétraitée (deskew+dewarp)
  // vers l'espace de l'image originale. Conserve width/height (erreur < 0,4 %
  // pour des angles < 5°). Nécessaire pour positionner le texte traduit sur
  // le fond PDF non transformé.
  Rect _inverseTransformRect(Rect r, _PrepResult prep) {
    if (!prep.hasTransform) return r;

    double cx = r.left + r.width / 2;
    double cy = r.top + r.height / 2;

    // 1. Défaire le dewarp : soustraire le décalage vertical appliqué en colonne x
    if (prep.dewarpStripOffsets.isNotEmpty) {
      final strips = prep.dewarpStripOffsets.length;
      final sw = prep.dewarpStripWidth;
      final sf = cx / sw;
      final s0 = sf.floor().clamp(0, strips - 1);
      final s1 = (s0 + 1).clamp(0, strips - 1);
      final t = sf - s0;
      final offset = prep.dewarpStripOffsets[s0] * (1 - t) +
          prep.dewarpStripOffsets[s1] * t;
      cy -= offset;
    }

    // 2. Défaire le deskew : rotation inverse autour du centre de l'image prétraitée
    if (prep.skewAngle.abs() >= 0.1) {
      final angle = prep.skewAngle * pi / 180.0;
      final ca = cos(angle);
      final sa = sin(angle);
      final dw2 = prep.prepWidth / 2.0;
      final dh2 = prep.prepHeight / 2.0;
      final w2  = prep.origWidth / 2.0;
      final h2  = prep.origHeight / 2.0;
      // Inverse de R(angle) = R(angle)^T : [[ca,sa],[-sa,ca]]
      final dx = cx - dw2;
      final dy = cy - dh2;
      cx = dx * ca + dy * sa + w2;
      cy = -dx * sa + dy * ca + h2;
    }

    return Rect.fromLTWH(cx - r.width / 2, cy - r.height / 2, r.width, r.height);
  }

  // ─── Binarisation Sauvola (inchangée) ─────────────────────────────────────

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

  List<Rect> _selfDeduplicate(List<Rect> rects) {
    final result = <Rect>[];
    for (final r in rects) {
      if (!result.any((e) => _centersOverlap(e, r))) result.add(r);
    }
    return result;
  }

  List<Rect> _mergeRects(List<Rect> base, List<Rect> additional) {
    final result = List<Rect>.from(base);
    for (final candidate in additional) {
      final isDuplicate = result.any((r) => _centersOverlap(r, candidate));
      if (!isDuplicate) result.add(candidate);
    }
    return result;
  }

  bool _centersOverlap(Rect a, Rect b) {
    final bCx = b.left + b.width / 2;
    final bCy = b.top + b.height / 2;
    if (bCx >= a.left && bCx <= a.right && bCy >= a.top && bCy <= a.bottom) return true;
    final aCx = a.left + a.width / 2;
    final aCy = a.top + a.height / 2;
    return aCx >= b.left && aCx <= b.right && aCy >= b.top && aCy <= b.bottom;
  }

  img.Image _adaptiveSauvola(img.Image gray) {
    double kLo = 0.02, kHi = 0.80, k = 0.25;
    img.Image result = _sauvolaBinarize(gray, k: k);

    for (int iter = 0; iter < 4; iter++) {
      final density = _blackPixelDensity(result);
      logger.d('Sauvola iter=$iter k=${k.toStringAsFixed(3)} densité=${(density * 100).toStringAsFixed(1)}%');
      if (density >= 0.05 && density <= 0.30) break;
      if (density < 0.05) { kHi = k; } else { kLo = k; }
      k = (kLo + kHi) / 2.0;
      result = _sauvolaBinarize(gray, k: k);
    }
    return result;
  }

  double _blackPixelDensity(img.Image binary) {
    const step = 4;
    int blacks = 0, count = 0;
    for (int y = 0; y < binary.height; y += step) {
      for (int x = 0; x < binary.width; x += step) {
        if (binary.getPixel(x, y).r.toInt() == 0) blacks++;
        count++;
      }
    }
    return count > 0 ? blacks / count : 0.0;
  }

  img.Image _sauvolaBinarize(img.Image gray,
      {int windowSize = 97, double k = 0.25, double r = 128.0}) {
    final w = gray.width;
    final h = gray.height;
    final stride = w + 1;

    final iSum   = Float64List(stride * (h + 1));
    final iSumSq = Float64List(stride * (h + 1));

    for (int y = 1; y <= h; y++) {
      for (int x = 1; x <= w; x++) {
        final v = gray.getPixel(x - 1, y - 1).r.toDouble();
        iSum[y * stride + x]   = v     + iSum[(y-1)*stride+x] + iSum[y*stride+x-1] - iSum[(y-1)*stride+x-1];
        iSumSq[y * stride + x] = v * v + iSumSq[(y-1)*stride+x] + iSumSq[y*stride+x-1] - iSumSq[(y-1)*stride+x-1];
      }
    }

    final half = windowSize ~/ 2;
    final out = img.Image(width: w, height: h, numChannels: 3);

    for (int y = 0; y < h; y++) {
      final y1 = max(0, y - half);
      final y2 = min(h - 1, y + half);
      for (int x = 0; x < w; x++) {
        final x1 = max(0, x - half);
        final x2 = min(w - 1, x + half);
        final count = (x2 - x1 + 1) * (y2 - y1 + 1);

        final s  = iSum[(y2+1)*stride+(x2+1)]   - iSum[y1*stride+(x2+1)]   - iSum[(y2+1)*stride+x1]   + iSum[y1*stride+x1];
        final sq = iSumSq[(y2+1)*stride+(x2+1)] - iSumSq[y1*stride+(x2+1)] - iSumSq[(y2+1)*stride+x1] + iSumSq[y1*stride+x1];

        final mean   = s / count;
        final stdDev = sqrt(max(0.0, sq / count - mean * mean));
        final threshold = mean * (1.0 + k * (stdDev / r - 1.0));

        final v = gray.getPixel(x, y).r.toDouble() <= threshold ? 0 : 255;
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    return out;
  }

  // ─── Détection de blocs (inchangée) ────────────────────────────────────────

  Future<List<Rect>> _detectBlockRects(
    File imageFile, String tessLang, Directory tempDir, {int dpi = 600}
  ) async {
    final rects3  = await _runDetection(imageFile, tessLang, tempDir, psm: '3',  dpi: dpi);
    final rects11 = await _runDetection(imageFile, tessLang, tempDir, psm: '11', dpi: dpi);
    logger.i('Détection PSM3=${rects3.length} PSM11=${rects11.length}');
    return _selfDeduplicate(_mergeRects(rects3, rects11));
  }

  Future<List<Rect>> _runDetection(
    File imageFile, String tessLang, Directory tempDir, {
    required String psm,
    int dpi = 600,
  }) async {
    final outputBase = p.join(tempDir.path, 'det_${DateTime.now().millisecondsSinceEpoch}');
    final env = await _tessdataEnv();
    List<String> _args(String lang) => [
      imageFile.path, outputBase, '-l', lang,
      '--oem', '1', '--dpi', '$dpi', '--psm', psm,
      '-c', 'load_system_dawg=0', '-c', 'load_freq_dawg=0',
      'tsv',
    ];

    logger.d('tesseract (détection psm=$psm) ${_args(tessLang).join(' ')}');
    var result = await Process.run('tesseract', _args(tessLang), environment: env);
    logger.d('tesseract détection psm=$psm exit=${result.exitCode}');
    if ((result.stderr as String).isNotEmpty) logger.d('stderr: ${result.stderr}');

    if (result.exitCode != 0 && tessLang.contains('+')) {
      final baseLang = tessLang.split('+').first;
      logger.w('Tesseract: "$tessLang" indisponible, fallback vers "$baseLang"');
      result = await Process.run('tesseract', _args(baseLang), environment: env);
      logger.d('tesseract détection-fallback exit=${result.exitCode}');
    }

    final tsvFile = File('$outputBase.tsv');
    if (result.exitCode != 0 || !await tsvFile.exists()) return [];
    final tsv = await tsvFile.readAsString();
    await tsvFile.delete();
    return _parseBlockRects(tsv);
  }

  List<Rect> _parseBlockRects(String tsv) {
    final rects = <Rect>[];
    for (final line in tsv.split('\n').skip(1)) {
      final parts = line.split('\t');
      if (parts.length < 10) continue;
      if ((int.tryParse(parts[0]) ?? 0) != 2) continue;

      final left   = double.tryParse(parts[6]) ?? 0;
      final top    = double.tryParse(parts[7]) ?? 0;
      final width  = double.tryParse(parts[8]) ?? 0;
      final height = double.tryParse(parts[9]) ?? 0;

      if (width < 40 || height < 40) continue;
      rects.add(Rect.fromLTWH(left, top, width, height));
    }
    return rects;
  }

  static const int _cropPad = 8;

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

  Future<List<OCRTextBlock>> _runOCR(
    File imageFile, String tessLang, Directory tempDir, {
    required String psm,
    int dpi = 600,
    double offsetX = 0,
    double offsetY = 0,
    double scale = 1.0,
  }) async {
    final outputBase = p.join(tempDir.path, 'ocr_${DateTime.now().millisecondsSinceEpoch}');
    final env = await _tessdataEnv();
    List<String> _args(String lang) => [
      imageFile.path, outputBase, '-l', lang,
      '--oem', '1', '--dpi', '$dpi', '--psm', psm,
      '-c', 'load_system_dawg=0', '-c', 'load_freq_dawg=0',
      'tsv',
    ];
    logger.d('tesseract (passe2 psm=$psm dpi=$dpi scale=$scale) ${_args(tessLang).join(' ')}');
    var result = await Process.run('tesseract', _args(tessLang), environment: env);
    logger.d('tesseract passe2 exit=${result.exitCode}');
    if ((result.stderr as String).isNotEmpty) logger.d('tesseract passe2 stderr: ${result.stderr}');

    if (result.exitCode != 0 && tessLang.contains('+')) {
      final baseLang = tessLang.split('+').first;
      logger.w('Tesseract: "$tessLang" indisponible, fallback vers "$baseLang"');
      result = await Process.run('tesseract', _args(baseLang), environment: env);
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

    return _parseTSV(tsv, offsetX: offsetX, offsetY: offsetY, scale: scale);
  }

  List<OCRTextBlock> _parseTSV(String tsv,
      {double offsetX = 0, double offsetY = 0, double scale = 1.0}) {
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
      if (level != 5) continue;

      wordsTotal++;
      final pageNum  = parts[1];
      final blockNum = parts[2];
      final parNum   = parts[3];
      // Diviser les coordonnées par scale pour ramener dans l'espace 600 DPI
      final left   = (double.tryParse(parts[6]) ?? 0) / scale + offsetX;
      final top    = (double.tryParse(parts[7]) ?? 0) / scale + offsetY;
      final width  = (double.tryParse(parts[8]) ?? 0) / scale;
      final height = (double.tryParse(parts[9]) ?? 0) / scale;
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
      if ((rune >= 0x41  && rune <= 0x5A)  ||
          (rune >= 0x61  && rune <= 0x7A)  ||
          (rune >= 0x30  && rune <= 0x39)  ||
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

// ─── Classes internes ─────────────────────────────────────────────────────────

class _PrepResult {
  final File file;
  final double skewAngle;
  final int prepWidth;
  final int prepHeight;
  final int origWidth;
  final int origHeight;
  final List<double> dewarpStripOffsets;
  final int dewarpStripWidth;

  const _PrepResult({
    required this.file,
    required this.skewAngle,
    required this.prepWidth,
    required this.prepHeight,
    required this.origWidth,
    required this.origHeight,
    required this.dewarpStripOffsets,
    required this.dewarpStripWidth,
  });

  bool get hasTransform =>
      skewAngle.abs() >= 0.1 || dewarpStripOffsets.isNotEmpty;
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
