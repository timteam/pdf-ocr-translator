import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'app_logger.dart';

/// Graphe de pivots : pour chaque paire 'src-tgt' (BCP-47), le nom du répertoire
/// du modèle bundlé et le token de langue optionnel à préfixer aux tokens source.
///
/// Architecture : étoile centrée sur l'anglais.
///   - Toute langue source → EN  (modèles pivot)
///   - EN → toute langue cible   (modèles de sortie)
///
/// Modèles stockés dans :
///   snap  : $SNAP/data/flutter_assets/assets/translation_models/{name}/
///   debug : <exe_dir>/data/flutter_assets/assets/translation_models/{name}/
///
/// Générer les modèles avec scripts/prepare_translation_models.sh avant le build.
class TranslationService {
  final logger = AppLogger.build();

  late String _scriptPath;
  Map<String, String> _cache = {};

  // ─── Graphe des modèles ───────────────────────────────────────────────────────
  // Clé   : 'src-tgt'   (codes BCP-47)
  // Valeur : (répertoire du modèle, token de langue ou null)
  static const Map<String, (String, String?)> _modelSpec = {
    // ── Source → Anglais (pivot) ──────────────────────────────────────────────
    'ja-en': ('ja-en',      null),        // opus-mt-ja-en
    'zh-en': ('zh-en',      null),        // opus-mt-zh-en
    'ko-en': ('ko-en',      null),        // opus-mt-ko-en
    'ru-en': ('ru-en',      null),        // opus-mt-ru-en
    'ar-en': ('ar-en',      null),        // opus-mt-ar-en
    'hi-en': ('hi-en',      null),        // opus-mt-hi-en
    'th-en': ('th-en',      null),        // opus-mt-th-en
    'vi-en': ('vi-en',      null),        // opus-mt-vi-en
    'fr-en': ('ROMANCE-en', null),        // opus-mt-ROMANCE-en (fr,es,it,pt→en)
    'es-en': ('ROMANCE-en', null),
    'pt-en': ('ROMANCE-en', null),
    'it-en': ('ROMANCE-en', null),
    'de-en': ('de-en',      null),        // opus-mt-de-en
    'nl-en': ('nl-en',      null),        // opus-mt-nl-en
    'pl-en': ('pl-en',      null),        // opus-mt-pl-en

    // ── Anglais → Cible ───────────────────────────────────────────────────────
    'en-fr': ('en-ROMANCE', '>>fr<<'),    // opus-mt-en-ROMANCE (fr,es,it,pt)
    'en-es': ('en-ROMANCE', '>>es<<'),
    'en-pt': ('en-ROMANCE', '>>pt<<'),
    'en-it': ('en-ROMANCE', '>>it<<'),
    'en-de': ('en-de',      null),        // opus-mt-en-de
    'en-nl': ('en-nl',      null),        // opus-mt-en-nl
    'en-ru': ('en-ru',      null),        // opus-mt-en-ru
    'en-hi': ('en-hi',      null),        // opus-mt-en-hi
    'en-zh': ('en-zh',      '>>cmn<<'),   // opus-mt-en-zh (Mandarin)
    'en-ar': ('tc-big-en-ar','>>ara<<'),  // opus-mt-tc-big-en-ar
    'en-vi': ('en-vi',      '>>vie<<'),   // opus-mt-en-vi
    'en-ja': ('en-mul',     '>>jpn<<'),   // opus-mt-en-mul (ISO 639-3)
    'en-th': ('en-mul',     '>>tha<<'),   // opus-mt-en-mul
    'en-pl': ('en-sla',     '>>pol<<'),   // opus-mt-en-sla (langues slaves)
    'en-ko': ('tc-big-en-ko', null),      // opus-mt-tc-big-en-ko (dédié en→ko)
  };

  // ─── Initialisation ──────────────────────────────────────────────────────────

  Future<void> initialize() async {
    final appDir = await getApplicationSupportDirectory();

    _scriptPath = p.join(appDir.path, 'opusmt_translate.py');
    final src = await rootBundle.loadString('assets/scripts/opusmt_translate.py');
    await File(_scriptPath).writeAsString(src);

    await _loadCache();
    logger.i('TranslationService initialisé. Cache: ${_cache.length} entrées.');
  }

