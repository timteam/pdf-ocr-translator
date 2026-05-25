import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'app_logger.dart';

class TranslationService {
  final logger = AppLogger.build();

  late String _modelsDir;
  late String _scriptPath;
  Map<String, String> _cache = {};

  // Paires sans modèle direct sur HuggingFace → pivot via EN
  final Set<String> _noPairModel = {};

  // ─── Initialisation ──────────────────────────────────────────────────────────

  Future<void> initialize() async {
    final appDir = await getApplicationSupportDirectory();
    _modelsDir = p.join(appDir.path, 'opus_models');
    await Directory(_modelsDir).create(recursive: true);

    // Extraire le script Python depuis les assets (mis à jour à chaque lancement)
    _scriptPath = p.join(appDir.path, 'opusmt_translate.py');
    final src = await rootBundle.loadString('assets/scripts/opusmt_translate.py');
    await File(_scriptPath).writeAsString(src);

    await _loadCache();
    logger.i('TranslationService initialisé. Cache: ${_cache.length} entrées.');
  }

  // ─── API publique ─────────────────────────────────────────────────────────────

  /// Traduit un texte unique. Utilise [translateBatch] en interne.
  Future<String> translateText(
    String text,
    String fromLanguage,
    String toLanguage,
  ) async {
    if (text.trim().isEmpty) return text;
    if (fromLanguage == toLanguage) return text;

    final cacheKey = '$fromLanguage→$toLanguage:${text.hashCode}';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    final results = await translateBatch([text], fromLanguage, toLanguage);
    final translated = results.first;
    _cache[cacheKey] = translated;
    await _saveCache();
    return translated;
  }

  /// Traduit une liste de textes en un seul appel Python (un subprocess par paire).
  Future<List<String>> translateBatch(
    List<String> texts,
    String fromLanguage,
    String toLanguage,
  ) async {
    if (fromLanguage == toLanguage) return texts;

    // Résoudre le cache : ne soumettre que les textes non encore traduits
    final results = List<String?>.filled(texts.length, null);
    final uncachedIdx = <int>[];
    for (var i = 0; i < texts.length; i++) {
      final key = '$fromLanguage→$toLanguage:${texts[i].hashCode}';
      results[i] = _cache[key];
      if (results[i] == null) uncachedIdx.add(i);
    }

    if (uncachedIdx.isNotEmpty) {
      final uncached = uncachedIdx.map((i) => texts[i]).toList();
      final translated = await _translateUncached(uncached, fromLanguage, toLanguage);
      for (var j = 0; j < uncachedIdx.length; j++) {
        final i = uncachedIdx[j];
        results[i] = translated[j];
        _cache['$fromLanguage→$toLanguage:${texts[i].hashCode}'] = translated[j];
      }
      await _saveCache();
    }

    return results.map((t) => t ?? '').toList();
  }

