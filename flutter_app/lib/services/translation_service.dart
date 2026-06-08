import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// Service de traduction utilisant des modèles Opus-MT (format Argos/CTranslate2).
///
/// Architecture : pivot via l'anglais.
///   - src == tgt          → pas de traduction
///   - src == 'en'         → modèle direct  en-{tgt}
///   - tgt == 'en'         → modèle direct  {src}-en
///   - sinon               → deux modèles : {src}-en  puis  en-{tgt}
///
/// ## Nommage des répertoires de modèles
///   `{src}-{tgt}` — ex : `ja-en`, `en-fr`, `ru-en`
///
/// ## Structure attendue dans chaque répertoire
///   `model/model.bin`           — modèle CTranslate2
///   `sentencepiece.model`       — tokenizer partagé source+cible
///
/// ## Stockage des modèles
///   Snap  : `$SNAP/data/flutter_assets/assets/translation_models/{src}-{tgt}/`
///   Debug : `<exe_dir>/data/flutter_assets/assets/translation_models/{src}-{tgt}/`
///   User  : `$XDG_DATA_HOME/pdf-ocr-translator/translation_models/{src}-{tgt}/`
class TranslationService {
  final logger = AppLogger.build();

  late String _scriptPath;
  final Map<String, String> _cache = {};

  // Incrémenter quand le script Python ou le format de modèle change.
  static const _cacheVersion = 'v5';

  // ============================================================================
  // API STATIQUE — vérification des modèles sans instanciation
  // ============================================================================

  static String? userModelsDir() {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : p.join(Platform.environment['HOME'] ?? '', '.local', 'share');
    if (!base.contains('/')) return null;
    return p.join(base, 'pdf-ocr-translator', 'translation_models');
  }

  /// Retourne les répertoires de modèles nécessaires pour traduire [src]→[tgt].
  /// 1 répertoire = traduction directe ; 2 = pivot via anglais.
  static Set<String> requiredModelDirs(String src, String tgt) {
    if (src == tgt) return {};
    if (src == 'en') return {'en-$tgt'};
    if (tgt == 'en') return {'$src-en'};
    return {'$src-en', 'en-$tgt'};
  }

  /// Vérifie si [modelDirName] contient un modèle valide.
  static bool isModelDirAvailable(String modelDirName) {
    // Cherche d'abord dans le répertoire utilisateur, puis dans le snap/bundle.
    final userDir = userModelsDir();
    if (userDir != null) {
      final userBin = File(p.join(userDir, modelDirName, 'model', 'model.bin'));
      if (userBin.existsSync()) return true;
    }
    final snap = Platform.environment['SNAP'];
    final bundleBase = (snap != null && snap.isNotEmpty)
        ? p.join(snap, 'data', 'flutter_assets', 'assets', 'translation_models')
        : p.join(
            p.dirname(Platform.resolvedExecutable),
            'data', 'flutter_assets', 'assets', 'translation_models',
          );
    return File(p.join(bundleBase, modelDirName, 'model', 'model.bin')).existsSync();
  }

  // ============================================================================
  // INITIALISATION
  // ============================================================================

  Future<void> initialize() async {
    final appDir = await getApplicationSupportDirectory();
    _scriptPath = p.join(appDir.path, 'opusmt_translate.py');
    final src = await rootBundle.loadString('assets/scripts/opusmt_translate.py');
    await File(_scriptPath).writeAsString(src);


    await _loadCache();
    logger.i('TranslationService initialisé | Cache: ${_cache.length} entrées');
  }

  // ============================================================================
  // API PUBLIQUE
  // ============================================================================

  Future<String> translateText(
    String text,
    String fromLanguage,
    String toLanguage,
  ) async {
    if (text.trim().isEmpty) return text;
    if (fromLanguage == toLanguage) return text;
    final key = _buildCacheKey(fromLanguage, toLanguage, text);
    if (_cache.containsKey(key)) return _cache[key]!;
    final results = await translateBatch([text], fromLanguage, toLanguage);
    _cache[key] = results.first;
    await _saveCache();
    return results.first;
  }

  /// Traduit un batch de textes via un ou deux modèles Opus-MT.
  ///
  /// [onTranslationProgress] est appelé après chaque chunk Python
  /// avec le nombre de lignes traitées et le total (inclut les deux étapes).
  Future<List<String>> translateBatch(
    List<String> texts,
    String fromLanguage,
    String toLanguage, {
    void Function(int done, int total)? onTranslationProgress,
  }) async {
    if (fromLanguage == toLanguage) return List.from(texts);
    if (texts.isEmpty) return [];

    final results = List<String?>.filled(texts.length, null);
    final uncachedIndices = <int>[];

    for (var i = 0; i < texts.length; i++) {
      final key = _buildCacheKey(fromLanguage, toLanguage, texts[i]);
      results[i] = _cache[key];
      if (results[i] == null) uncachedIndices.add(i);
    }

    if (uncachedIndices.isNotEmpty) {
      final uncachedTexts = uncachedIndices.map((i) => texts[i]).toList();
      final translated = await _translateDirect(
        uncachedTexts,
        fromLanguage,
        toLanguage,
        onTranslationProgress: onTranslationProgress,
      );
      for (var j = 0; j < uncachedIndices.length; j++) {
        final i = uncachedIndices[j];
        results[i] = translated[j];
        _cache[_buildCacheKey(fromLanguage, toLanguage, texts[i])] = translated[j];
      }
      await _saveCache();
    }

    return results.map((t) => t ?? '').toList();
  }

  bool isLanguagePairSupported(String from, String to) {
    if (from == to) return true;
    return requiredModelDirs(from, to).every(isModelDirAvailable);
  }

