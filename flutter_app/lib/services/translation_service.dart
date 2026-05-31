import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// Service de traduction utilisant NLLB-200-distilled-600M (CTranslate2).
///
/// Un seul modèle couvre toutes les langues supportées — traduction directe
/// sans pivot anglais intermédiaire.
///
/// ## Codes de langue
/// Les codes internes (BCP-47 court : fr, ja, zh…) sont convertis en codes
/// NLLB (ex: fra_Latn, jpn_Jpan) avant d'appeler le script Python.
///
/// ## Stockage du modèle
///   Snap   : `$SNAP/data/flutter_assets/assets/translation_models/nllb-200-distilled-600M/`
///   Debug  : `<exe_dir>/data/flutter_assets/assets/translation_models/nllb-200-distilled-600M/`
///
/// Génération : `scripts/prepare_translation_models.sh`
class TranslationService {
  final logger = AppLogger.build();

  late String _scriptPath;
  final Map<String, String> _cache = {};

  // ============================================================================
  // CODES NLLB-200
  // ============================================================================

  /// Correspondance code interne (BCP-47 court) → code NLLB.
  static const _nllbCodes = <String, String>{
    'en': 'eng_Latn',
    'fr': 'fra_Latn',
    'es': 'spa_Latn',
    'de': 'deu_Latn',
    'it': 'ita_Latn',
    'pt': 'por_Latn',
    'nl': 'nld_Latn',
    'pl': 'pol_Latn',
    'ru': 'rus_Cyrl',
    'ja': 'jpn_Jpan',
    'zh': 'zho_Hans',
    'ko': 'kor_Hang',
    'ar': 'ara_Arab',
    'hi': 'hin_Deva',
    'th': 'tha_Thai',
    'vi': 'vie_Latn',
  };

  static const _modelDirName = 'nllb-200-distilled-600M';

  // ============================================================================
  // API STATIQUE — vérification des modèles sans instanciation
  // ============================================================================

  /// Répertoire de modèles téléchargés par l'utilisateur à l'exécution.
  /// `$XDG_DATA_HOME/pdf-ocr-translator/translation_models/`
  /// ou `~/.local/share/pdf-ocr-translator/translation_models/`
  static String? userModelsDir() {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : p.join(Platform.environment['HOME'] ?? '', '.local', 'share');
    if (!base.contains('/')) return null;
    return p.join(base, 'pdf-ocr-translator', 'translation_models');
  }

  /// Vérifie si [modelName] est disponible (téléchargé par l'utilisateur ou bundlé).
  static bool isModelDirAvailable(String modelName) {
    final userDir = userModelsDir();
    if (userDir != null &&
        File(p.join(userDir, modelName, 'model.bin')).existsSync()) {
      return true;
    }
    final snap = Platform.environment['SNAP'];
    final bundleBase = (snap != null && snap.isNotEmpty)
        ? p.join(snap, 'data', 'flutter_assets', 'assets', 'translation_models')
        : p.join(
            p.dirname(Platform.resolvedExecutable),
            'data', 'flutter_assets', 'assets', 'translation_models',
          );
    return File(p.join(bundleBase, modelName, 'model.bin')).existsSync();
  }

  /// Le seul modèle requis pour toute paire de langues est NLLB.
  static Set<String> requiredModelDirs(String from, String to) {
    if (from == to) return {};
    return {_modelDirName};
  }

  // ============================================================================
  // INITIALISATION
  // ============================================================================

  Future<void> initialize() async {
    final appDir = await getApplicationSupportDirectory();
    _scriptPath = p.join(appDir.path, 'nllb_translate.py');
    final src = await rootBundle.loadString('assets/scripts/nllb_translate.py');
    await File(_scriptPath).writeAsString(src);

    await _loadCache();
    logger.i('TranslationService initialisé | Cache: ${_cache.length} entrées | '
             'Langues supportées: ${_nllbCodes.length}');
  }

  // ============================================================================
  // API PUBLIQUE
  // ============================================================================

  /// Traduit un texte unique.
  Future<String> translateText(
    String text,
    String fromLanguage,
    String toLanguage,
  ) async {
    if (text.trim().isEmpty) return text;
    if (fromLanguage == toLanguage) return text;

    final cacheKey = _buildCacheKey(fromLanguage, toLanguage, text);
    if (_cache.containsKey(cacheKey)) {
      logger.d('Cache hit: $cacheKey');
      return _cache[cacheKey]!;
    }

    final results = await translateBatch([text], fromLanguage, toLanguage);
    _cache[cacheKey] = results.first;
    await _saveCache();
    return results.first;
  }

  /// Traduit un batch de textes en un seul appel Python.
  ///
  /// [onTranslationProgress] est appelé après chaque chunk Python avec le nombre
  /// de lignes traitées et le total. Permet d'animer une barre de progression
  /// pendant la traduction sans relancer le process.
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

  /// Vérifie si une paire de langues est supportée.
  bool isLanguagePairSupported(String from, String to) {
    if (from == to) return true;
    return _nllbCodes.containsKey(from) && _nllbCodes.containsKey(to);
  }

  /// Retourne la liste de toutes les langues supportées.
  Set<String> get supportedLanguages => Set.unmodifiable(_nllbCodes.keys);

