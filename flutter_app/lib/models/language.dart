class Language {
  final String code;
  final String name;
  const Language({required this.code, required this.name});
}

class SupportedLanguages {
  static const List<Language> languages = [
    Language(code: 'ar', name: 'Arabe'),
    Language(code: 'zh', name: 'Chinois'),
    Language(code: 'de', name: 'Allemand'),
    Language(code: 'en', name: 'Anglais'),
    Language(code: 'es', name: 'Espagnol'),
    Language(code: 'fr', name: 'Français'),
    Language(code: 'hi', name: 'Hindi'),
    Language(code: 'it', name: 'Italien'),
    Language(code: 'ja', name: 'Japonais'),
    Language(code: 'ko', name: 'Coréen'),
    Language(code: 'nl', name: 'Néerlandais'),
    Language(code: 'pl', name: 'Polonais'),
    Language(code: 'pt', name: 'Portugais'),
    Language(code: 'ru', name: 'Russe'),
    Language(code: 'th', name: 'Thaï'),
    Language(code: 'vi', name: 'Vietnamien'),
  ];

  static Language getLanguageByCode(String code) {
    return languages.firstWhere(
      (l) => l.code == code,
      orElse: () => Language(code: code, name: code.toUpperCase()),
    );
  }
}
