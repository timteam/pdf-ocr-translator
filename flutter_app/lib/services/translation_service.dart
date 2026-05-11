import 'dart:convert';
import 'dart:io';
import 'package:translator/translator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';

class TranslationService {
  final logger = Logger();
  final _googleTranslator = GoogleTranslator();
  Map<String, String> _translationCache = {};
  bool _argosAvailable = false;

  Future<void> initialize() async {
    await _loadCacheFromStorage();
    _argosAvailable = await _checkArgosAvailable();
    logger.i('Argos Translate disponible: $_argosAvailable');
  }

  Future<bool> _checkArgosAvailable() async {
    try {
      final result = await Process.run('argos-translate', ['--help']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // Appelle le CLI argos-translate en passant le texte via stdin
  Future<String> _argosCall(String text, String from, String to) async {
    final process = await Process.start(
      'argos-translate',
      ['--from-lang', from, '--to-lang', to],
    );
    process.stdin.write(text);
    await process.stdin.close();

    final out = await process.stdout.transform(utf8.decoder).join();
    final err = await process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;

    if (code != 0) throw Exception('argos-translate ($from→$to): $err');
    return out.trim();
  }

  // Pivot via l'anglais si aucun modèle direct n'existe entre from et to
  Future<String> _translateWithArgos(String text, String from, String to) async {
    if (from == to) return text;
    if (from != 'en' && to != 'en') {
      final english = await _argosCall(text, from, 'en');
      return await _argosCall(english, 'en', to);
    }
    return await _argosCall(text, from, to);
  }

  Future<String> translateText(
    String text,
    String fromLanguage,
    String toLanguage,
  ) async {
    if (text.trim().isEmpty) return text;

    final cacheKey = '$fromLanguage-$toLanguage-${text.hashCode}';
    if (_translationCache.containsKey(cacheKey)) {
      logger.i('Cache hit: $cacheKey');
      return _translationCache[cacheKey]!;
    }

    try {
      final String translated;
      if (_argosAvailable) {
        translated = await _translateWithArgos(text, fromLanguage, toLanguage);
        logger.i('Argos: $fromLanguage→$toLanguage');
      } else {
        final result = await _googleTranslator.translate(
          text,
          from: fromLanguage,
          to: toLanguage,
        );
        translated = result.text;
        logger.i('Google Translate: $fromLanguage→$toLanguage');
      }

      _translationCache[cacheKey] = translated;
      await _saveCacheToStorage();
      return translated;
    } catch (e) {
      logger.e('Traduction échouée: $e');
      return text;
    }
  }

  Future<void> _loadCacheFromStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/translation_cache.json');
      if (await file.exists()) {
        final data = json.decode(await file.readAsString()) as Map<String, dynamic>;
        _translationCache = Map<String, String>.from(data);
        logger.i('Cache chargé: ${_translationCache.length} entrées');
      }
    } catch (e) {
      logger.e('Chargement cache échoué: $e');
    }
  }

  Future<void> _saveCacheToStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/translation_cache.json');
      await file.writeAsString(json.encode(_translationCache));
    } catch (e) {
      logger.e('Sauvegarde cache échouée: $e');
    }
  }

  Future<void> clearCache() async {
    _translationCache.clear();
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/translation_cache.json');
    if (await file.exists()) await file.delete();
    logger.i('Cache vidé');
  }

  int getCacheSize() => _translationCache.length;
}
