import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'screens/processing_screen.dart';
import 'screens/result_screen.dart';
import 'services/pdf_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Pré-charge les modèles statiques (FastText LID, script PaddleOCR)
  // avant que l'utilisateur lance la première traduction.
  final prewarm = PDFProcessingService();
  await prewarm.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'PDF OCR Translator',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      routerConfig: _buildRouter(),
    );
  }

  GoRouter _buildRouter() {
    return GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: '/processing',
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>?;
            return ProcessingScreen(
              pdfPath: extra?['pdfPath'],
              targetLanguage: extra?['targetLanguage'],
              outputPath: extra?['outputPath'],
              debugMode: extra?['debugMode'] as bool? ?? false,
            );
          },
        ),
        GoRoute(
          path: '/result',
          builder: (context, state) {
            final extra = state.extra as Map<String, dynamic>?;
            return ResultScreen(outputPath: extra?['outputPath']);
          },
        ),
      ],
    );
  }
}
