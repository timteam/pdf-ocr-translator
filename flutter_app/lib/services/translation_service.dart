import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// Service de traduction utilisant un graphe de pivots pour le routage automatique.
///
/// # Architecture du graphe
///
/// Le graphe est structuré en étoile avec l'anglais (en) comme pivot central :
///
///   Source → Anglais → Cible
///
/// ## Nœuds du graphe
/// - Chaque nœud représente une langue (code BCP-47 : fr, en, ja, zh, etc.)
/// - Chaque arête représente un modèle de traduction disponible
///
/// ## Routage automatique
/// Pour traduire de A vers B :
/// 1. Si modèle A→B existe : traduction directe
/// 2. Sinon, si A→en et en→B existent : pivot via anglais
/// 3. Sinon, impossible (retourne texte original)
///
/// ## Stockage des modèles
/// Modèles bundlés dans :
///   - Snap   : `$SNAP/data/flutter_assets/assets/translation_models/`
///   - Debug  : `<exe_dir>/data/flutter_assets/assets/translation_models/`
///
/// Génération : `scripts/prepare_translation_models.sh`
class TranslationService {
  final logger = AppLogger.build();

  late String _scriptPath;
  final Map<String, String> _cache = {};

  // ============================================================================
  // GRAPHE DE PIVOTS
  // ============================================================================

  /// Modèles de traduction disponibles, organisés par type.
  ///
  /// Structure : {
  ///   'src-tgt': (répertoire_du_modèle, token_de_langue_optionnel)
  /// }
  ///
  /// Le token de langue est préfixé aux tokens source pour les modèles
  /// multi-langues (ex: ROMANCE, mul, sla).
  static const _modelGraph = <String, (String, String?)>{
    // ========================================================================
    // PIVOT ENTRANT : Source → Anglais
    // ========================================================================

    // Modèles OPUS-MT dédiés
    'ja-en': ('ja-en', null),           // Japonais → Anglais
    'zh-en': ('zh-en', null),           // Chinois → Anglais
    'ko-en': ('ko-en', null),           // Coréen → Anglais
    'ru-en': ('ru-en', null),           // Russe → Anglais
    'ar-en': ('ar-en', null),           // Arabe → Anglais
    'hi-en': ('hi-en', null),           // Hindi → Anglais
    'th-en': ('th-en', null),           // Thaï → Anglais
    'vi-en': ('vi-en', null),           // Vietnamien → Anglais
    'de-en': ('de-en', null),           // Allemand → Anglais
    'nl-en': ('nl-en', null),           // Néerlandais → Anglais
    'pl-en': ('pl-en', null),           // Polonais → Anglais

    // Modèles groupés par famille linguistique
    'fr-en': ('ROMANCE-en', null),      // Français → Anglais (famille ROMANCE)
    'es-en': ('ROMANCE-en', null),      // Espagnol → Anglais
    'pt-en': ('ROMANCE-en', null),      // Portugais → Anglais
    'it-en': ('ROMANCE-en', null),      // Italien → Anglais

    // ========================================================================
    // PIVOT SORTANT : Anglais → Cible
    // ========================================================================

    // Familles linguistiques (multi-langues)
    'en-fr': ('en-ROMANCE', '>>fr<<'),   // Anglais → Français (ROMANCE)
    'en-es': ('en-ROMANCE', '>>es<<'),   // Anglais → Espagnol
    'en-pt': ('en-ROMANCE', '>>pt<<'),   // Anglais → Portugais
    'en-it': ('en-ROMANCE', '>>it<<'),   // Anglais → Italien

    'en-zh': ('en-zh', '>>cmn<<'),      // Anglais → Chinois (Mandarin)
    'en-ar': ('tc-big-en-ar', '>>ara<<'), // Anglais → Arabe (TC-Big)
    'en-vi': ('en-vi', '>>vie<<'),       // Anglais → Vietnamien
    'en-ja': ('en-mul', '>>jpn<<'),      // Anglais → Japonais (multi)
    'en-th': ('en-mul', '>>tha<<'),      // Anglais → Thaï (multi)
    'en-ko': ('tc-big-en-ko', null),     // Anglais → Coréen (TC-Big dédié)
    'en-pl': ('en-sla', '>>pol<<'),      // Anglais → Polonais (langues slaves)

    // Modèles OPUS-MT dédiés
    'en-de': ('en-de', null),            // Anglais → Allemand
    'en-nl': ('en-nl', null),            // Anglais → Néerlandais
    'en-ru': ('en-ru', null),            // Anglais → Russe
    'en-hi': ('en-hi', null),            // Anglais → Hindi
  };

