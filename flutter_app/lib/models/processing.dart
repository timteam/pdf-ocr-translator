class ProcessingUpdate {
  final int currentPage;
  final int totalPages;
  final String stepName;
  final double? stepProgress;
  final bool isIndeterminate;

  const ProcessingUpdate({
    required this.currentPage,
    required this.totalPages,
    required this.stepName,
    this.stepProgress,
    this.isIndeterminate = false,
  });

  double get totalProgress {
    if (totalPages == 0) return 0.0;
    final pagesDone = currentPage - 1;
    final withinPage = stepProgress ?? 0.0;
    return (pagesDone + withinPage) / totalPages;
  }

  int get totalPercent => (totalProgress * 100).round().clamp(0, 100);
  int get stepPercent => ((stepProgress ?? 0.0) * 100).round().clamp(0, 100);
}