  Future<void> clearCache() async {
    _cache.clear();
    try {
      final appDir = await getApplicationSupportDirectory();
      final cacheFile = File(p.join(appDir.path, 'translation_cache.json'));
      if (await cacheFile.exists()) await cacheFile.delete();
    } catch (_) {}
    logger.i('Cache vidé');
  }

  int getCacheSize() => _cache.length;

  // ============================================================================
  // TRADUCTION INTERNE
  // ============================================================================

  Future<List<String>> _translateDirect(
    List<String> texts,
    String src,
    String tgt, {
    void Function(int done, int total)? onTranslationProgress,
  }) async {
    final dirs = requiredModelDirs(src, tgt);
    if (dirs.isEmpty) return List.from(texts);

    // Vérifie que tous les modèles requis sont présents.
    final missing = dirs.where((d) => !isModelDirAvailable(d)).toList();
    if (missing.isNotEmpty) {
      logger.w('Modèles manquants : ${missing.join(", ")}');
      throw Exception('Modèles introuvables : ${missing.join(", ")}');
    }

    final pivot = src != 'en' && tgt != 'en';
    logger.i('Traduction $src→$tgt | ${pivot ? "pivot en" : "direct"} | ${texts.length} seg');

    // Ordre : si pivot, passer src-en en premier puis en-tgt.
    final orderedDirs = pivot
        ? ['$src-en', 'en-$tgt']
        : [dirs.first];

    final modelPaths = orderedDirs.map(_getModelDir).toList();

    try {
      return await _callPython(texts, modelPaths,
          onTranslationProgress: onTranslationProgress);
    } catch (e) {
      logger.w('Traduction $src→$tgt échouée ($e) — textes conservés.');
      return List.from(texts);
    }
  }

  // ============================================================================
  // CHEMINS DES MODÈLES
  // ============================================================================

  String _getModelDir(String modelDirName) {
    final userDir = userModelsDir();
    if (userDir != null) {
      final userPath = p.join(userDir, modelDirName);
      if (File(p.join(userPath, 'model', 'model.bin')).existsSync()) return userPath;
    }
    final snap = Platform.environment['SNAP'];
    if (snap != null && snap.isNotEmpty) {
      return p.join(
          snap, 'data', 'flutter_assets', 'assets', 'translation_models', modelDirName);
    }
    return p.join(
      p.dirname(Platform.resolvedExecutable),
      'data', 'flutter_assets', 'assets', 'translation_models', modelDirName,
    );
  }

  // ============================================================================
  // EXÉCUTION PYTHON
  // ============================================================================

  Future<List<String>> _callPython(
    List<String> texts,
    List<String> modelDirs, {
    void Function(int done, int total)? onTranslationProgress,
  }) async {
    final logPrefix = '[${modelDirs.map(p.basename).join("+")}]';
    final args = [_scriptPath, ...modelDirs];

    final env = _buildPythonEnv();
    const pythonBin = 'python3.12';
    logger.d('$logPrefix CMD: $pythonBin ${args.join(' ')}');

    final Process process;
    try {
      process = await Process.start(pythonBin, args, environment: env);
    } catch (e) {
      throw Exception('$logPrefix Impossible de démarrer $pythonBin : $e');
    }
    logger.d('$logPrefix PID=${process.pid}');

    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr.transform(utf8.decoder).forEach((chunk) {
      for (final line in chunk.split('\n')) {
        final l = line.trim();
        if (l.isNotEmpty) {
          logger.i('$logPrefix py: $l');
          stderrBuffer.writeln(l);
          // Parse PROGRESS:done/total émis par opusmt_translate.py après chaque chunk.
          if (l.startsWith('PROGRESS:')) {
            final rest = l.substring(9);
            final slash = rest.indexOf('/');
            if (slash > 0) {
              final done = int.tryParse(rest.substring(0, slash));
              final total = int.tryParse(rest.substring(slash + 1));
              if (done != null && total != null) {
                onTranslationProgress?.call(done, total);
              }
            }
          }
        }
      }
    });

    final jsonStr = json.encode(texts);
    logger.d('$logPrefix stdin → ${jsonStr.length} octets (${texts.length} seg)');
    process.stdin.write(jsonStr);
    await process.stdin.close();

    final output = await process.stdout.transform(utf8.decoder).join();
    await stderrDone;
    final exitCode = await process.exitCode;

    logger.d('$logPrefix stdout=${output.length} oct · exit=$exitCode');

    if (exitCode != 0) {
      throw Exception(
        '$logPrefix opusmt_translate.py exit=$exitCode\n${stderrBuffer.toString().trim()}',
      );
    }

    final decoded = json.decode(output);
    if (decoded is! List || decoded.length != texts.length) {
      throw Exception(
        '$logPrefix réponse inattendue (${decoded is List ? decoded.length : "?"} ≠ ${texts.length})',
      );
    }

    return List<String>.from(decoded);
  }

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

  // ============================================================================
  // CACHE
  // ============================================================================

  String _buildCacheKey(String from, String to, String text) =>
      '$_cacheVersion:$from→$to:${text.hashCode}';

  Future<void> _loadCache() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final cacheFile = File(p.join(appDir.path, 'translation_cache.json'));
      if (await cacheFile.exists()) {
        final data = json.decode(await cacheFile.readAsString())
            as Map<String, dynamic>;
        _cache.addAll(Map<String, String>.from(data));
        logger.i('Cache chargé: ${_cache.length} entrées');
      }
    } catch (e) {
      logger.e('Chargement cache échoué: $e');
    }
  }

  Future<void> _saveCache() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final cacheFile = File(p.join(appDir.path, 'translation_cache.json'));
      await cacheFile.writeAsString(json.encode(_cache));
    } catch (e) {
      logger.e('Sauvegarde cache échouée: $e');
    }
  }
}
