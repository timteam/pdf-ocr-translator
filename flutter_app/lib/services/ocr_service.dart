import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
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

// ─── Fonctions top-level (isolate-safe) ───────────────────────────────────────

/// Pipeline complet de prétraitement dans un isolate séparé.
/// Retourne une Map sérialisable avec les bytes PNG traités + métadonnées.
Map<String, dynamic> _preprocessPipeline(Uint8List srcBytes) {
  final logs = <String>[];
  final t0 = DateTime.now();
  int ms() => DateTime.now().difference(t0).inMilliseconds;

  final src = img.decodeImage(srcBytes);
  if (src == null) {
    return {
      'processedBytes': srcBytes,
      'skewAngle': 0.0,
      'prepWidth': 0,
      'prepHeight': 0,
      'origWidth': 0,
      'origHeight': 0,
      'dewarpStripOffsets': <double>[],
      'dewarpStripWidth': 1,
      'elapsedMs': 0,
      'logs': logs,
    };
  }

  final origW = src.width;
  final origH = src.height;
  logs.add('i:Prétraitement démarré — image ${origW}×${origH} px');

  var gray = img.grayscale(src);

  gray = _ppSubtractBackground(gray, logs: logs);
  logs.add('d:  correction éclairage      : ${ms()} ms');

  gray = _ppMedianFilter3x3(gray);
  logs.add('d:  filtre médian 3×3          : ${ms()} ms');

  gray = img.normalize(gray, min: 0, max: 255);
  var binary = _ppAdaptiveSauvola(gray, logs: logs);
  logs.add('d:  binarisation Sauvola       : ${ms()} ms');

  binary = _ppDespeckle(binary);
  logs.add('d:  despeckle composantes      : ${ms()} ms');

  binary = _ppDilate(binary);
  logs.add('d:  dilatation 1 px            : ${ms()} ms');

  final deskewData = _ppDeskew(binary, logs: logs);
  binary = deskewData.image;
  final skewAngle = deskewData.angle;
  final prepW = deskewData.prepW;
  final prepH = deskewData.prepH;
  logs.add('d:  deskew (${skewAngle.toStringAsFixed(2)}°)              : ${ms()} ms');

  final dewarpData = _ppDewarp(binary, logs: logs);
  binary = dewarpData.image;
  final dewarpOffsets = dewarpData.stripOffsets;
  final dewarpStripW = dewarpData.stripW;
  logs.add('d:  dewarp (${dewarpOffsets.isEmpty ? "aucun" : dewarpOffsets.map((o) => o.toStringAsFixed(1)).join(",")}) : ${ms()} ms');

  final elapsedMs = ms();
  logs.add('i:Prétraitement terminé — durée totale $elapsedMs ms | '
      'deskew=${skewAngle.toStringAsFixed(2)}° | '
      'dewarp=${dewarpOffsets.isEmpty ? "non" : "oui (${dewarpOffsets.length} bandes)"}');

  return {
    'processedBytes': Uint8List.fromList(img.encodePng(binary)),
    'skewAngle': skewAngle,
    'prepWidth': prepW,
    'prepHeight': prepH,
    'origWidth': origW,
    'origHeight': origH,
    'dewarpStripOffsets': dewarpOffsets,
    'dewarpStripWidth': dewarpStripW,
    'elapsedMs': elapsedMs,
    'logs': logs,
  };
}

/// Inverse les pixels d'une image PNG dans un isolate.
Uint8List _invertImageBytes(Uint8List srcBytes) {
  final decoded = img.decodeImage(srcBytes);
  if (decoded == null) return srcBytes;
  return Uint8List.fromList(img.encodePng(img.invert(decoded)));
}

/// Upscale 2× bicubique d'un crop PNG dans un isolate.
Uint8List _upscaleCrop(Uint8List cropBytes) {
  final decoded = img.decodeImage(cropBytes);
  if (decoded == null) return cropBytes;
  final upscaled = img.copyResize(
    decoded,
    width: decoded.width * 2,
    height: decoded.height * 2,
    interpolation: img.Interpolation.cubic,
  );
  return Uint8List.fromList(img.encodePng(upscaled));
}

