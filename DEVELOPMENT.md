# Guide de Développement - PDF OCR Translator

## Gitflow Workflow

Ce projet utilise le modèle Gitflow pour la gestion des branches.

### Branches principales
- `main` - Production (releases stabilisées)
- `dev` - Développement (intégration des features)

### Branches de travail
- `feature/xxx` - Nouvelles fonctionnalités
- `bugfix/xxx` - Corrections de bugs
- `hotfix/xxx` - Corrections urgentes en production

### Workflow typique

```bash
# 1. Créer une feature depuis dev
git checkout dev
git pull origin dev
git checkout -b feature/ma-feature

# 2. Développer et faire des commits réguliers
git commit -m "feat: description"

# 3. Push et créer une Pull Request
git push origin feature/ma-feature

# 4. Review et Squash merge dans dev (PR)
# Le merge dans main est fait par le propriétaire uniquement

# 5. Cleanup locale
git checkout dev
git pull origin dev
git branch -d feature/ma-feature
```

## Setup local

### Backend Python

```bash
cd backend
python -m venv venv
source venv/bin/activate  # ou `venv\Scripts\activate` sur Windows
pip install -r requirements.txt
python main.py
```

### Frontend Flutter

```bash
cd flutter_app
flutter pub get
flutter run
```

### Docker

```bash
docker build -f docker/Dockerfile.backend -t pdf-ocr-backend .
docker run -p 8000:8000 pdf-ocr-backend
```

## CI/CD Pipelines

4 pipelines GitHub Actions sont configurées:
- Linux: `ci-linux.yml` - Backend Python + Docker
- macOS: `ci-macos.yml` - Desktop macOS
- Windows: `ci-windows.yml` - Desktop Windows
- Android/iOS: `ci-mobile.yml` - Apps mobiles natives

Chaque pipeline:
1. Teste le code
2. Build les artefacts natifs (APK/IPA pour mobile, Docker pour backend)
3. **Docker uniquement pour le backend** - les apps mobiles sont packagées nativement
4. Publie les releases sur les app stores ou registries

**⚠️ Important:** Les apps mobiles Flutter sont déployées comme des **packages natifs** (APK/IPA) sur les app stores, pas comme des conteneurs Docker.

## Commits et Commits Messages

Format conventionnel:
```
type(scope): description

feat(ocr): add Tesseract integration
fix(translation): handle edge cases
docs(readme): update setup instructions
test(backend): add unit tests for pdf processor
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `chore`

## Ressources

- [Gitflow Cheatsheet](https://danielkummer.github.io/git-flow-cheatsheet/)
- [Conventional Commits](https://www.conventionalcommits.org/)
