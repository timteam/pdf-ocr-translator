import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../models/language.dart';
import '../models/language_detection.dart';
import '../models/processing.dart';
import '../services/pdf_service.dart';
import '../services/translation_service.dart';
import '../theme/app_theme.dart';

// ─── Machine d'état ───────────────────────────────────────────────────────────

enum _Phase { detecting, confirming, translating, error }

// ─── Vue zoom plein écran ─────────────────────────────────────────────────────

void _showPageZoom(BuildContext context, String path) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog.fullscreen(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black),
          InteractiveViewer(
            panEnabled: true,
            minScale: 0.8,
            maxScale: 8.0,
            child: Center(
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.broken_image, color: Colors.white54, size: 64),
              ),
            ),
          ),
          Positioned(
            top: 16, right: 16,
            child: SafeArea(
              child: IconButton(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// ─── Écran principal ──────────────────────────────────────────────────────────

class ProcessingScreen extends StatefulWidget {
  final String? pdfPath;
  final String? targetLanguage;
  final String? outputPath;
  final bool debugMode;

  const ProcessingScreen({
    Key? key,
    this.pdfPath,
    this.targetLanguage,
    this.outputPath,
    this.debugMode = false,
  }) : super(key: key);

  @override
  _ProcessingScreenState createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  _Phase _phase = _Phase.detecting;
  String? _errorMessage;

  // Phase detecting
  int _detectPage = 0;
  int _detectTotal = 0;

  // Phase confirming
  List<PageLanguage> _pageLanguages = [];

  // Disponibilité des modèles (calculée après la détection)
  Map<String, bool> _modelStatus = {}; // modelName -> disponible
  bool _modelsChecked = false;

  // Phase translating
  ProcessingUpdate _update = const ProcessingUpdate(
    currentPage: 0, totalPages: 1, stepName: 'Initialisation…',
  );

  late final PDFProcessingService _service;

  @override
  void initState() {
    super.initState();
    _service = PDFProcessingService();
    _startDetection();
  }

  @override
  void dispose() {
    _cleanupThumbnails();
    super.dispose();
  }

  void _cleanupThumbnails() {
    for (final pl in _pageLanguages) {
      final path = pl.thumbnailPath;
      if (path != null) {
        try { File(path).deleteSync(); } catch (_) {}
      }
    }
  }

  // ─── Phase 1 : Détection ──────────────────────────────────────────────────

  Future<void> _startDetection() async {
    if (widget.pdfPath == null || widget.outputPath == null) {
      setState(() {
        _errorMessage = 'Paramètres manquants';
        _phase = _Phase.error;
      });
      return;
    }

    try {
      await _service.initialize();
      final langs = await _service.detectPageLanguages(
        File(widget.pdfPath!),
        onPageDetected: (cur, tot) {
          if (mounted) setState(() { _detectPage = cur; _detectTotal = tot; });
        },
      );
      if (mounted) {
        setState(() {
          _pageLanguages = langs;
          _phase = _Phase.confirming;
        });
        _checkModelAvailability();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _phase = _Phase.error;
        });
      }
    }
  }

  // ─── Vérification des modèles ─────────────────────────────────────────────

  void _checkModelAvailability() {
    final target = widget.targetLanguage ?? 'fr';
    final required = <String>{};
    for (final pl in _pageLanguages) {
      if (!pl.skipTranslation) {
        required.addAll(TranslationService.requiredModelDirs(pl.effectiveCode, target));
      }
    }
    final status = {
      for (final m in required) m: TranslationService.isModelDirAvailable(m),
    };
    if (mounted) setState(() { _modelStatus = status; _modelsChecked = true; });
  }

  Set<String> _missingModelsForPage(PageLanguage pl) {
    if (!_modelsChecked || pl.skipTranslation) return {};
    final target = widget.targetLanguage ?? 'fr';
    return TranslationService.requiredModelDirs(pl.effectiveCode, target)
        .where((m) => _modelStatus[m] == false)
        .toSet();
  }

  Set<String> get _allMissingModels =>
      _modelStatus.entries.where((e) => !e.value).map((e) => e.key).toSet();

  // ─── Phase 2 : Confirmation ───────────────────────────────────────────────

  void _abandon() => context.go('/');

  void _showCustomizationSheet() async {
    final updated = await showModalBottomSheet<List<PageLanguage>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        maxChildSize: 0.95,
        minChildSize: 0.45,
        expand: false,
        builder: (ctx, scroll) => _CustomizationSheet(
          pageLanguages: _pageLanguages,
          scrollController: scroll,
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _pageLanguages = updated);
      _checkModelAvailability();
    }
  }

  void _skipAffectedPages() {
    setState(() {
      _pageLanguages = _pageLanguages.map((pl) {
        if (_missingModelsForPage(pl).isNotEmpty) return pl.withSkip(true);
        return pl;
      }).toList();
    });
    _checkModelAvailability();
  }

  void _showModelDownloadSheet(Set<String> missing) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        expand: false,
        builder: (ctx, scroll) => _ModelDownloadSheet(
          missingModels: missing,
          scrollController: scroll,
          onDownloadComplete: () {
            if (mounted) _checkModelAvailability();
          },
        ),
      ),
    );
  }

  Future<void> _confirmAndTranslate() async {
    // Les pages dont les modèles sont toujours manquants seront ignorées (src = target)
    final effectivePages = _pageLanguages.map((pl) {
      if (pl.skipTranslation || _missingModelsForPage(pl).isNotEmpty) {
        return pl.withOverride(widget.targetLanguage ?? 'fr');
      }
      return pl;
    }).toList();

    _cleanupThumbnails();
    setState(() { _phase = _Phase.translating; });

    try {
      final outputPath = await _service.processPDF(
        pdfFile: File(widget.pdfPath!),
        pageLanguages: effectivePages,
        targetLanguage: widget.targetLanguage ?? 'fr',
        outputPath: widget.outputPath!,
        onProgress: (update) {
          if (mounted) setState(() => _update = update);
        },
        debugMode: widget.debugMode,
      );
      if (mounted) {
        context.go('/result', extra: {'outputPath': outputPath});
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _phase = _Phase.error;
        });
      }
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final canPop = _phase != _Phase.detecting && _phase != _Phase.translating;
    return PopScope(
      canPop: canPop,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Traitement en cours'),
          automaticallyImplyLeading: canPop,
        ),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: switch (_phase) {
            _Phase.detecting    => _buildDetecting(),
            _Phase.confirming   => _buildConfirming(),
            _Phase.translating  => _buildTranslating(),
            _Phase.error        => _buildError(),
          },
        ),
      ),
    );
  }

  // ── UI : détection ────────────────────────────────────────────────────────

  Widget _buildDetecting() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 64, height: 64,
          child: CircularProgressIndicator(strokeWidth: 5),
        ),
        const SizedBox(height: 32),
        Text(
          'Analyse de la langue…',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        if (_detectTotal > 0) ...[
          const SizedBox(height: 8),
          Text(
            'Page $_detectPage / $_detectTotal',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: _detectTotal > 0 ? _detectPage / _detectTotal : null,
            backgroundColor: Colors.grey.shade200,
            valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
          ),
        ],
      ],
    );
  }

  // ── UI : confirmation ─────────────────────────────────────────────────────

  Widget _buildConfirming() {
    final n = _pageLanguages.length;
    return Column(
      children: [
        const SizedBox(height: 8),
        const Icon(Icons.check_circle_outline, size: 52, color: Colors.green),
        const SizedBox(height: 12),
        Text(
          'Langues détectées',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          '$n page${n > 1 ? 's' : ''} analysée${n > 1 ? 's' : ''}',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
        ),
        const SizedBox(height: 20),

        // Liste des pages
        Expanded(
          child: Card(
            margin: EdgeInsets.zero,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _pageLanguages.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (ctx, i) {
                final pl = _pageLanguages[i];
                return _buildPageTile(pl);
              },
            ),
          ),
        ),

        // Bannière modèles manquants
        if (_modelsChecked && _allMissingModels.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildMissingModelsBanner(),
        ],

        const SizedBox(height: 16),

        // Boutons d'action
        Row(
          children: [
            TextButton(
              onPressed: _abandon,
              child: const Text('Abandonner'),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _showCustomizationSheet,
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Personnaliser'),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: _confirmAndTranslate,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Continuer'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPageTile(PageLanguage pl) {
    final missing = _missingModelsForPage(pl);
    final langName = pl.skipTranslation
        ? 'Non traduit'
        : SupportedLanguages.getLanguageByCode(pl.effectiveCode).name;
    final detectedName = SupportedLanguages.getLanguageByCode(pl.detectedCode).name;

    final isGray = pl.skipTranslation;
    final textStyle = isGray
        ? TextStyle(color: Colors.grey.shade500, fontStyle: FontStyle.italic)
        : null;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: GestureDetector(
        onTap: pl.thumbnailPath != null
            ? () => _showPageZoom(context, pl.thumbnailPath!)
            : null,
        child: _buildThumbnail(pl.thumbnailPath, dim: isGray),
      ),
      title: Text('Page ${pl.pageNumber}',
          style: TextStyle(fontWeight: FontWeight.w600).merge(textStyle)),
      subtitle: pl.skipTranslation
          ? Text('Non traduit', style: textStyle)
          : pl.isOverridden
              ? Text('$langName  ·  détecté : $detectedName',
                  style: TextStyle(color: AppTheme.primaryColor, fontSize: 12))
              : Text(langName),
      trailing: _buildPageTrailing(pl, missing),
    );
  }

  Widget? _buildPageTrailing(PageLanguage pl, Set<String> missing) {
    if (pl.skipTranslation) {
      return Tooltip(
        message: 'Traduction ignorée (modèle absent)',
        child: Icon(Icons.block, size: 18, color: Colors.grey.shade400),
      );
    }
    final hasWarning = missing.isNotEmpty;
    final hasEdit = pl.isOverridden;
    if (!hasWarning && !hasEdit) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasEdit)
          const Icon(Icons.edit, size: 16, color: AppTheme.primaryColor),
        if (hasEdit && hasWarning) const SizedBox(width: 4),
        if (hasWarning)
          Tooltip(
            message: 'Modèle manquant : ${missing.join(", ")}',
            child: const Icon(Icons.warning_amber, size: 18, color: Colors.orange),
          ),
      ],
    );
  }

  Widget _buildThumbnail(String? path, {bool dim = false}) {
    Widget img;
    if (path != null) {
      img = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(path),
          height: 52, width: 37,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _PageIcon(),
        ),
      );
    } else {
      img = const _PageIcon();
    }
    return dim ? Opacity(opacity: 0.35, child: img) : img;
  }

  Widget _buildMissingModelsBanner() {
    final missing = _allMissingModels;
    final affectedPages = _pageLanguages
        .where((pl) => !pl.skipTranslation && _missingModelsForPage(pl).isNotEmpty)
        .map((pl) => 'p.${pl.pageNumber}')
        .join(', ');

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${missing.length} modèle${missing.length > 1 ? 's' : ''} manquant${missing.length > 1 ? 's' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.orange),
              ),
            ),
          ]),
          const SizedBox(height: 2),
          Text(
            '$affectedPages — ${missing.join(", ")}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.orange.shade800),
          ),
          const SizedBox(height: 6),
          Row(children: [
            TextButton.icon(
              onPressed: _skipAffectedPages,
              icon: const Icon(Icons.block, size: 15),
              label: const Text('Passer ces pages'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.orange.shade800,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => _showModelDownloadSheet(missing),
              icon: const Icon(Icons.download, size: 15),
              label: const Text('Télécharger'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.orange,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ]),
        ],
      ),
    );
  }

  // ── UI : traduction ───────────────────────────────────────────────────────

  Widget _buildTranslating() {
    final hasPages = _update.totalPages > 0;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 140, height: 140,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: hasPages ? _update.totalProgress : null,
                  strokeWidth: 10,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${_update.totalPercent}%',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primaryColor,
                        ),
                  ),
                  if (hasPages && _update.totalPages > 1)
                    Text(
                      'p. ${_update.currentPage}/${_update.totalPages}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
        Text(
          _update.stepName,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _update.isIndeterminate ? null : _update.stepProgress,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
              ),
            ),
            const SizedBox(height: 4),
            if (!_update.isIndeterminate)
              Text(
                '${_update.stepPercent}%',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
              ),
          ],
        ),
      ],
    );
  }

  // ── UI : erreur ───────────────────────────────────────────────────────────

  Widget _buildError() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, size: 64, color: AppTheme.errorColor),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.shade200),
          ),
          child: Text(
            _errorMessage!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.errorColor,
                ),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: () => context.go('/'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Retour'),
        ),
      ],
    );
  }
}