  /// Vide le cache de traduction.
  Future<void> clearCache() async {
    _cache.clear();
    try {
      final appDir = await getApplicationSupportDirectory();
      final cacheFile = File(p.join(appDir.path, 'translation_cache.json'));
      if (await cacheFile.exists()) await cacheFile.delete();
    } catch (_) {}
    logger.i('Cache vidé');
  }

  /// Retourne la taille actuelle du cache.
  int getCacheSize() => _cache.length;

  // ============================================================================
  // TRADUCTION DIRECTE
  // ============================================================================

  Future<List<String>> _translateDirect(
    List<String> texts,
    String src,
    String tgt, {
    void Function(int done, int total)? onTranslationProgress,
  }) async {
    final srcCode = _nllbCodes[src] ?? 'eng_Latn';
    final tgtCode = _nllbCodes[tgt] ?? 'fra_Latn';
    final modelDir = _getModelDir(_modelDirName);

    if (!_isModelAvailable(_modelDirName)) {
      logger.w('Modèle NLLB non disponible');
      throw Exception('Modèle $_modelDirName introuvable');
    }

    logger.i('Traduction NLLB: $src ($srcCode) → $tgt ($tgtCode) | ${texts.length} segment(s)');
    try {
      return await _callPython(texts, modelDir, srcCode, tgtCode,
          onTranslationProgress: onTranslationProgress);
    } catch (e) {
      logger.w('Traduction $src→$tgt échouée ($e) — textes conservés.');
      return List.from(texts);
    }
  }

  // ============================================================================
  // CHEMINS DES MODÈLES
  // ============================================================================

  String _getModelDir(String modelName) {
    final userDir = userModelsDir();
    if (userDir != null) {
      final userPath = p.join(userDir, modelName);
      if (File(p.join(userPath, 'model.bin')).existsSync()) return userPath;
    }
    final snap = Platform.environment['SNAP'];
    if (snap != null && snap.isNotEmpty) {
      return p.join(snap, 'data', 'flutter_assets', 'assets', 'translation_models', modelName);
    }
    final exeDir = p.dirname(Platform.resolvedExecutable);
    return p.join(exeDir, 'data', 'flutter_assets', 'assets', 'translation_models', modelName);
  }

  bool _isModelAvailable(String modelName) => isModelDirAvailable(modelName);

  // ============================================================================
  // EXÉCUTION PYTHON
  // ============================================================================

  Future<List<String>> _callPython(
    List<String> texts,
    String modelDir,
    String srcCode,
    String tgtCode, {
    void Function(int done, int total)? onTranslationProgress,
  }) async {
    final logPrefix = '[$srcCode→$tgtCode]';
    final args = [_scriptPath, modelDir, srcCode, tgtCode];

    final env = _buildPythonEnv();
    const pythonBin = 'python3.12';
    logger.d('$logPrefix CMD: $pythonBin ${args.join(' ')}');
    logger.d('$logPrefix PYTHONPATH=${env['PYTHONPATH'] ?? '(non défini)'}');
    logger.d('$logPrefix LD_LIBRARY_PATH=${env['LD_LIBRARY_PATH'] ?? '(non défini)'}');

    final Process process;
    try {
      process = await Process.start(pythonBin, args, environment: env);
    } catch (e) {
      throw Exception('$logPrefix Impossible de démarrer $pythonBin : $e');
    }
    logger.d('$logPrefix Processus démarré (PID=${process.pid})');

    // Abonnement stderr AVANT l'écriture stdin pour éviter tout risque de
    // remplissage du pipe si Python écrit des messages au démarrage.
    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr.transform(utf8.decoder).forEach((chunk) {
      for (final line in chunk.split('\n')) {
        final l = line.trim();
        if (l.isNotEmpty) {
          logger.i('$logPrefix py: $l');
          stderrBuffer.writeln(l);
          // "PROGRESS:done/total" émis par nllb_translate.py après chaque chunk.
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

    // Envoi JSON via stdin
    final jsonStr = json.encode(texts);
    logger.d('$logPrefix stdin → ${jsonStr.length} octets (${texts.length} segments)');
    process.stdin.write(jsonStr);
    await process.stdin.close();
    logger.d('$logPrefix stdin fermé — en attente de stdout…');

    // Lecture de stdout
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final output = await stdoutFuture;
    await stderrDone;
    final exitCode = await process.exitCode;

    logger.d('$logPrefix stdout=${output.length} octets · exit=$exitCode');

    if (exitCode != 0) {
      throw Exception(
        '$logPrefix nllb_translate.py exit=$exitCode\n${stderrBuffer.toString().trim()}',
      );
    }

    final decoded = json.decode(output);
    if (decoded is! List || decoded.length != texts.length) {
      throw Exception(
        '$logPrefix réponse inattendue (longueur ${decoded is List ? decoded.length : "?"} ≠ ${texts.length})',
      );
    }

    return List<String>.from(decoded);
  }

  /// Construit l'environnement pour l'exécution Python.
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
  // GESTION DU CACHE
  // ============================================================================

  String _buildCacheKey(String from, String to, String text) {
    return '$from→$to:${text.hashCode}';
  }

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
