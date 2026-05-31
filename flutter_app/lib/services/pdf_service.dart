import 'dart:io';
import 'dart:ui' show Rect;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import 'app_logger.dart';
import 'ocr_service.dart';
import 'translation_service.dart';
import '../models/processing.dart';
import '../models/language_detection.dart';

const int _renderDpi = 600;
const int _detectDpi = 150;

const double _phaseRender = 0.10;
const double _phaseOCR = 0.35;
const double _phaseWrite = 0.10;

// Fonction top-level requise par compute() : s'exécute dans un isolate séparé.
// Reçoit les données brutes d'une page, génère et retourne les bytes PDF.
const _rtlLanguages = {'ar', 'he', 'fa', 'ur'};

// Recherche binaire du plus grand corps de texte tel que le texte
// tient dans bWidth × bHeight sans déborder.
// Roboto : largeur moy. ≈ fs×0.50, interligne ≈ fs×1.30.
double _estimateFontSize(double bWidth, double bHeight, int charCount) {
  if (charCount == 0) return 10.0;
  double lo = 4.0, hi = 20.0;
  for (int i = 0; i < 12; i++) {
    final mid = (lo + hi) / 2;
    final lines = (charCount * mid * 0.50 / bWidth).ceil();
    if (lines * mid * 1.30 <= bHeight) lo = mid; else hi = mid;
  }
  return lo;
}