// ─── Widget icône de page fallback ────────────────────────────────────────────

class _PageIcon extends StatelessWidget {
  const _PageIcon();
  @override
  Widget build(BuildContext context) => Container(
    width: 37, height: 52,
    decoration: BoxDecoration(
      color: Colors.grey.shade100,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: Colors.grey.shade300),
    ),
    child: const Icon(Icons.description, size: 20, color: Colors.grey),
  );
}

// ─── Feuille de téléchargement des modèles ───────────────────────────────────

class _ModelDownloadSheet extends StatefulWidget {
  final Set<String> missingModels;
  final ScrollController scrollController;
  final VoidCallback onDownloadComplete;

  const _ModelDownloadSheet({
    required this.missingModels,
    required this.scrollController,
    required this.onDownloadComplete,
  });

  @override
  State<_ModelDownloadSheet> createState() => _ModelDownloadSheetState();
}

class _ModelDownloadSheetState extends State<_ModelDownloadSheet> {
  final _tokenController = TextEditingController();
  final _outputScroll = ScrollController();
  bool _downloading = false;
  bool _done = false;
  String _output = '';

  @override
  void dispose() {
    _tokenController.dispose();
    _outputScroll.dispose();
    super.dispose();
  }

  // Remonte l'arborescence depuis l'exécutable pour trouver le script source
  static String? _findPrepareScript() {
    var dir = p.dirname(Platform.resolvedExecutable);
    for (int i = 0; i < 8; i++) {
      final candidate = p.join(dir, 'scripts', 'prepare_translation_models.sh');
      if (File(candidate).existsSync()) return candidate;
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    return null;
  }

  Future<void> _runDownload() async {
    setState(() { _downloading = true; _done = false; _output = ''; });

    final script = _findPrepareScript();
    final outputDir = TranslationService.userModelsDir();

    if (script == null) {
      // Mode snap ou dossier source inaccessible : afficher la commande à exécuter
      final token = _tokenController.text.trim();
      final tokenArg = token.isNotEmpty ? '\n    --hf-token $token \\' : '';
      setState(() {
        _output = '⚠  Script de conversion introuvable (mode snap).\n\n'
            'Exécutez depuis le répertoire source du projet :\n\n'
            '  ./scripts/prepare_translation_models.sh \\\n'
            '    --models ${widget.missingModels.join(",")} \\$tokenArg\n'
            '    flutter_app/assets/translation_models/\n\n'
            'Puis relancez l\'application.';
        _downloading = false;
      });
      return;
    }

    if (outputDir == null) {
      setState(() {
        _output = '⚠  Impossible de déterminer le répertoire utilisateur.';
        _downloading = false;
      });
      return;
    }

    await Directory(outputDir).create(recursive: true);

    final token = _tokenController.text.trim();
    final args = [
      script,
      '--models', widget.missingModels.join(','),
      if (token.isNotEmpty) ...['--hf-token', token],
      outputDir,
    ];

    setState(() => _output = '→ Démarrage de la conversion...\n');

    try {
      final process = await Process.start('bash', args);

      process.stdout.transform(utf8.decoder).forEach((chunk) {
        if (mounted) setState(() { _output += chunk; _scrollToBottom(); });
      });
      process.stderr.transform(utf8.decoder).forEach((chunk) {
        if (mounted) setState(() { _output += chunk; _scrollToBottom(); });
      });

      final exitCode = await process.exitCode;
      if (mounted) {
        setState(() {
          _downloading = false;
          _done = exitCode == 0;
          _output += exitCode == 0
              ? '\n✅ Téléchargement terminé.'
              : '\n❌ Erreur (code $exitCode).';
          _scrollToBottom();
        });
        if (exitCode == 0) widget.onDownloadComplete();
      }
    } catch (e) {
      if (mounted) {
        setState(() { _output += '\n❌ Erreur : $e'; _downloading = false; });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_outputScroll.hasClients) {
        _outputScroll.jumpTo(_outputScroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // Drag handle
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // En-tête
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              const Icon(Icons.download, color: AppTheme.primaryColor),
              const SizedBox(width: 10),
              Text(
                'Télécharger les modèles manquants',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ]),
          ),

          const Divider(height: 20),

          Expanded(
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                // Liste des modèles requis
                Text('Modèles requis',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                ...widget.missingModels.map((m) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(children: [
                        const Icon(Icons.chevron_right, size: 16, color: AppTheme.primaryColor),
                        const SizedBox(width: 4),
                        Text(m, style: const TextStyle(fontFamily: 'monospace')),
                      ]),
                    )),

                const SizedBox(height: 20),

                // Token HuggingFace
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Text('Token HuggingFace',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(width: 6),
                  Tooltip(
                    triggerMode: TooltipTriggerMode.tap,
                    showDuration: const Duration(seconds: 8),
                    message:
                        'Optionnel, mais recommandé pour éviter le rate-limiting\n'
                        'lors du téléchargement de plusieurs modèles.\n\n'
                        'Pour créer un token gratuit :\n'
                        '  1. Allez sur huggingface.co/settings/tokens\n'
                        '  2. Cliquez "New token" → type "Read"\n'
                        '  3. Copiez le token (commence par hf_...)',
                    child: Icon(Icons.help_outline,
                        size: 16, color: Colors.grey.shade500),
                  ),
                ]),
                const SizedBox(height: 6),
                TextField(
                  controller: _tokenController,
                  enabled: !_downloading,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'hf_... (optionnel)',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    prefixIcon: Icon(Icons.key, size: 18),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'huggingface.co/settings/tokens  →  "New token" → Read',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                ),

                // Zone de sortie (visible après démarrage)
                if (_output.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Sortie', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Container(
                    height: 180,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade900,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Scrollbar(
                      controller: _outputScroll,
                      child: SingleChildScrollView(
                        controller: _outputScroll,
                        padding: const EdgeInsets.all(10),
                        child: SelectableText(
                          _output,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const Divider(height: 1),

          // Boutons
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Row(children: [
              TextButton(
                onPressed: _downloading ? null : () => Navigator.of(context).pop(),
                child: Text(_done ? 'Fermer' : 'Annuler'),
              ),
              const Spacer(),
              if (_downloading)
                const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (_downloading) const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _downloading || _done ? null : _runDownload,
                icon: const Icon(Icons.download, size: 18),
                label: Text(_done ? 'Terminé' : 'Télécharger'),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ─── Feuille de personnalisation ──────────────────────────────────────────────

class _CustomizationSheet extends StatefulWidget {
  final List<PageLanguage> pageLanguages;
  final ScrollController scrollController;

  const _CustomizationSheet({
    required this.pageLanguages,
    required this.scrollController,
  });

  @override
  State<_CustomizationSheet> createState() => _CustomizationSheetState();
}

class _CustomizationSheetState extends State<_CustomizationSheet> {
  bool _globalMode = true;
  String _globalLang = 'en';
  late List<PageLanguage> _pages;

  @override
  void initState() {
    super.initState();
    _pages = List.of(widget.pageLanguages);
    _globalLang = _pages.isNotEmpty ? _pages.first.effectiveCode : 'en';
  }

  void _applyGlobal() {
    setState(() {
      _pages = _pages.map((pl) => pl.withOverride(_globalLang)).toList();
    });
  }

  void _reset() {
    setState(() {
      _pages = _pages.map((pl) => pl.clearOverride().withSkip(false)).toList();
      if (_pages.isNotEmpty) _globalLang = _pages.first.detectedCode;
    });
  }

  void _confirm() => Navigator.of(context).pop(_pages);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text(
                  'Personnaliser les langues',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _reset,
                  child: const Text('Réinitialiser'),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          Expanded(
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              children: [
                RadioGroup<bool>(
                  groupValue: _globalMode,
                  onChanged: (v) { if (v != null) setState(() => _globalMode = v); },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RadioListTile<bool>(
                        value: true,
                        title: const Text('Même langue pour tout le document'),
                      ),
                      if (_globalMode)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(32, 0, 16, 8),
                          child: DropdownButtonFormField<String>(
                            initialValue: _globalLang,
                            decoration: const InputDecoration(
                              labelText: 'Langue',
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: SupportedLanguages.languages
                                .map((l) => DropdownMenuItem(
                                      value: l.code,
                                      child: Text(l.name),
                                    ))
                                .toList(),
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _globalLang = v);
                                _applyGlobal();
                              }
                            },
                          ),
                        ),
                      const SizedBox(height: 4),
                      RadioListTile<bool>(
                        value: false,
                        title: const Text('Personnaliser page par page'),
                      ),
                      if (!_globalMode) ...[
                        const SizedBox(height: 4),
                        ..._pages.map((pl) => _buildPageRow(pl)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _confirm,
                icon: const Icon(Icons.check),
                label: const Text('Confirmer'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageRow(PageLanguage pl) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          if (pl.thumbnailPath != null)
            GestureDetector(
              onTap: () => _showPageZoom(context, pl.thumbnailPath!),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Image.file(
                  File(pl.thumbnailPath!),
                  height: 56, width: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const _PageIcon(),
                ),
              ),
            )
          else
            const _PageIcon(),
          const SizedBox(width: 12),
          SizedBox(
            width: 56,
            child: Text(
              'Page ${pl.pageNumber}',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: pl.effectiveCode,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: SupportedLanguages.languages
                  .map((l) => DropdownMenuItem(
                        value: l.code,
                        child: Text(l.name, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    final idx = _pages.indexWhere((p) => p.pageNumber == pl.pageNumber);
                    if (idx >= 0) _pages[idx] = pl.withOverride(v);
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
