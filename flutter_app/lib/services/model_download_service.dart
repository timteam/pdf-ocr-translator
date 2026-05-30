import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// ─── Dépôt HuggingFace hébergeant les modèles CTranslate2 pré-convertis ──────
// Créez un Dataset HF public et uploadez vos modèles convertis avec :
//   scripts/upload_models_to_hf.sh --repo OWNER/REPO --hf-token hf_...
// Puis remplacez OWNER/opus-mt-ct2 par votre identifiant de dépôt.
const String kModelHfRepo = 'Timteamteem/opus-mt-ct2';

class ModelDownloadService {
  static const String _hfApiBase =
      'https://huggingface.co/api/datasets/$kModelHfRepo/tree/main';
  static const String _hfResolveBase =
      'https://huggingface.co/datasets/$kModelHfRepo/resolve/main';

  /// Télécharge un modèle [modelKey] depuis HuggingFace vers [targetDir].
  ///
  /// [onProgress] : appelé à intervalles réguliers avec (nomFichier, octetsReçus, total).
  /// total = -1 si la taille est inconnue.
  ///
  /// Lève une [Exception] en cas d'erreur réseau ou si le modèle est introuvable.
  static Future<void> downloadModel(
    String modelKey, {
    required String targetDir,
    String? hfToken,
    void Function(String file, int received, int total)? onProgress,
  }) async {
    final files = await _listModelFiles(modelKey, hfToken: hfToken);
    if (files.isEmpty) {
      throw Exception(
        'Modèle "$modelKey" introuvable dans le dépôt "$kModelHfRepo".\n'
        'Vérifiez que le dépôt existe et contient ce modèle.\n'
        'Commande d\'upload : scripts/upload_models_to_hf.sh --repo $kModelHfRepo',
      );
    }

    await Directory(targetDir).create(recursive: true);

    for (final file in files) {
      final name = file['name'] as String;
      final url = '$_hfResolveBase/$modelKey/$name';
      await _downloadFile(
        url,
        p.join(targetDir, name),
        hfToken: hfToken,
        onProgress: (recv, tot) => onProgress?.call(name, recv, tot),
      );
    }
  }

  // ─── HuggingFace API : liste des fichiers d'un répertoire ─────────────────

  static Future<List<Map<String, dynamic>>> _listModelFiles(
    String modelKey, {
    String? hfToken,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$_hfApiBase/$modelKey'));
      _setAuth(req, hfToken);
      final resp = await req.close();
      if (resp.statusCode == 404) return [];
      if (resp.statusCode == 401) {
        throw Exception(
          'Authentification requise (HTTP 401).\n'
          'Fournissez un token HuggingFace dans le champ ci-dessus.',
        );
      }
      if (resp.statusCode != 200) {
        throw Exception('API HuggingFace : HTTP ${resp.statusCode}');
      }
      final body = await resp.transform(utf8.decoder).join();
      final entries = jsonDecode(body) as List;
      return entries
          .where((e) => e['type'] == 'file')
          .map<Map<String, dynamic>>((e) {
            final path = e['path'] as String;
            return {
              'name': p.basename(path),
              'size': (e['size'] as int?) ?? -1,
            };
          })
          .toList();
    } finally {
      client.close();
    }
  }

  // ─── Téléchargement d'un fichier avec progression ─────────────────────────

  static Future<void> _downloadFile(
    String url,
    String dest, {
    String? hfToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 8;
      _setAuth(req, hfToken);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode} pour ${p.basename(url)}');
      }

      final total = resp.contentLength; // -1 si inconnu
      int received = 0;
      int lastNotified = 0;
      const notifyEvery = 262144; // 256 Ko

      final sink = File(dest).openWrite();
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          if (received - lastNotified >= notifyEvery) {
            lastNotified = received;
            onProgress?.call(received, total);
          }
        }
        // Notification finale garantie
        onProgress?.call(received, total);
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  static void _setAuth(HttpClientRequest req, String? token) {
    if (token != null && token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
  }
}
