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
      currentTexts = await _translateStep(currentTexts, step);
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
    // En mode snap : $SNAP est défini et pointe vers /snap/pdf-ocr-translator/xN
    final snap = Platform.environment['SNAP'];
    if (snap != null && snap.isNotEmpty) {
      return p.join(snap, 'data', 'flutter_assets', 'assets', 'translation_models', modelName);
    }

    // En mode debug/local : on utilise le répertoire des données de l'application
    // Les modèles devraient être copiés depuis les assets au premier usage
    final exeDir = p.dirname(Platform.resolvedExecutable);
    return p.join(
      exeDir,
      'data',
      'flutter_assets',
      'assets',
      'translation_models',
      modelName,
    );
  }

  /// Vérifie si un modèle est disponible sur le système de fichiers.
  ///
  /// Les modèles peuvent être :
  /// 1. Dans le répertoire de données de l'application (bundlés avec le snap)
  /// 2. Dans les assets Flutter (pour le mode dev)
  /// 3. Téléchargés manuellement via scripts/prepare_translation_models.sh
  bool _isModelAvailable(String modelName) {
    final modelDir = _getModelDir(modelName);
    
    // Vérification par extensions de fichiers modèles courantes
    final possibleFiles = [
      'model.bin',
      'model.onnx',
      'model.pt',
      'model.safetensors',
    ];

    for (final file in possibleFiles) {
      if (File(p.join(modelDir, file)).existsSync()) {
        return true;
      }
    }

    // Vérification de l'existence du répertoire avec des fichiers
    final dir = Directory(modelDir);
    if (dir.existsSync()) {
      final files = dir.listSync();
      if (files.isNotEmpty) return true;
    }

    return false;
  }

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
    logger.d('$logPrefix opusmt_translate.py (${texts.length} segment(s))');

    final args = [_scriptPath, modelDir];
    if (langToken != null) {
      args.addAll(['--token', langToken]);
    }

    final process = await Process.start(
      'python3.12',
      args,
      environment: _buildPythonEnv(),
    );

    // Envoi des textes via stdin (JSON)
    process.stdin.write(json.encode(texts));
    await process.stdin.close();

    // Lecture de stdout
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();

    // Gestion des erreurs stderr
    process.stderr.transform(utf8.decoder).forEach((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.trim().isNotEmpty) {
          logger.w('$logPrefix stderr: $line');
        }
      }
    });

    final output = await stdoutFuture;
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      throw Exception('opusmt_translate.py $pair: exit code $exitCode');
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
