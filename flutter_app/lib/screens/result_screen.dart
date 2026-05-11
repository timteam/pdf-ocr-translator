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
        title: const Text('Translation Complete'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Success icon
            const Center(
              child: Icon(
                Icons.check_circle,
                size: 96,
                color: AppTheme.successColor,
              ),
            ),
            const SizedBox(height: 24),

            // Success message
            Text(
              'Translation Successful!',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppTheme.successColor,
                  ),
            ),
            const SizedBox(height: 16),

            Text(
              'Your PDF has been translated and is ready for download.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 40),

            // File info card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Output File',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.description,
                          color: AppTheme.primaryColor,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            outputPath ?? 'translated.pdf',
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

            // Translate another button
            OutlinedButton.icon(
              onPressed: () {
                context.go('/');
              },
              icon: const Icon(Icons.add),
              label: const Text('Translate Another PDF'),
            ),
          ],
        ),
      ),
    );
  }
}
