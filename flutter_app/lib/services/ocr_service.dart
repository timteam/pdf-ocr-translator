import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:logger/logger.dart';

class OCRService {
  final logger = Logger();

  static const Map<String, String> _langMap = {
    'en': 'eng', 'fr': 'fra', 'es': 'spa', 'de': 'deu',
    'it': 'ita', 'pt': 'por', 'nl': 'nld', 'pl': 'pol',
    'ru': 'rus', 'ja': 'jpn', 'zh': 'chi_sim', 'ko': 'kor',
    'ar': 'ara', 'hi': 'hin', 'th': 'tha', 'vi': 'vie',
  };

  String _toTesseractLang(String bcp47) => _langMap[bcp47] ?? 'eng';

  Future<List<OCRTextBlock>> extractTextBlocks(
    File imageFile, {
    String language = 'en',
  }) async {
    final tessLang = _toTesseractLang(language);
    final tempDir = await getTemporaryDirectory();
    final ownTempFiles = <String>[];

    try {
      // Étape 1 : prétraitement
      final preprocessed = await _preprocessImage(imageFile, tempDir);
      ownTempFiles.add(preprocessed.path);

      // Étape 2 : passe 1 — détection des régions (niveau 2 = blocs)
      final blockRects = await _detectBlockRects(preprocessed, tessLang, tempDir);
      logger.i('Régions détectées: ${blockRects.length}');

      if (blockRects.isEmpty) {
        // Fallback : OCR pleine page avec layout automatique
        return await _runOCR(preprocessed, tessLang, tempDir, psm: '3');
      }

      // Pré-décode l'image une seule fois pour tous les recadrages
      final srcDecoded = img.decodeImage(await preprocessed.readAsBytes());

      // Étape 3 : passe 2 — OCR par région indépendante (--psm 6)
      final result = <OCRTextBlock>[];
      for (final rect in blockRects) {
        if (srcDecoded == null) break;
        final crop = _cropRegion(srcDecoded, rect);
        if (crop == null) continue;

        final cropPath = p.join(
          tempDir.path,
          'crop_${rect.left.toInt()}_${rect.top.toInt()}_${DateTime.now().microsecondsSinceEpoch}.png',
        );
        await File(cropPath).writeAsBytes(img.encodePng(crop.image));
        ownTempFiles.add(cropPath);

        final blocks = await _runOCR(
          File(cropPath), tessLang, tempDir,
          psm: '6',
          offsetX: crop.originX,
          offsetY: crop.originY,
        );
        result.addAll(blocks);
      }

      return result;
    } finally {
      for (final path in ownTempFiles) {
        try { await File(path).delete(); } catch (_) {}
      }
    }
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
    final result = await Process.run('tesseract', [
      imageFile.path, outputBase, '-l', tessLang, 'tsv',
    ]);

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
    final result = await Process.run('tesseract', [
      imageFile.path, outputBase, '-l', tessLang, '--psm', psm, 'tsv',
    ]);

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
    if (lines.length < 2) return [];

    final Map<String, _ParagraphGroup> groups = {};

    for (final line in lines.skip(1)) {
      final parts = line.split('\t');
      if (parts.length < 12) continue;

      final level = int.tryParse(parts[0]) ?? 0;
      if (level != 5) continue; // niveau 5 = mots

      final pageNum  = parts[1];
      final blockNum = parts[2];
      final parNum   = parts[3];
      final left   = (double.tryParse(parts[6]) ?? 0) + offsetX;
      final top    = (double.tryParse(parts[7]) ?? 0) + offsetY;
      final width  = double.tryParse(parts[8]) ?? 0;
      final height = double.tryParse(parts[9]) ?? 0;
      final conf   = double.tryParse(parts[10]) ?? -1;
      final text   = parts[11].trim();

      if (conf < 50 || text.isEmpty) continue;

      final key = '$pageNum-$blockNum-$parNum';
      groups.putIfAbsent(key, () => _ParagraphGroup());
      groups[key]!.addWord(text, conf, left, top, left + width, top + height);
    }

    return groups.values
        .where((g) => g.words.isNotEmpty)
        .where((g) => g.avgConf >= 40)
        .where((g) => g.bbox.width >= 20 && g.bbox.height >= 10)
        .where((g) => !_isGarbageText(g.text))
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