// ─── Correction d'éclairage ───────────────────────────────────────────────────
img.Image _ppSubtractBackground(img.Image gray, {List<String>? logs}) {
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

// ─── Filtre médian 3×3 ────────────────────────────────────────────────────────
img.Image _ppMedianFilter3x3(img.Image gray) {
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

// ─── Binarisation adaptative Sauvola ──────────────────────────────────────────
img.Image _ppAdaptiveSauvola(img.Image gray, {List<String>? logs}) {
  double kLo = 0.02, kHi = 0.80, k = 0.25;
  img.Image result = _ppSauvolaBinarize(gray, k: k);

  for (int iter = 0; iter < 4; iter++) {
    final density = _ppBlackPixelDensity(result);
    logs?.add('d:Sauvola iter=$iter k=${k.toStringAsFixed(3)} densité=${(density * 100).toStringAsFixed(1)}%');
    if (density >= 0.05 && density <= 0.30) break;
    if (density < 0.05) { kHi = k; } else { kLo = k; }
    k = (kLo + kHi) / 2.0;
    result = _ppSauvolaBinarize(gray, k: k);
  }
  return result;
}

double _ppBlackPixelDensity(img.Image binary) {
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

img.Image _ppSauvolaBinarize(img.Image gray,
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

// ─── Nettoyage par composantes connexes ───────────────────────────────────────
img.Image _ppDespeckle(img.Image binary, {int minSize = 10}) {
  final w = binary.width;
  final h = binary.height;

  final src = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      src[y * w + x] = binary.getPixel(x, y).r.toInt();
    }
  }

  final visited  = Uint8List(w * h);
  final result   = Uint8List.fromList(src);
  final stack    = <int>[];
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

// ─── Dilatation morphologique 1 px ────────────────────────────────────────────
img.Image _ppDilate(img.Image binary) {
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

// ─── Correction de déformation de page (dewarp) ───────────────────────────────
({img.Image image, List<double> stripOffsets, int stripW}) _ppDewarp(
    img.Image binary, {List<String>? logs}) {
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
    final smooth = List<int>.filled(h, 0);
    for (int y = 0; y < h; y++) {
      var s2 = 0;
      for (int dy = -2; dy <= 2; dy++) {
        s2 += proj[(y + dy).clamp(0, h - 1)];
      }
      smooth[y] = s2 ~/ 5;
    }
    final threshold = (x1 - x0) ~/ 12;
    stripPeaks.add(_ppFindProjectionPeaks(smooth, minValue: threshold, minDist: 60));
  }

  final refIdx = strips ~/ 2;
  final refPeaks = stripPeaks[refIdx];
  if (refPeaks.isEmpty) {
    logs?.add('d:Dewarp: aucune ligne de référence, pas de correction');
    return (image: binary, stripOffsets: const [], stripW: sw);
  }

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
    logs?.add('i:Dewarp: déformation négligeable (max=${maxOff.toStringAsFixed(1)}px), pas de correction');
    return (image: binary, stripOffsets: const [], stripW: sw);
  }
  logs?.add('i:Dewarp: correction appliquée — déviation max=${maxOff.toStringAsFixed(1)}px '
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

List<int> _ppFindProjectionPeaks(List<int> proj,
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

// ─── OCRService ───────────────────────────────────────────────────────────────

class OCRService {
  final logger = AppLogger.build();

  static String? _localTessdata;
  static String? _fastTextModelPath;

  /// Extrait le modèle FastText LID depuis les assets Flutter vers le répertoire
  /// de données de l'application. À appeler une fois au démarrage.
  static Future<void> initFastTextModel() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final modelFile = File(p.join(appDir.path, 'lid.176.ftz'));

      if (!await modelFile.exists()) {
        final data = await rootBundle.load('assets/models/lid.176.ftz');
        await modelFile.writeAsBytes(data.buffer.asUint8List());
      }
      _fastTextModelPath = modelFile.path;
    } catch (e) {
      // Modèle absent des assets → la détection utilisera le fallback heuristique.
      _fastTextModelPath = null;
    }
  }

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
      // Décode une fois ici pour réutilisation dans la boucle de crop
      final srcDecoded = img.decodeImage(srcBytes);
      if (srcDecoded != null) {
        // Inversion dans un isolate pour ne pas bloquer l'UI
        final invBytes = await compute(_invertImageBytes, srcBytes);
        final invPath = p.join(tempDir.path, 'inv_${DateTime.now().millisecondsSinceEpoch}.png');
        await File(invPath).writeAsBytes(invBytes);
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

        // Upscale 2× (bicubique) dans un isolate pour ne pas bloquer l'UI
        final cropBytes = Uint8List.fromList(img.encodePng(cropImage));
        final upscaledBytes = await compute(_upscaleCrop, cropBytes);

        final cropPath = p.join(
          tempDir.path,
          'crop_${rect.left.toInt()}_${rect.top.toInt()}_${DateTime.now().microsecondsSinceEpoch}.png',
        );
        await File(cropPath).writeAsBytes(upscaledBytes);
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

    // Pipeline CPU-intensif exécuté dans un isolate via compute()
    final result = await _withSimulatedProgress(
      compute(_preprocessPipeline, bytes),
      onProgress: onProgress,
      start: 0.00, end: 0.98,
      label: 'Prétraitement de l\'image…',
      expectedMs: 28000,
    );

    // Relire les logs produits dans l'isolate
    for (final msg in (result['logs'] as List).cast<String>()) {
      if (msg.startsWith('d:')) logger.d(msg.substring(2));
      else if (msg.startsWith('i:')) logger.i(msg.substring(2));
      else if (msg.startsWith('w:')) logger.w(msg.substring(2));
      else logger.i(msg);
    }

    await onProgress?.call(0.98, 'Sauvegarde image prétraitée…');
    final processedBytes = result['processedBytes'] as Uint8List;
    final outPath = p.join(tempDir.path, 'prep_${DateTime.now().millisecondsSinceEpoch}.png');
    await File(outPath).writeAsBytes(processedBytes);

    final debugDir = AppLogger.debugDir;
    if (debugDir != null) {
      final m = RegExp(r'page_(\d+)_').firstMatch(p.basename(imageFile.path));
      final name = 'prep_page_${m?.group(1) ?? DateTime.now().millisecondsSinceEpoch}.png';
      try { await File(outPath).copy(p.join(debugDir, name)); } catch (_) {}
    }

    return _PrepResult(
      file: File(outPath),
      skewAngle: result['skewAngle'] as double,
      prepWidth: result['prepWidth'] as int,
      prepHeight: result['prepHeight'] as int,
      origWidth: result['origWidth'] as int,
      origHeight: result['origHeight'] as int,
      dewarpStripOffsets: (result['dewarpStripOffsets'] as List).cast<double>(),
      dewarpStripWidth: result['dewarpStripWidth'] as int,
    );
  }

  // ─── Transformation inverse deskew + dewarp ───────────────────────────────
  Rect _inverseTransformRect(Rect r, _PrepResult prep) {
    if (!prep.hasTransform) return r;

    double cx = r.left + r.width / 2;
    double cy = r.top + r.height / 2;

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

    if (prep.skewAngle.abs() >= 0.1) {
      final angle = prep.skewAngle * pi / 180.0;
      final ca = cos(angle);
      final sa = sin(angle);
      final dw2 = prep.prepWidth / 2.0;
      final dh2 = prep.prepHeight / 2.0;
      final w2  = prep.origWidth / 2.0;
      final h2  = prep.origHeight / 2.0;
      final dx = cx - dw2;
      final dy = cy - dh2;
      cx = dx * ca + dy * sa + w2;
      cy = -dx * sa + dy * ca + h2;
    }

    return Rect.fromLTWH(cx - r.width / 2, cy - r.height / 2, r.width, r.height);
  }

  // ─── Détection de blocs ────────────────────────────────────────────────────

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
    List<String> args(String lang) => [
      imageFile.path, outputBase, '-l', lang,
      '--oem', '1', '--dpi', '$dpi', '--psm', psm,
      '-c', 'load_system_dawg=0', '-c', 'load_freq_dawg=0',
      'tsv',
    ];

    logger.d('tesseract (détection psm=$psm) ${args(tessLang).join(' ')}');
    var result = await Process.run('tesseract', args(tessLang), environment: env);
    logger.d('tesseract détection psm=$psm exit=${result.exitCode}');
    if ((result.stderr as String).isNotEmpty) logger.d('stderr: ${result.stderr}');

    if (result.exitCode != 0 && tessLang.contains('+')) {
      final baseLang = tessLang.split('+').first;
      logger.w('Tesseract: "$tessLang" indisponible, fallback vers "$baseLang"');
      result = await Process.run('tesseract', args(baseLang), environment: env);
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
    List<String> args(String lang) => [
      imageFile.path, outputBase, '-l', lang,
      '--oem', '1', '--dpi', '$dpi', '--psm', psm,
      '-c', 'load_system_dawg=0', '-c', 'load_freq_dawg=0',
      'tsv',
    ];
    logger.d('tesseract (passe2 psm=$psm dpi=$dpi scale=$scale) ${args(tessLang).join(' ')}');
    var result = await Process.run('tesseract', args(tessLang), environment: env);
    logger.d('tesseract passe2 exit=${result.exitCode}');
    if ((result.stderr as String).isNotEmpty) logger.d('tesseract passe2 stderr: ${result.stderr}');

    if (result.exitCode != 0 && tessLang.contains('+')) {
      final baseLang = tessLang.split('+').first;
      logger.w('Tesseract: "$tessLang" indisponible, fallback vers "$baseLang"');
      result = await Process.run('tesseract', args(baseLang), environment: env);
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

  // ─── Détection de langue ──────────────────────────────────────────────────────

  /// Détecte la langue dominante d'une page à partir de son image rendue.
  /// Utilise Tesseract OSD (orientation/script detection) en priorité,
  /// puis une analyse Unicode + word-frequency pour les scripts latins.
  Future<String> detectPageLanguage(File imageFile, {int dpi = 150}) async {
    final script = await _detectScript(imageFile);
    logger.d('Détection langue page: OSD script="${script}"');
    switch (script.toLowerCase()) {
      case 'japanese': return 'ja';
      case 'han': case 'chinese': case 'han_simplified':
      case 'chinese_simplified': case 'chinese_traditional': return 'zh';
      case 'korean': case 'hangul': return 'ko';
      case 'arabic': return 'ar';
      case 'cyrillic': return 'ru';
      case 'devanagari': return 'hi';
      case 'thai': return 'th';
      default:
        return await _detectByTextAnalysis(imageFile, dpi: dpi);
    }
  }

  Future<String> _detectScript(File imageFile) async {
    try {
      final env = await _tessdataEnv();
      final result = await Process.run(
        'tesseract',
        [imageFile.path, 'stdout', '--psm', '0', '-l', 'osd'],
        environment: env,
      );
      if (result.exitCode == 0) {
        final match = RegExp(r'Script:\s*(\w+)', caseSensitive: false)
            .firstMatch(result.stdout as String);
        if (match != null) return match.group(1)!;
      }
    } catch (e) {
      logger.d('OSD indisponible: $e');
    }
    return 'unknown';
  }

  Future<String> _detectByTextAnalysis(File imageFile, {int dpi = 150}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final blocks = await _runOCR(
        imageFile,
        'jpn+chi_sim+kor+rus+ara+hin+tha+eng+fra+deu+spa+ita+por+nld+pol+vie',
        tempDir,
        psm: '3', dpi: dpi,
      );
      final text = blocks.map((b) => b.text).join(' ');
      if (text.trim().isEmpty) return 'en';

      if (_fastTextModelPath != null) {
        return await _classifyWithFastText(text);
      }
      // Fallback heuristique (FastText absent ou modèle non chargé)
      final byScript = _detectScriptFromText(text);
      if (byScript != null) return byScript;
      return _matchLatinLanguage(text);
    } catch (e) {
      logger.d('Analyse texte pour détection échouée: $e');
      return 'en';
    }
  }

  /// Envoie le texte extrait au binaire `fasttext` via stdin et retourne le
  /// code BCP-47 prédit (ex. "fr", "ja"). Retourne "en" en cas d'erreur.
  Future<String> _classifyWithFastText(String text) async {
    // Nettoyer et tronquer : fasttext n'a pas besoin de plus de ~1 000 chars
    final input = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final snippet = input.length > 1000 ? input.substring(0, 1000) : input;
    if (snippet.isEmpty) return 'en';

    try {
      final process = await Process.start(
        'fasttext',
        ['predict', _fastTextModelPath!, '-'],
      );
      process.stdin.writeln(snippet);
      await process.stdin.close();

      // Drain stdout et stderr en parallèle pour éviter tout deadlock
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      process.stderr.drain<List<int>>();
      final raw = await stdoutFuture;
      await process.exitCode;

      // Sortie attendue : "__label__fr\n"
      final label = raw.trim().split('\n').first.trim();
      if (!label.startsWith('__label__')) {
        logger.w('FastText: sortie inattendue "$label"');
        return 'en';
      }
      final code = label.substring('__label__'.length).trim();
      final mapped = _mapFastTextCode(code);
      logger.d('FastText: $code → $mapped');
      return mapped;
    } catch (e) {
      logger.w('fasttext non disponible ou erreur: $e');
      // Fallback heuristique
      final byScript = _detectScriptFromText(text);
      if (byScript != null) return byScript;
      return _matchLatinLanguage(text);
    }
  }

  /// Traduit un code FastText LID vers les codes BCP-47 supportés par l'app.
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

  String? _detectScriptFromText(String text) {
    int hiraganaKatakana = 0, hangul = 0, arabic = 0, cyrillic = 0;
    int devanagari = 0, thai = 0, cjk = 0, vietnamese = 0, total = 0;
    for (final r in text.runes) {
      total++;
      if (r >= 0x3040 && r <= 0x30FF) hiraganaKatakana++;
      else if (r >= 0xAC00 && r <= 0xD7AF) hangul++;
      else if (r >= 0x0600 && r <= 0x06FF) arabic++;
      else if (r >= 0x0400 && r <= 0x04FF) cyrillic++;
      else if (r >= 0x0900 && r <= 0x097F) devanagari++;
      else if (r >= 0x0E00 && r <= 0x0E7F) thai++;
      else if (r >= 0x4E00 && r <= 0x9FFF) cjk++;
      else if ((r >= 0x1EA0 && r <= 0x1EF9) ||
               r == 0x0111 || r == 0x01A1 || r == 0x01B0) vietnamese++;
    }
    if (total == 0) return null;
    final t = total;
    if (hiraganaKatakana > 0) return 'ja';
    if (hangul / t > 0.05) return 'ko';
    if (arabic / t > 0.05) return 'ar';
    if (cyrillic / t > 0.05) return 'ru';
    if (devanagari / t > 0.05) return 'hi';
    if (thai / t > 0.05) return 'th';
    if (cjk / t > 0.05) return 'zh';
    if (vietnamese / t > 0.03) return 'vi';
    return null;
  }

  String _matchLatinLanguage(String text) {
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r"[^\w\s]"), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 2)
        .toSet();

    const markers = <String, List<String>>{
      'fr': ['le', 'la', 'les', 'de', 'du', 'des', 'est', 'une', 'pour', 'dans', 'avec', 'sur', 'au', 'par', 'ne', 'pas', 'que', 'qui', 'ce', 'se', 'un', 'et', 'il', 'on', 'en', 'son', 'sa', 'ses'],
      'de': ['der', 'die', 'das', 'und', 'ist', 'mit', 'von', 'auf', 'zu', 'ein', 'eine', 'des', 'dem', 'den', 'nicht', 'sich', 'bei', 'als', 'auch', 'werden', 'wird', 'im', 'oder', 'haben'],
      'es': ['del', 'con', 'por', 'para', 'una', 'como', 'pero', 'sobre', 'cuando', 'los', 'las', 'son', 'han', 'su', 'sus', 'ya', 'sin', 'que', 'este', 'esta'],
      'it': ['del', 'con', 'per', 'una', 'che', 'sono', 'anche', 'come', 'alla', 'agli', 'dei', 'gli', 'questo', 'questa', 'nelle', 'nella', 'dal', 'dello'],
      'pt': ['dos', 'das', 'com', 'por', 'para', 'mais', 'como', 'uma', 'este', 'essa', 'ser', 'pela', 'pelo', 'nos', 'foi', 'seu', 'sua'],
      'nl': ['het', 'een', 'van', 'op', 'met', 'voor', 'aan', 'dit', 'zijn', 'wordt', 'kan', 'worden', 'ook', 'dat', 'bij', 'heeft', 'door', 'naar', 'hun'],
      'pl': ['sie', 'nie', 'jest', 'jak', 'ale', 'czy', 'przez', 'juz', 'do', 'na', 'po', 'ze', 'tak', 'co', 'ich', 'tej', 'tym'],
      'en': ['the', 'of', 'and', 'to', 'in', 'is', 'it', 'you', 'that', 'he', 'was', 'for', 'on', 'are', 'with', 'as', 'at', 'this', 'be', 'have', 'from', 'or', 'an', 'will', 'not', 'all'],
    };

    final scores = <String, int>{};
    for (final word in words) {
      for (final entry in markers.entries) {
        if (entry.value.contains(word)) {
          scores[entry.key] = (scores[entry.key] ?? 0) + 1;
        }
      }
    }
    if (scores.isEmpty) return 'en';
    return scores.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
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
