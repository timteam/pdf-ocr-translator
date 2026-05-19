import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;

import '../models/language.dart';
import '../theme/app_theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? selectedSourceLanguage;
  String? selectedTargetLanguage;
  String? selectedPdfPath;
  bool _debugMode = false;

  @override
  void initState() {
    super.initState();
    selectedSourceLanguage = 'en';
    selectedTargetLanguage = 'fr';
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await Permission.storage.request();
    await Permission.photos.request();
  }

  Future<void> _pickPDFFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (result != null) {
        setState(() => selectedPdfPath = result.files.single.path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur lors de la sélection : $e')),
        );
      }
    }
  }

  String _defaultOutputPath() {
    if (selectedPdfPath == null) return '';
    final dir = p.dirname(selectedPdfPath!);
    final name = p.basenameWithoutExtension(selectedPdfPath!);
    final lang = selectedTargetLanguage ?? 'fr';
    return p.join(dir, '${name}_$lang.pdf');
  }

  Future<void> _startTranslation() async {
    if (selectedPdfPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Veuillez sélectionner un fichier PDF')),
      );
      return;
    }

    // Dialogue de choix du fichier de sortie
    final outputPath = await _pickOutputPath();
    if (outputPath == null) return; // annulé par l'utilisateur

    if (mounted) {
      context.go('/processing', extra: {
        'pdfPath': selectedPdfPath,
        'sourceLanguage': selectedSourceLanguage,
        'targetLanguage': selectedTargetLanguage,
        'outputPath': outputPath,
        'debugMode': _debugMode,
      });
    }
  }

  Future<String?> _pickOutputPath() async {
    final defaultPath = _defaultOutputPath();
    final controller = TextEditingController(text: defaultPath);

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Fichier de sortie'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Chemin et nom du PDF traduit :',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '/chemin/vers/fichier_fr.pdf',
              ),
              maxLines: 2,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () async {
                final result = await FilePicker.saveFile(
                  dialogTitle: 'Enregistrer le PDF traduit',
                  fileName: p.basename(defaultPath),
                  type: FileType.custom,
                  allowedExtensions: ['pdf'],
                );
                if (result != null) controller.text = result;
              },
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Parcourir…'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () {
              final path = controller.text.trim();
              if (path.isEmpty) return;
              Navigator.of(ctx).pop(path);
            },
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF OCR Translator'),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // En-tête
              Center(
                child: Column(
                  children: [
                    const Icon(Icons.description, size: 64, color: AppTheme.primaryColor),
                    const SizedBox(height: 16),
                    Text(
                      'Traduire vos PDFs',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Extraction OCR et traduction dans 16 langues',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),

              // Sélection PDF
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Fichier PDF source',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _pickPDFFile,
                        icon: const Icon(Icons.file_open),
                        label: Text(
                          selectedPdfPath != null
                              ? p.basename(selectedPdfPath!)
                              : 'Choisir un PDF…',
                        ),
                      ),
                      if (selectedPdfPath != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          selectedPdfPath!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Sélection des langues
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Langues',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: selectedSourceLanguage,
                        decoration: const InputDecoration(labelText: 'Langue source'),
                        items: SupportedLanguages.languages
                            .map((lang) => DropdownMenuItem(
                                  value: lang.code,
                                  child: Text(lang.name),
                                ))
                            .toList(),
                        onChanged: (value) =>
                            setState(() => selectedSourceLanguage = value),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: selectedTargetLanguage,
                        decoration: const InputDecoration(labelText: 'Langue cible'),
                        items: SupportedLanguages.languages
                            .map((lang) => DropdownMenuItem(
                                  value: lang.code,
                                  child: Text(lang.name),
                                ))
                            .toList(),
                        onChanged: (value) =>
                            setState(() => selectedTargetLanguage = value),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Mode debug
              CheckboxListTile(
                value: _debugMode,
                onChanged: (v) => setState(() => _debugMode = v ?? false),
                title: const Text('Mode debug'),
                subtitle: const Text(
                  'Enregistre le log et les images préprocessées dans un sous-répertoire',
                  style: TextStyle(fontSize: 12),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),

              const SizedBox(height: 24),

              // Bouton lancer
              ElevatedButton.icon(
                onPressed: selectedPdfPath != null ? _startTranslation : null,
                icon: const Icon(Icons.translate),
                label: const Text('Démarrer la traduction'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
