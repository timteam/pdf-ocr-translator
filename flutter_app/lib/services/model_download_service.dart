import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// ─── Index Argos Open Tech ────────────────────────────────────────────────────
// Liste publique des modèles Opus-MT (CTranslate2) disponibles.
const String _kArgosIndexUrl =
    'https://raw.githubusercontent.com/argosopentech/argospm-index/main/index.json';

class ModelDownloadService {
  /// Télécharge le modèle Opus-MT pour la paire [modelDirName] (ex : "ja-en")
  /// depuis le CDN Argos vers [targetDir].
  ///
  /// Structure attendue après téléchargement :
  ///   [targetDir]/model/model.bin
  ///   [targetDir]/sentencepiece.model
  ///
  /// [onProgress] : appelé régulièrement avec (nomFichier, octetsReçus, total).
  static Future<void> downloadModel(
    String modelDirName, {
    required String targetDir,
    String? hfToken,          // ignoré (Argos est public, pas de token requis)
    void Function(String file, int received, int total)? onProgress,
  }) async {
    // 1. Récupérer l'index Argos
    final index = await _fetchIndex();

    // 2. Chercher la paire demandée (format "{from}-{to}")
    final parts = modelDirName.split('-');
    if (parts.length < 2) throw Exception('Nom de modèle invalide : $modelDirName');
    final from = parts.first;
    final to = parts.last;

    final entry = index.firstWhere(
      (e) => e['from_code'] == from && e['to_code'] == to,
      orElse: () => throw Exception(
        'Modèle "$modelDirName" introuvable dans l\'index Argos.\n'
        'Vérifiez que la paire de langues est supportée.',
      ),
    );

    final links = entry['links'] as List<dynamic>;
    if (links.isEmpty) throw Exception('Aucun lien pour $modelDirName');
    final url = links.first as String;

    // 3. Télécharger le .argosmodel (zip)
    final zipPath = p.join(Directory.systemTemp.path, 'argos_$modelDirName.argosmodel');
    await _downloadFile(
      url,
      zipPath,
      onProgress: (recv, tot) => onProgress?.call(p.basename(url), recv, tot),
    );

    // 4. Extraire et installer dans targetDir
    await _installArgosModel(zipPath, targetDir);
    await File(zipPath).delete();
  }

  // ─── Récupération de l'index ──────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> _fetchIndex() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(_kArgosIndexUrl));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('Index Argos inaccessible (HTTP ${resp.statusCode})');
      }
      final body = await resp.transform(utf8.decoder).join();
      return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    } finally {
      client.close();
    }
  }

  // ─── Extraction du .argosmodel ────────────────────────────────────────────

  static Future<void> _installArgosModel(String zipPath, String targetDir) async {
    final extractDir = Directory(
      p.join(Directory.systemTemp.path, 'argos_extract_${DateTime.now().millisecondsSinceEpoch}'),
    );
    await extractDir.create(recursive: true);

    try {
      // unzip via le shell (disponible sur Linux)
      final result = await Process.run(
        'unzip', ['-q', zipPath, '-d', extractDir.path],
      );
      if (result.exitCode != 0) {
        throw Exception('unzip échoué : ${result.stderr}');
      }

      // Le zip peut contenir un sous-répertoire racine — on l'aplatit
      final entries = extractDir.listSync();
      final Directory extractRoot;
      if (entries.length == 1 && entries.first is Directory) {
        extractRoot = entries.first as Directory;
      } else {
        extractRoot = extractDir;
      }

      // Vérification de la structure
      final modelBin = File(p.join(extractRoot.path, 'model', 'model.bin'));
      final spmFile = File(p.join(extractRoot.path, 'sentencepiece.model'));
      if (!await modelBin.exists() || !await spmFile.exists()) {
        throw Exception(
          'Structure .argosmodel inattendue — model/model.bin ou sentencepiece.model manquant',
        );
      }

      // Copie dans targetDir
      await Directory(targetDir).create(recursive: true);
      await _copyDir(Directory(p.join(extractRoot.path, 'model')), Directory(p.join(targetDir, 'model')));
      await spmFile.copy(p.join(targetDir, 'sentencepiece.model'));

      final metaFile = File(p.join(extractRoot.path, 'metadata.json'));
      if (await metaFile.exists()) {
        await metaFile.copy(p.join(targetDir, 'metadata.json'));
      }
    } finally {
      await extractDir.delete(recursive: true);
    }
  }

  static Future<void> _copyDir(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list()) {
      final destPath = p.join(dest.path, p.basename(entity.path));
      if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Directory) {
        await _copyDir(entity, Directory(destPath));
      }
    }
  }

  // ─── Téléchargement d'un fichier avec progression ─────────────────────────

  static Future<void> _downloadFile(
    String url,
    String dest, {
    void Function(int received, int total)? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 8;
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode} pour ${p.basename(url)}');
      }

      final total = resp.contentLength;
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
        onProgress?.call(received, total);
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      client.close();
    }
  }
}
