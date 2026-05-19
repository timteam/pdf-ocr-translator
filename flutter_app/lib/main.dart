import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'screens/processing_screen.dart';
import 'screens/result_screen.dart';
import 'services/translation_service.dart';
import 'services/pdf_service.dart';
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize services
  final translationService = TranslationService();
  await translationService.initialize();

  final pdfService = PDFProcessingService();
  await pdfService.initialize();

  runApp(MyApp(
    translationService: translationService,
    pdfService: pdfService,
  ));
}

class MyApp extends StatelessWidget {
  final TranslationService translationService;
  final PDFProcessingService pdfService;

  const MyApp({
    Key? key,
    required this.translationService,
    required this.pdfService,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: translationService),
        Provider.value(value: pdfService),
      ],
      child: MaterialApp.router(
        title: 'PDF OCR Translator',
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.system,
        routerConfig: _buildRouter(),
      ),
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
              sourceLanguage: extra?['sourceLanguage'],
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
            return ResultScreen(
              outputPath: extra?['outputPath'],
            );
          },
        ),
      ],
    );
  }
}