  // ─── API publique ─────────────────────────────────────────────────────────────

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

  Future<List<String>> translateBatch(
    List<String> texts,
    String fromLanguage,
    String toLanguage,
  ) async {
    if (fromLanguage == toLanguage) return texts;

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

  // ─── Chemin des modèles bundlés ───────────────────────────────────────────────

  /// Chemin vers le répertoire d'un modèle bundlé dans le snap/build Flutter.
  /// En mode snap  : $SNAP/data/flutter_assets/assets/translation_models/{name}
  /// En mode debug : <exe>/data/flutter_assets/assets/translation_models/{name}
  String _getModelDir(String modelName) {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    return p.join(
      exeDir, 'data', 'flutter_assets', 'assets', 'translation_models', modelName,
    );
  }

  bool _modelAvailable(String pair) {
    final spec = _modelSpec[pair];
    if (spec == null) return false;
    final (modelName, _) = spec;
    return File(p.join(_getModelDir(modelName), 'model.bin')).existsSync();
  }

  // ─── Logique de traduction avec pivot EN ──────────────────────────────────────

  Future<List<String>> _translateUncached(
    List<String> texts,
    String src,
    String tgt,
  ) async {
    if (src == tgt) return texts;

    // Tentative directe
    final directPair = '$src-$tgt';
    if (_modelAvailable(directPair)) {
      try {
        return await _callPython(texts, directPair);
      } catch (e) {
        logger.w('Traduction directe $src→$tgt échouée ($e). Tentative pivot.');
      }
    }

    // Pivot via l'anglais
    if (src == 'en' || tgt == 'en') {
      logger.w('Modèle $src→$tgt non disponible — textes conservés en $src.');
      return texts;
    }

    logger.i('Pivot EN : $src→en→$tgt (${texts.length} segment(s))');
    try {
      final inEnglish = await _translateUncached(texts, src, 'en');
      return await _translateUncached(inEnglish, 'en', tgt);
    } catch (e) {
      logger.w('Pivot $src→en→$tgt échoué ($e) — textes conservés en $src.');
      return texts;
    }
  }

  // ─── Subprocess Python ────────────────────────────────────────────────────────

  Future<List<String>> _callPython(List<String> texts, String pair) async {
    final (modelName, langToken) = _modelSpec[pair]!;
    final modelDir = _getModelDir(modelName);
    final logPrefix = '[$pair]';
    logger.d('$logPrefix opusmt_translate.py (${texts.length} segment(s))');

    final args = [_scriptPath, modelDir];
    if (langToken != null) args.addAll(['--token', langToken]);

    final process = await Process.start(
      'python3.12', args,
      environment: _buildPythonEnv(),
    );

    process.stdin.write(json.encode(texts));
    await process.stdin.close();

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    process.stderr.transform(utf8.decoder).forEach((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.trim().isNotEmpty) logger.w('$logPrefix stderr: $line');
      }
    });

    final output = await stdoutFuture;
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      throw Exception('opusmt_translate.py $pair: exit $exitCode');
    }

    final decoded = json.decode(output);
    if (decoded is! List || decoded.length != texts.length) {
      throw Exception(
        '$logPrefix réponse inattendue '
        '(longueur ${decoded is List ? decoded.length : "?"} ≠ ${texts.length})',
      );
    }
    return List<String>.from(decoded);
  }

  // ─── Environnement Python (pyenv snap ou venv local) ─────────────────────────

  Map<String, String> _buildPythonEnv() {
    final env = Map<String, String>.from(Platform.environment);
    if (env.containsKey('PYTHONPATH')) return env;

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final localPyenv = p.join(exeDir, 'pyenv');
    if (!Directory(localPyenv).existsSync()) return env;

    env['PYTHONPATH'] = localPyenv;

    final wheelLibDirs = [
      p.join(localPyenv, 'ctranslate2.libs'),
      p.join(localPyenv, 'numpy.libs'),
    ].where((d) => Directory(d).existsSync()).join(':');

    if (wheelLibDirs.isNotEmpty) {
      final existing = env['LD_LIBRARY_PATH'] ?? '';
      env['LD_LIBRARY_PATH'] =
          existing.isEmpty ? wheelLibDirs : '$wheelLibDirs:$existing';
    }

    return env;
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