Future<Uint8List> _buildPagePdfBytes(Map<String, dynamic> data) async {
  final imageBytes = data['imageBytes'] as Uint8List;
  final ptWidth = data['ptWidth'] as double;
  final ptHeight = data['ptHeight'] as double;
  final blocks = (data['blocks'] as List).cast<Map<String, dynamic>>();
  final targetLanguage = data['targetLanguage'] as String? ?? 'fr';

  final isRtl = _rtlLanguages.contains(targetLanguage);
  final textAlign = isRtl ? pw.TextAlign.right : pw.TextAlign.left;

  final fontBytesRaw = data['fontBytes'] as Uint8List?;
  final font = fontBytesRaw != null
      ? pw.Font.ttf(fontBytesRaw.buffer.asByteData())
      : null;

  final pagePdf = pw.Document();
  pagePdf.addPage(pw.Page(
    pageFormat: PdfPageFormat(ptWidth, ptHeight),
    build: (pw.Context context) => pw.Stack(
      children: [
        pw.Image(pw.MemoryImage(imageBytes), fit: pw.BoxFit.contain),
        ...blocks
          .where((b) => (b['text'] as String).trim().isNotEmpty)
          .map((b) {
          final bWidth = b['width'] as double;
          final bHeight = b['height'] as double;
          final text = b['text'] as String;
          final fontSize = _estimateFontSize(bWidth, bHeight, text.length);
          return pw.Positioned(
            left: b['left'] as double,
            top: b['top'] as double,
            child: pw.ClipRect(
              child: pw.SizedBox(
                width: bWidth,
                height: bHeight,
                child: pw.Container(
                  color: PdfColors.white,
                  child: pw.Text(
                    text,
                    style: pw.TextStyle(fontSize: fontSize, color: PdfColors.black, font: font),
                    textAlign: textAlign,
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    ),
  ));

  return pagePdf.save();
}

class PDFProcessingService {
  final logger = AppLogger.build();
  final OCRService _ocrService = OCRService();
  final TranslationService _translationService = TranslationService();

  Future<void> initialize() async {
    await _translationService.initialize();
    await OCRService.initFastTextModel();
    await OCRService.initPaddleOCR();
  }

  Future<int> _getPageCount(File pdfFile) async {
    logger.d('pdfinfo "${pdfFile.path}"');
    final result = await Process.run('pdfinfo', [pdfFile.path]);
    logger.d('pdfinfo exit=${result.exitCode} stdout="${(result.stdout as String).trim()}"');
    if (result.stderr != null && (result.stderr as String).isNotEmpty) {
      logger.w('pdfinfo stderr: ${result.stderr}');
    }
    if (result.exitCode != 0) throw Exception('pdfinfo failed: ${result.stderr}');
    final match = RegExp(r'Pages:\s+(\d+)').firstMatch(result.stdout as String);
    return int.tryParse(match?.group(1) ?? '1') ?? 1;
  }

  Future<File> _renderPageToImage(File pdfFile, int pageNumber, Directory tempDir) async {
    final prefix = p.join(
      tempDir.path,
      'page_${pageNumber}_${DateTime.now().millisecondsSinceEpoch}',
    );
    final args = ['-r', '$_renderDpi', '-png', '-f', '$pageNumber', '-l', '$pageNumber', pdfFile.path, prefix];
    logger.d('pdftoppm ${args.join(' ')}');
    final result = await Process.run('pdftoppm', args);
    logger.d('pdftoppm exit=${result.exitCode}');
    if (result.stderr != null && (result.stderr as String).isNotEmpty) {
      logger.w('pdftoppm stderr: ${result.stderr}');
    }
    if (result.exitCode != 0) {
      throw Exception('pdftoppm failed on page $pageNumber: ${result.stderr}');
    }
    final files = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith(p.basename(prefix)))
        .toList();
    if (files.isEmpty) {
      throw Exception('pdftoppm: aucun fichier produit pour la page $pageNumber');
    }
    logger.d('pdftoppm → ${files.first.path}');
    return files.first;
  }

  // Détecte la langue dominante de chaque page à 150 DPI.
  // Les miniatures PNG restent sur disque jusqu'à ce que ProcessingScreen les nettoie.
  Future<List<PageLanguage>> detectPageLanguages(
    File pdfFile, {
    required Function(int current, int total) onPageDetected,
  }) async {
    final pageCount = await _getPageCount(pdfFile);
    final tempDir = await getTemporaryDirectory();
    final results = <PageLanguage>[];

    for (int i = 1; i <= pageCount; i++) {
      onPageDetected(i, pageCount);

      final prefix = p.join(
        tempDir.path,
        'thumb_${i}_${DateTime.now().millisecondsSinceEpoch}',
      );
      final renderResult = await Process.run('pdftoppm', [
        '-r', '$_detectDpi', '-png', '-f', '$i', '-l', '$i',
        pdfFile.path, prefix,
      ]);

      String? thumbnailPath;
      String detectedLang = 'en';

      if (renderResult.exitCode == 0) {
        final files = tempDir
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith(p.basename(prefix)))
            .toList();
        if (files.isNotEmpty) {
          thumbnailPath = files.first.path;
          try {
            detectedLang = await _ocrService.detectPageLanguage(
              files.first, dpi: _detectDpi,
            );
          } catch (e) {
            logger.w('Détection langue page $i échouée: $e');
          }
        }
      } else {
        logger.w('Rendu détection page $i échoué: ${renderResult.stderr}');
      }

      logger.i('Page $i: langue détectée = $detectedLang');
      results.add(PageLanguage(
        pageNumber: i,
        detectedCode: detectedLang,
        thumbnailPath: thumbnailPath,
      ));
    }

    return results;
  }

  // Émet une mise à jour de progression et cède un frame à l'event loop.
  Future<void> _emit(
    Function(ProcessingUpdate) onProgress,
    ProcessingUpdate update,
  ) async {
    onProgress(update);
    await Future.delayed(Duration.zero);
  }

  Future<String> processPDF({
    required File pdfFile,
    required List<PageLanguage> pageLanguages,
    required String targetLanguage,
    required String outputPath,
    required Function(ProcessingUpdate) onProgress,
    bool debugMode = false,
  }) async {
    final List<String> tempPagePdfs = [];
    final List<String> tempImages = [];

    try {
      AppLogger.setOutputPath(outputPath, debug: debugMode);
      logger.i('=== processPDF démarré ===');
      logger.i('  PDF source   : ${pdfFile.path}');
      logger.i('  Langues src  : ${pageLanguages.map((p) => 'p${p.pageNumber}=${p.effectiveCode}').join(', ')}');
      logger.i('  Langue cible : $targetLanguage');
      logger.i('  Sortie       : $outputPath');
      logger.i('  Exécutable   : ${Platform.resolvedExecutable}');
      logger.i('  Dart version : ${Platform.version}');

      final pageCount = await _getPageCount(pdfFile);
      logger.i('Nombre de pages: $pageCount');

      final tempDir = await getTemporaryDirectory();

      // Chargé une seule fois pour tout le document (rootBundle non accessible dans un isolate)
      final fontData = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
      final fontBytes = fontData.buffer.asUint8List();

      for (int pageIndex = 1; pageIndex <= pageCount; pageIndex++) {
        final pageLang = pageLanguages.firstWhere(
          (pl) => pl.pageNumber == pageIndex,
          orElse: () => PageLanguage(pageNumber: pageIndex, detectedCode: 'en'),
        );
        final sourceLanguage = pageLang.effectiveCode;

        // Étape 1 — Rendu
        await _emit(onProgress, ProcessingUpdate(
          currentPage: pageIndex, totalPages: pageCount,
          stepName: 'Rendu de la page en image…',
          stepProgress: 0.0,
        ));
        final renderedFile = await _renderPageToImage(pdfFile, pageIndex, tempDir);
        tempImages.add(renderedFile.path);

        // Rotation manuelle demandée par l'utilisateur (0 = aucune)
        final File imageFile;
        if (pageLang.rotation != 0) {
          imageFile = await _applyRotation(renderedFile, pageLang.rotation, tempDir);
          tempImages.add(imageFile.path);
          logger.i('Page $pageIndex: rotation ${pageLang.rotation}° CCW appliquée');
        } else {
          imageFile = renderedFile;
        }

        final imageBytes = await imageFile.readAsBytes();
        logger.i('Page $pageIndex: image rendue — ${imageBytes.length ~/ 1024} Ko, chemin: ${imageFile.path}');
        final decoded = img.decodeImage(imageBytes);
        if (decoded == null) {
          logger.e('Page $pageIndex: décodage image échoué');
          continue;
        }
        logger.i('Page $pageIndex: dimensions image — ${decoded.width}×${decoded.height} px');
        final ptWidth = decoded.width * 72.0 / _renderDpi;
        final ptHeight = decoded.height * 72.0 / _renderDpi;
        final pixelToPoint = 72.0 / _renderDpi;

        // Étape 2 — Essai texte embarqué (PDF avec couche texte) puis OCR.
        // Si l'utilisateur a appliqué une rotation, on saute le texte embarqué
        // (ses coordonnées seraient dans le repère original, pas le repère rotaté).
        final embedded = pageLang.rotation == 0
            ? await _tryEmbeddedText(pdfFile, pageIndex, _renderDpi)
            : null;
        final List<OCRTextBlock> textBlocks;
        if (embedded != null) {
          logger.i('Page $pageIndex: texte embarqué utilisé (${embedded.length} blocs pdftotext)');
          textBlocks = embedded;
          await _emit(onProgress, ProcessingUpdate(
            currentPage: pageIndex, totalPages: pageCount,
            stepName: 'Texte embarqué extrait',
            stepProgress: _phaseRender + _phaseOCR,
          ));
        } else {
          textBlocks = await _ocrService.extractTextBlocks(
            imageFile, language: sourceLanguage,
            dpi: _renderDpi,
            onProgress: (ocrFraction, ocrStep) => _emit(onProgress, ProcessingUpdate(
              currentPage: pageIndex, totalPages: pageCount,
              stepName: ocrStep,
              stepProgress: _phaseRender + ocrFraction * _phaseOCR,
            )),
          );
        }
        logger.i('Page $pageIndex: ${textBlocks.length} bloc(s) OCR après filtrage');
        for (int i = 0; i < textBlocks.length; i++) {
          final bb = textBlocks[i].boundingBox;
          logger.d('  bloc[$i] — "${textBlocks[i].text.substring(0, textBlocks[i].text.length.clamp(0, 60))}" | bb: ${bb.left.toInt()},${bb.top.toInt()} ${bb.width.toInt()}×${bb.height.toInt()}');
        }

        // Étape 3 — Traduction par lot (un subprocess par page)
        await _emit(onProgress, ProcessingUpdate(
          currentPage: pageIndex, totalPages: pageCount,
          stepName: 'Traduction (${textBlocks.length} bloc(s))…',
          stepProgress: _phaseRender + _phaseOCR,
        ));
        final translations = await _translationService.translateBatch(
          textBlocks.map((b) => b.text).toList(),
          sourceLanguage,
          targetLanguage,
        );
        final blocks = <Map<String, dynamic>>[];
        for (int i = 0; i < textBlocks.length; i++) {
          final translated = translations[i];
          if (translated.trim().isEmpty) {
            logger.w('  bloc[$i]: traduction vide, ignoré (original: "${textBlocks[i].text.substring(0, textBlocks[i].text.length.clamp(0, 40))}")');
            continue;
          }
          logger.d('  bloc[$i]: "${translated.substring(0, translated.length.clamp(0, 60))}"');
          final bb = textBlocks[i].boundingBox;
          blocks.add({
            'text': translated,
            'left': bb.left * pixelToPoint,
            'top': bb.top * pixelToPoint,
            'width': bb.width * pixelToPoint,
            'height': bb.height * pixelToPoint,
          });
        }
        logger.i('Page $pageIndex: ${blocks.length} bloc(s) traduits insérés dans le PDF');

        // Étape 4 — Génération PDF de la page dans un isolate (non bloquant)
        await _emit(onProgress, ProcessingUpdate(
          currentPage: pageIndex, totalPages: pageCount,
          stepName: 'Écriture de la page PDF…',
          stepProgress: 1.0 - _phaseWrite,
        ));
        final pdfBytes = await compute(_buildPagePdfBytes, {
          'imageBytes': imageBytes,
          'ptWidth': ptWidth,
          'ptHeight': ptHeight,
          'blocks': blocks,
          'targetLanguage': targetLanguage,
          'fontBytes': fontBytes,
        });
        final tempPagePath = p.join(tempDir.path, 'out_page_$pageIndex.pdf');
        await File(tempPagePath).writeAsBytes(pdfBytes);
        tempPagePdfs.add(tempPagePath);

        await _emit(onProgress, ProcessingUpdate(
          currentPage: pageIndex, totalPages: pageCount,
          stepName: 'Page $pageIndex écrite',
          stepProgress: 1.0,
        ));
      }

      // Assemblage final avec pdfunite
      await _emit(onProgress, ProcessingUpdate(
        currentPage: pageCount, totalPages: pageCount,
        stepName: 'Assemblage du document final…',
        stepProgress: 0.0,
        isIndeterminate: true,
      ));

      await Directory(p.dirname(outputPath)).create(recursive: true);
      logger.d('pdfunite ${[...tempPagePdfs, outputPath].join(' ')}');
      final mergeResult = await Process.run(
        'pdfunite', [...tempPagePdfs, outputPath],
      );
      logger.d('pdfunite exit=${mergeResult.exitCode}');
      if (mergeResult.stderr != null && (mergeResult.stderr as String).isNotEmpty) {
        logger.w('pdfunite stderr: ${mergeResult.stderr}');
      }
      if (mergeResult.exitCode != 0) {
        throw Exception('pdfunite failed: ${mergeResult.stderr}');
      }

      logger.i('=== Traitement terminé: $outputPath ===');
      return outputPath;
    } catch (e, st) {
      logger.e('EXCEPTION dans processPDF: $e\n$st');
      rethrow;
    } finally {
      for (final path in [...tempPagePdfs, ...tempImages]) {
        try { await File(path).delete(); } catch (_) {}
      }
    }
  }

  // Applique une rotation CCW (0/90/180/270°) à une image et écrit un nouveau fichier.
  Future<File> _applyRotation(File imageFile, int degrees, Directory tempDir) async {
    final bytes = await imageFile.readAsBytes();
    final source = img.decodeImage(bytes);
    if (source == null) return imageFile;
    final rotated = img.copyRotate(source, angle: degrees.toDouble());
    final outPath = p.join(
      tempDir.path,
      'rot${degrees}_${p.basename(imageFile.path)}',
    );
    await File(outPath).writeAsBytes(img.encodePng(rotated));
    return File(outPath);
  }

  // Tente d'extraire le texte embarqué via pdftotext -bbox.
  // Retourne null si la page n'a pas de couche texte utile (PDF scanné pur).
  // Les coordonnées pdftotext sont en points PDF (72 pt = 1 inch) ; on les
  // convertit en pixels en multipliant par (dpi / 72).
  Future<List<OCRTextBlock>?> _tryEmbeddedText(
      File pdfFile, int pageNumber, int dpi) async {
    final result = await Process.run('pdftotext', [
      '-bbox', '-f', '$pageNumber', '-l', '$pageNumber',
      pdfFile.path, '-',
    ]);
    if (result.exitCode != 0) return null;

    final blocks = _parsePdftotextBbox(result.stdout as String, dpi);
    if (blocks.isEmpty) return null;

    // Compter les caractères significatifs (lettres, chiffres, japonais)
    int meaningful = 0;
    for (final b in blocks) {
      for (final r in b.text.runes) {
        if ((r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) ||
            (r >= 0x61 && r <= 0x7A) || (r >= 0x3040 && r <= 0x9FFF)) {
          meaningful++;
        }
      }
    }
    // Seuil : au moins 20 caractères réels pour valider la couche texte
    return meaningful >= 20 ? blocks : null;
  }

  List<OCRTextBlock> _parsePdftotextBbox(String html, int dpi) {
    final scale = dpi / 72.0;
    final blocks = <OCRTextBlock>[];
    final blockRe = RegExp(
      r'<block xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</block>',
      dotAll: true,
    );
    final wordRe = RegExp(r'<word[^>]*>(.*?)</word>', dotAll: true);

    for (final bm in blockRe.allMatches(html)) {
      final x1 = double.parse(bm.group(1)!) * scale;
      final y1 = double.parse(bm.group(2)!) * scale;
      final x2 = double.parse(bm.group(3)!) * scale;
      final y2 = double.parse(bm.group(4)!) * scale;
      final words = wordRe.allMatches(bm.group(5)!)
          .map((m) => m.group(1)!.trim())
          .where((w) => w.isNotEmpty)
          .toList();
      if (words.isEmpty) continue;
      blocks.add(OCRTextBlock(
        text: words.join(' '),
        boundingBox: Rect.fromLTRB(x1, y1, x2, y2),
      ));
    }
    return blocks;
  }
}
