import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;

// Filtre sans restriction : le filtre par défaut du package logger bloque
// les niveaux < warning en mode release. Ce filtre laisse tout passer.
class _AllLevelsFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) => true;
}

// Output dynamique : toutes les instances de Logger partagent cette unique
// référence. Quand setOutputPath() est appelé, tous les loggers basculent
// vers le nouveau fichier sans être recréés.
class _DynamicFileOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    final file = AppLogger._logFile;
    if (file == null) return;
    final ts = DateTime.now().toIso8601String();
    final lvl = event.level.name.toUpperCase().padRight(7);
    for (final line in event.lines) {
      try {
        file.writeAsStringSync('[$ts][$lvl] $line\n', mode: FileMode.append);
      } catch (_) {}
    }
  }
}

class AppLogger {
  static File?   _logFile;
  static String? _debugDir;
  static final   _fileOutput = _DynamicFileOutput();

  // Répertoire de debug : <dir>/<stem>/ (null si debug désactivé)
  static String? get debugDir => _debugDir;
  static String? get logPath  => _logFile?.path;

  // Appelé au début de chaque processPDF.
  // Sans debug : log console uniquement, pas de répertoire créé.
  // Avec debug  : crée <dir>/<stem>/ et y écrit le log + les images de préprocessing.
  static void setOutputPath(String outputPath, {bool debug = false}) {
    if (!debug) {
      _logFile  = null;
      _debugDir = null;
      return;
    }
    final stem = p.basenameWithoutExtension(outputPath);
    _debugDir  = p.join(p.dirname(outputPath), stem);
    Directory(_debugDir!).createSync(recursive: true);
    final logPath = p.join(_debugDir!, '$stem.log');
    _logFile = File(logPath);
    _logFile!.writeAsStringSync(
      '=== Traitement démarré ${DateTime.now().toIso8601String()} ===\n'
      'Sortie : $outputPath\n'
      'Log    : $logPath\n\n',
    );
  }

  static Logger build() => Logger(
    filter: _AllLevelsFilter(),
    level: Level.trace,
    printer: SimplePrinter(printTime: true, colors: false),
    output: MultiOutput([ConsoleOutput(), _fileOutput]),
  );
}
