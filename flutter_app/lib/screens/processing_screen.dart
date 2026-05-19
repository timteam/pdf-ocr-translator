import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'dart:io';

import '../models/processing.dart';
import '../services/pdf_service.dart';
import '../theme/app_theme.dart';

class ProcessingScreen extends StatefulWidget {
  final String? pdfPath;
  final String? sourceLanguage;
  final String? targetLanguage;
  final String? outputPath;
  final bool debugMode;

  const ProcessingScreen({
    Key? key,
    this.pdfPath,
    this.sourceLanguage,
    this.targetLanguage,
    this.outputPath,
    this.debugMode = false,
  }) : super(key: key);

  @override
  _ProcessingScreenState createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  ProcessingUpdate _update = const ProcessingUpdate(
    currentPage: 0,
    totalPages: 1,
    stepName: 'Initialisation…',
  );
  bool _isProcessing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _startProcessing();
  }

  Future<void> _startProcessing() async {
    if (widget.pdfPath == null || widget.outputPath == null) {
      setState(() => _errorMessage = 'Paramètres manquants');
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final service = PDFProcessingService();
      await service.initialize();

      final outputPath = await service.processPDF(
        pdfFile: File(widget.pdfPath!),
        sourceLanguage: widget.sourceLanguage ?? 'en',
        targetLanguage: widget.targetLanguage ?? 'fr',
        outputPath: widget.outputPath!,
        onProgress: (update) {
          if (mounted) setState(() => _update = update);
        },
        debugMode: widget.debugMode,
      );

      if (mounted) {
        setState(() => _isProcessing = false);
        context.go('/result', extra: {'outputPath': outputPath});
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isProcessing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Traitement en cours'),
          automaticallyImplyLeading: !_isProcessing,
        ),
        body: Padding(
          padding: const EdgeInsets.all(32.0),
          child: _errorMessage != null ? _buildError() : _buildProgress(context),
        ),
      ),
    );
  }

  Widget _buildProgress(BuildContext context) {
    final hasPages = _update.totalPages > 0;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Progression globale
        SizedBox(
          width: 140,
          height: 140,
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

        // Étape courante
        Text(
          _update.stepName,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),

        const SizedBox(height: 16),

        // Barre de progression de l'étape
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
