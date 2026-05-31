class PageLanguage {
  final int pageNumber;
  final String detectedCode;
  final String? overrideCode;
  final String? thumbnailPath;
  final bool skipTranslation;
  /// Rotation CCW en degrés à appliquer avant OCR (0 / 90 / 180 / 270).
  final int rotation;

  const PageLanguage({
    required this.pageNumber,
    required this.detectedCode,
    this.overrideCode,
    this.thumbnailPath,
    this.skipTranslation = false,
    this.rotation = 0,
  });

  String get effectiveCode => overrideCode ?? detectedCode;
  bool get isOverridden => overrideCode != null;

  PageLanguage withOverride(String? code) => PageLanguage(
        pageNumber: pageNumber,
        detectedCode: detectedCode,
        overrideCode: code,
        thumbnailPath: thumbnailPath,
        skipTranslation: skipTranslation,
        rotation: rotation,
      );

  PageLanguage clearOverride() => PageLanguage(
        pageNumber: pageNumber,
        detectedCode: detectedCode,
        thumbnailPath: thumbnailPath,
        rotation: rotation,
      );

  PageLanguage withSkip(bool skip) => PageLanguage(
        pageNumber: pageNumber,
        detectedCode: detectedCode,
        overrideCode: overrideCode,
        thumbnailPath: thumbnailPath,
        skipTranslation: skip,
        rotation: rotation,
      );

  PageLanguage withRotation(int deg) => PageLanguage(
        pageNumber: pageNumber,
        detectedCode: detectedCode,
        overrideCode: overrideCode,
        thumbnailPath: thumbnailPath,
        skipTranslation: skipTranslation,
        rotation: deg % 360,
      );
}