  /// Ensemble de toutes les langues supportées (extrait du graphe).
  static final _supportedLanguages = _modelGraph.keys
      .expand((pair) => pair.split('-'))
      .toSet()
    ..add('en'); // Anglais toujours supporté

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

  /// Noms des répertoires de modèles requis pour traduire [from] → [to].
  /// Utilise la même logique que [_findPath] mais de façon statique.
  static Set<String> requiredModelDirs(String from, String to) {
    if (from == to) return {};
    if (_modelGraph.containsKey('$from-$to')) {
      return {_modelGraph['$from-$to']!.$1};
    }
    final result = <String>{};
    if (from != 'en' && to != 'en') {
      final incoming = _modelGraph['$from-en'];
      final outgoing = _modelGraph['en-$to'];
      if (incoming != null) result.add(incoming.$1);
      if (outgoing != null) result.add(outgoing.$1);
    }
    return result;
  }

  // ============================================================================
  // INITIALISATION
  // ============================================================================

  Future<void> initialize() async {
    final appDir = await getApplicationSupportDirectory();

    // Copie du script Python pour l'exécution
    _scriptPath = p.join(appDir.path, 'opusmt_translate.py');
    final src = await rootBundle.loadString('assets/scripts/opusmt_translate.py');
    await File(_scriptPath).writeAsString(src);

    await _loadCache();
    logger.i('TranslationService initialisé | Cache: ${_cache.length} entrées | '
             'Langues supportées: ${_supportedLanguages.length}');
  }

  // ============================================================================
  // API PUBLIQUE
  // ============================================================================