  Future<void> clearCache() async {
    _cache.clear();
    try {
      final appDir = await getApplicationSupportDirectory();
      final f = File(p.join(appDir.path, 'translation_cache.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
    logger.i('Cache vidé');
  }

  int getCacheSize() => _cache.length;

  // ─── Logique de traduction ────────────────────────────────────────────────────

  Future<List<String>> _translateUncached(
    List<String> texts,
    String src,
    String tgt,
  ) async {
    // Essai paire directe
    if (await _ensureModel(src, tgt)) {
      return _callPython(texts, src, tgt);
    }

    // Pivot via l'anglais
    if (src == 'en' || tgt == 'en') {
      throw Exception(
        'Modèle opus-mt-tc-tiny-$src-$tgt introuvable sur HuggingFace '
        '(aucun pivot possible sans anglais).',
      );
    }
    logger.i('Pivot EN: $src→en→$tgt (${texts.length} texte(s))');
    final inEnglish = await _translateUncached(texts, src, 'en');
    return _translateUncached(inEnglish, 'en', tgt);
  }

  // ─── Gestion des modèles ──────────────────────────────────────────────────────

  String _modelDir(String src, String tgt) =>
      p.join(_modelsDir, 'opus-mt-tc-tiny-$src-$tgt');

  Future<bool> _ensureModel(String src, String tgt) async {
    if (_noPairModel.contains('$src-$tgt')) return false;
    if (await File(p.join(_modelDir(src, tgt), 'model.bin')).exists()) return true;
    return _downloadModel(src, tgt);
  }

  Future<bool> _downloadModel(String src, String tgt) async {
    final dir = _modelDir(src, tgt);
    final base = 'https://huggingface.co/Helsinki-NLP/opus-mt-tc-tiny-$src-$tgt/resolve/main';

    await Directory(dir).create(recursive: true);
    logger.i('Téléchargement opus-mt-tc-tiny-$src-$tgt…');

    try {
      // Fichiers obligatoires
      for (final file in ['model.bin', 'shared_vocabulary.json']) {
        if (!await _curl('$base/$file', p.join(dir, file))) {
          throw Exception('Fichier requis absent: $file');
        }
      }
      // Modèles SentencePiece (au moins un requis)
      var gotSpm = false;
      for (final file in ['source.spm', 'target.spm', 'sentencepiece.bpe.model']) {
        if (await _curl('$base/$file', p.join(dir, file))) gotSpm = true;
      }
      if (!gotSpm) throw Exception('Aucun modèle SentencePiece disponible');

      logger.i('Modèle opus-mt-tc-tiny-$src-$tgt prêt (${await _dirSizeMb(dir)} MB).');
      return true;
    } catch (e) {
      logger.w('Pas de modèle direct $src→$tgt: $e');
      await Directory(dir).delete(recursive: true).catchError((_) => Directory(dir));
      _noPairModel.add('$src-$tgt');
      return false;
    }
  }

  Future<bool> _curl(String url, String dest) async {
    final r = await Process.run('curl', ['-L', '--fail', '-s', '-o', dest, url]);
    if (r.exitCode != 0) return false;
    final size = await File(dest).length().catchError((_) => 0);
    return size > 100; // sanity check : un fichier vide n'est pas un modèle valide
  }

  Future<String> _dirSizeMb(String dir) async {
    final r = await Process.run('du', ['-sh', dir]);
    return (r.stdout as String).split('\t').first.trim();
  }

  // ─── Subprocess Python ────────────────────────────────────────────────────────

  Future<List<String>> _callPython(
    List<String> texts,
    String src,
    String tgt,
  ) async {
    final modelDir = _modelDir(src, tgt);
    final logPrefix = '[$src→$tgt]';
    logger.d('$logPrefix appel opusmt_translate.py (${texts.length} texte(s))');

    final process = await Process.start('python3', [_scriptPath, modelDir]);

    process.stdin.write(json.encode(texts));
    await process.stdin.close();

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    // Drain stderr et loguer
    process.stderr.transform(utf8.decoder).forEach((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.trim().isNotEmpty) logger.w('$logPrefix stderr: $line');
      }
    });

    final output = await stdoutFuture;
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      throw Exception('opusmt_translate.py $src→$tgt: exit code $exitCode');
    }

    final decoded = json.decode(output);
    if (decoded is! List || decoded.length != texts.length) {
      throw Exception(
        '$logPrefix réponse inattendue (longueur ${decoded.length} ≠ ${texts.length})',
      );
    }
    return List<String>.from(decoded);
  }

  // ─── Cache persistant ─────────────────────────────────────────────────────────

  Future<void> _loadCache() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final f = File(p.join(appDir.path, 'translation_cache.json'));
      if (await f.exists()) {
        final data = json.decode(await f.readAsString()) as Map<String, dynamic>;
        _cache = Map<String, String>.from(data);
        logger.i('Cache chargé : ${_cache.length} entrées');
      }
    } catch (e) {
      logger.e('Chargement cache échoué : $e');
    }
  }

  Future<void> _saveCache() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final f = File(p.join(appDir.path, 'translation_cache.json'));
      await f.writeAsString(json.encode(_cache));
    } catch (e) {
      logger.e('Sauvegarde cache échouée : $e');
    }
  }
}
