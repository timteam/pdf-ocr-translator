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
  static File? _logFile;
  static final _fileOutput = _DynamicFileOutput();

  // Appelé au début de chaque processPDF : crée/écrase le fichier de log
  // à côté du PDF de sortie (même nom, extension .log).
  static void setOutputPath(String outputPath) {
    final logPath = p.join(
      p.dirname(outputPath),
      '${p.basenameWithoutExtension(outputPath)}.log',
    );
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

  static String? get logPath => _logFile?.path;
}