  /// Traduit un texte unique.
  ///
  /// Utilise le cache si disponible, sinon appelle la traduction.
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
    final translated = results.first;
    _cache[cacheKey] = translated;
    await _saveCache();
    return translated;
  }

  /// Traduit un batch de textes.
  ///
  /// Optimise en groupant les traductions et en utilisant le cache.
  Future<List<String>> translateBatch(
    List<String> texts,
    String fromLanguage,
    String toLanguage,
  ) async {
    if (fromLanguage == toLanguage) return List.from(texts);
    if (texts.isEmpty) return [];

    final results = List<String?>.filled(texts.length, null);
    final uncachedIndices = <int>[];

    // Séparation cache / non-cache
    for (var i = 0; i < texts.length; i++) {
      final key = _buildCacheKey(fromLanguage, toLanguage, texts[i]);
      results[i] = _cache[key];
      if (results[i] == null) uncachedIndices.add(i);
    }

    // Traduction des entrées non en cache
    if (uncachedIndices.isNotEmpty) {
      final uncachedTexts = uncachedIndices.map((i) => texts[i]).toList();
      final translated = await _translateWithGraph(
        uncachedTexts,
        fromLanguage,
        toLanguage,
      );

      for (var j = 0; j < uncachedIndices.length; j++) {
        final i = uncachedIndices[j];
        results[i] = translated[j];
        final key = _buildCacheKey(fromLanguage, toLanguage, texts[i]);
        _cache[key] = translated[j];
      }
      await _saveCache();
    }

    return results.map((t) => t ?? '').toList();
  }

  /// Vérifie si une paire de langues est supportée.
  bool isLanguagePairSupported(String from, String to) {
    if (from == to) return true;
    return _modelGraph.containsKey('$from-$to');
  }

  /// Retourne la liste de toutes les langues supportées.
  Set<String> get supportedLanguages => Set.unmodifiable(_supportedLanguages);

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
  // ROUTAGE VIA GRAPHE DE PIVOTS
  // ============================================================================

  /// Trouve le chemin optimal dans le graphe pour traduire de src vers tgt.
  ///
  /// Retourne une liste de paires (étapes) à exécuter.
  /// Exemple : ['fr-en', 'en-de'] pour fr→de via pivot anglais.
  List<String> _findPath(String src, String tgt) {
    if (src == tgt) return [];

    // 1. Tentative de traduction directe
    if (_modelGraph.containsKey('$src-$tgt')) {
      logger.d('Chemin direct trouvé: $src-$tgt');
      return ['$src-$tgt'];
    }

    // 2. Tentative de pivot via l'anglais
    if (src != 'en' && tgt != 'en') {
      if (_modelGraph.containsKey('$src-en') &&
          _modelGraph.containsKey('en-$tgt')) {
        logger.d('Chemin pivot trouvé: $src-en + en-$tgt');
        return ['$src-en', 'en-$tgt'];
      }
    }

    // 3. Aucune route disponible
    logger.w('Aucune route de traduction disponible: $src → $tgt');
    return [];
  }

  /// Exécute la traduction en suivant le chemin trouvé dans le graphe.
  Future<List<String>> _translateWithGraph(
    List<String> texts,
    String src,
    String tgt,
  ) async {
    final path = _findPath(src, tgt);

    if (path.isEmpty) {
      logger.w('Traduction impossible: $src → $tgt (aucune route)');
      return List.from(texts);
    }

    var currentTexts = List<String>.from(texts);

    for (final step in path) {
      logger.i('Étape de traduction: $step (${currentTexts.length} segments)');
      try {
        currentTexts = await _translateStep(currentTexts, step);
      } catch (e) {
        logger.w('Étape $step échouée ($e) — textes conservés sans traduction.');
        return List.from(texts); // retour aux textes originaux
      }
    }

    return currentTexts;
  }

  /// Exécute une seule étape de traduction (une paire source-cible).
  Future<List<String>> _translateStep(
    List<String> texts,
    String pair,
  ) async {
    final spec = _modelGraph[pair]!;
    final (modelName, langToken) = spec;
    final modelDir = _getModelDir(modelName);

    // Vérification de disponibilité du modèle
    if (!_isModelAvailable(modelName)) {
      logger.w('Modèle non disponible: $modelName pour la paire $pair');
      throw Exception('Modèle $modelName introuvable');
    }

    return await _callPython(texts, pair, modelDir, langToken);
  }

  // ============================================================================
  // CHEMINS DES MODÈLES
  // ============================================================================

  /// Chemin vers le répertoire d'un modèle bundlé.
  ///
  /// Structure :
  ///   snap   : `$SNAP/data/flutter_assets/assets/translation_models/{name}/`
  ///   debug  : `<exe_dir>/data/flutter_assets/assets/translation_models/{name}/`
  ///   dev    : `<app_support_dir>/translation_models/` (copié depuis assets)
  String _getModelDir(String modelName) {
    // 1. Modèles téléchargés à l'exécution (priorité sur les modèles bundlés)
    final userDir = userModelsDir();
    if (userDir != null) {
      final userPath = p.join(userDir, modelName);
      if (File(p.join(userPath, 'model.bin')).existsSync()) return userPath;
    }

    // 2. Modèles bundlés (snap ou debug)
    final snap = Platform.environment['SNAP'];
    if (snap != null && snap.isNotEmpty) {
      return p.join(snap, 'data', 'flutter_assets', 'assets', 'translation_models', modelName);
    }
    final exeDir = p.dirname(Platform.resolvedExecutable);
    return p.join(exeDir, 'data', 'flutter_assets', 'assets', 'translation_models', modelName);
  }

  /// Vérifie si un modèle CTranslate2 est disponible sur le système de fichiers.
  ///
  /// Seul `model.bin` (format CTranslate2) est accepté par opusmt_translate.py.
  /// Les autres formats (onnx, pt, safetensors) ne sont pas supportés.
  bool _isModelAvailable(String modelName) => isModelDirAvailable(modelName);

  // ============================================================================
  // EXÉCUTION PYTHON
  // ============================================================================

  /// Appelle le script Python de traduction OPUS-MT.
  Future<List<String>> _callPython(
    List<String> texts,
    String pair,
    String modelDir,
    String? langToken,
  ) async {
    final logPrefix = '[$pair]';

    final args = [_scriptPath, modelDir];
    if (langToken != null) {
      args.addAll(['--token', langToken]);
    }

    final env = _buildPythonEnv();
    final pythonBin = 'python3.12';
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
        '$logPrefix opusmt_translate.py exit=$exitCode\n${stderrBuffer.toString().trim()}',
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
  ///
  /// Gère :
  /// - PYTHONPATH pour pyenv snap
  /// - LD_LIBRARY_PATH pour les libs ctranslate2 et numpy
  Map<String, String> _buildPythonEnv() {
    final env = Map<String, String>.from(Platform.environment);

    if (env.containsKey('PYTHONPATH')) return env;

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final localPyenv = p.join(exeDir, 'pyenv');

    if (!Directory(localPyenv).existsSync()) return env;

    env['PYTHONPATH'] = localPyenv;

    // Ajout des chemins des bibliothèques compilées
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

  /// Génère une clé de cache unique pour une traduction.
  String _buildCacheKey(String from, String to, String text) {
    return '$from→$to:${text.hashCode}';
  }

  /// Charge le cache depuis le fichier.
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

  /// Sauvegarde le cache dans le fichier.
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
