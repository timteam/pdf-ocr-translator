import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';

class ResultScreen extends StatelessWidget {
  final String? outputPath;

  const ResultScreen({Key? key, this.outputPath}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Traduction terminée'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(
              child: Icon(Icons.check_circle, size: 96, color: AppTheme.successColor),
            ),
            const SizedBox(height: 24),

            Text(
              'Traduction réussie !',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppTheme.successColor,
                  ),
            ),
            const SizedBox(height: 16),

            Text(
              'Le PDF traduit a été enregistré.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 40),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fichier de sortie',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.description, color: AppTheme.primaryColor),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            outputPath ?? 'traduit.pdf',
                            style: Theme.of(context).textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),

            OutlinedButton.icon(
              onPressed: () => context.go('/'),
              icon: const Icon(Icons.add),
              label: const Text('Traduire un autre PDF'),
            ),
          ],
        ),
      ),
    );
  }
}
