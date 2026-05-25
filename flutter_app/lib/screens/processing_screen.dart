import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/language.dart';
import '../models/language_detection.dart';
import '../models/processing.dart';
import '../services/pdf_service.dart';
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
    }
  }

  Future<void> _confirmAndTranslate() async {
    _cleanupThumbnails();
    setState(() { _phase = _Phase.translating; });

    try {
      final outputPath = await _service.processPDF(
        pdfFile: File(widget.pdfPath!),
        pageLanguages: _pageLanguages,
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
                final langName = SupportedLanguages.getLanguageByCode(pl.effectiveCode).name;
                final detectedName = SupportedLanguages.getLanguageByCode(pl.detectedCode).name;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: GestureDetector(
                    onTap: pl.thumbnailPath != null
                        ? () => _showPageZoom(context, pl.thumbnailPath!)
                        : null,
                    child: _buildThumbnail(pl.thumbnailPath),
                  ),
                  title: Text('Page ${pl.pageNumber}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: pl.isOverridden
                      ? Text('$langName  ·  détecté : $detectedName',
                          style: TextStyle(color: AppTheme.primaryColor, fontSize: 12))
                      : Text(langName),
                  trailing: pl.isOverridden
                      ? const Icon(Icons.edit, size: 16, color: AppTheme.primaryColor)
                      : null,
                );
              },
            ),
          ),
        ),

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

  Widget _buildThumbnail(String? path) {
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(path),
          height: 52, width: 37,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _PageIcon(),
        ),
      );
    }
    return const _PageIcon();
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
  bool _globalMode = true; // true = même langue pour tout le document
  String _globalLang = 'en';
  late List<PageLanguage> _pages;

  @override
  void initState() {
    super.initState();
    _pages = List.of(widget.pageLanguages);
    // Initialiser la langue globale sur la première page
    _globalLang = _pages.isNotEmpty ? _pages.first.effectiveCode : 'en';
  }

  void _applyGlobal() {
    setState(() {
      _pages = _pages.map((pl) => pl.withOverride(_globalLang)).toList();
    });
  }

  void _reset() {
    setState(() {
      _pages = _pages.map((pl) => pl.clearOverride()).toList();
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

          // Titre
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

          // Options radio
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
                      // Option 1 : langue unique
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
                      // Option 2 : par page
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

          // Bouton confirmer
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
          // Miniature — clic pour zoom plein écran
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

          // Numéro de page
          SizedBox(
            width: 56,
            child: Text(
              'Page ${pl.pageNumber}',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),

          // Dropdown compact
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
