import 'dart:io';
import 'dart:math';
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

const int _renderDpi = 300;

const double _phaseRender = 0.10;
const double _phaseOCR = 0.35;
const double _phaseTranslate = 0.45;
const double _phaseWrite = 0.10;

// Fonction top-level requise par compute() : s'exécute dans un isolate séparé.
// Reçoit les données brutes d'une page, génère et retourne les bytes PDF.
const _rtlLanguages = {'ar', 'he', 'fa', 'ur'};

// Taille de police proportionnelle à la surface du bloc original.
// Cible : le texte traduit couvre la même aire que le texte source.
double _estimateFontSize(double bWidth, double bHeight, int charCount) {
  if (charCount == 0) return 10.0;
  final fs = sqrt(bWidth * bHeight / (charCount * 0.7));
  return fs.clamp(7.0, 16.0);
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
            child: pw.Container(
              width: bWidth,
              color: PdfColors.white,
              child: pw.Text(
                text,
                style: pw.TextStyle(fontSize: fontSize, color: PdfColors.black, font: font),
                textAlign: textAlign,
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
    required String sourceLanguage,
    required String targetLanguage,
    required String outputPath,
    required Function(ProcessingUpdate) onProgress,
  }) async {
    final List<String> tempPagePdfs = [];
    final List<String> tempImages = [];

    try {
      AppLogger.setOutputPath(outputPath);
      logger.i('=== processPDF démarré ===');
      logger.i('  PDF source   : ${pdfFile.path}');
      logger.i('  Langue src   : $sourceLanguage');
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
        // Étape 1 — Rendu
        await _emit(onProgress, ProcessingUpdate(
          currentPage: pageIndex, totalPages: pageCount,
          stepName: 'Rendu de la page en image…',
          stepProgress: 0.0,
        ));
        final imageFile = await _renderPageToImage(pdfFile, pageIndex, tempDir);
        tempImages.add(imageFile.path);

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

        // Étape 2 — OCR (progress émis depuis l'intérieur de extractTextBlocks)
        final textBlocks = await _ocrService.extractTextBlocks(
          imageFile, language: sourceLanguage,
          onProgress: (ocrFraction, ocrStep) => _emit(onProgress, ProcessingUpdate(
            currentPage: pageIndex, totalPages: pageCount,
            stepName: ocrStep,
            stepProgress: _phaseRender + ocrFraction * _phaseOCR,
          )),
        );
        logger.i('Page $pageIndex: ${textBlocks.length} bloc(s) OCR après filtrage');
        for (int i = 0; i < textBlocks.length; i++) {
          final bb = textBlocks[i].boundingBox;
          logger.d('  bloc[$i] — "${textBlocks[i].text.substring(0, textBlocks[i].text.length.clamp(0, 60))}" | bb: ${bb.left.toInt()},${bb.top.toInt()} ${bb.width.toInt()}×${bb.height.toInt()}');
        }

        // Étape 3 — Traduction par bloc
        final blocks = <Map<String, dynamic>>[];
        final blockCount = max(1, textBlocks.length);
        for (int i = 0; i < textBlocks.length; i++) {
          await _emit(onProgress, ProcessingUpdate(
            currentPage: pageIndex, totalPages: pageCount,
            stepName: 'Traduction du bloc de texte (${i + 1}/$blockCount)…',
            stepProgress: _phaseRender + _phaseOCR + _phaseTranslate * i / blockCount,
          ));
          final translated = await _translationService.translateText(
            textBlocks[i].text, sourceLanguage, targetLanguage,
          );
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
}
