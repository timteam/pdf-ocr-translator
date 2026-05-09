# PDF OCR Translator - Snap Package

## 🏗️ Aperçu

Ce guide décrit la construction, l’installation et la publication du package Snap pour l’application `PDF OCR Translator`.

La solution est conçue pour fonctionner entièrement localement : OCR, traduction et génération de document PDF se déroulent sur l’appareil sans backend externe.

---

## ✅ Prérequis

### 1. Système hôte

- **Linux** est requis pour construire le Snap.
- Le script `build-snap.sh` vérifie automatiquement l’OS et échoue proprement sur macOS/Windows.

### 2. Outils requis

- `snapcraft` (installé via Snap)
- `Flutter` 3.16+ installé et accessible dans le `PATH`
- `git`

### 3. Dépendances Linux de build

Sur Debian/Ubuntu, installez :

```bash
sudo apt update
sudo apt install build-essential cmake ninja-build pkg-config libgtk-3-dev libglib2.0-dev liblzma-dev libasound2 libpangocairo-1.0-0 libatk1.0-0 libcairo-gobject2 libgdk-pixbuf2.0-0 libxss1 libgconf-2-4 libxrandr2
```

### 4. Configuration Flutter Linux

```bash
flutter config --enable-linux-desktop
flutter doctor
```

> Note : si `flutter pub get` remonte un avertissement à propos de `file_picker` et de plugins desktop, cela signifie un problème de métadonnées du package. Le build snap peut toujours fonctionner si la plateforme Linux est bien configurée.

---

## 🚀 Procédure de build

### 1. Construire l’application Flutter Linux

```bash
cd /home/tim/Repos/pdf-ocr-translator
./build-snap.sh
```

Le script effectue les actions suivantes :

- vérifie la présence de `snapcraft`
- vérifie que l’hôte est Linux
- vérifie la présence de `flutter`
- vérifie les outils de compilation Linux (`cmake`, `ninja`, `clang++`, `pkg-config`)
- ajoute le support Linux si nécessaire via `flutter create --platforms=linux .`
- lance `flutter pub get`
- construit le binaire Linux avec `flutter build linux --release`
- génère le package Snap via `snapcraft pack`

### 2. Résultat

- Le `.snap` généré est déplacé vers `snap-builds/`
- Le package porte un nom de type `pdf-ocr-translator_0.1.0_amd64.snap`

---

## 📦 Installation locale du Snap

```bash
sudo snap install ./snap-builds/pdf-ocr-translator_*.snap --dangerous
```

### Lancer l’application

```bash
pdf-ocr-translator
```

---

## 🔧 Configuration Snap

Le package Snap utilise :

- **Base** : `core22`
- **Confinement** : `strict`
- **Plugs** : `home`, `network`, `opengl`, `wayland`, `x11`, `removable-media`
- **Applications** : `pdf-ocr-translator`

---

## 🛠️ Résolution des problèmes

### Flutter non trouvé

```bash
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
```

### Outils de build Linux manquants

```bash
sudo apt update
sudo apt install build-essential cmake ninja-build pkg-config libgtk-3-dev
```

### Erreur `file_picker` plugin desktop

Ce message est généralement lié à un avertissement de métadonnées de plugin, pas à une erreur de build Flutter en soi.

- Vérifiez que votre projet a bien le dossier `linux/`
- Vérifiez que le support desktop Linux est activé
- Si le build échoue, essayez de verrouiller la version de `file_picker` compatible avec votre SDK Flutter

### Erreur Snapcraft

```bash
snapcraft clean
snapcraft --verbose
```

---

## 🚀 Publication Snap

1. **Connexion**

```bash
snapcraft login
```

2. **Upload**

```bash
snapcraft upload ./snap-builds/pdf-ocr-translator_0.1.0_amd64.snap
```

3. **Publication**

```bash
snapcraft release pdf-ocr-translator 1 stable
snapcraft release pdf-ocr-translator 1 candidate
```

---

## 📌 Conseils d’optimisation

- Utiliser `flutter build linux --release --split-debug-info` pour débogage différentiel
- Supprimer les assets inutilisés
- Réduire la taille du Snap avec la compression et le nettoyage des fichiers intermédiaires

---

## 📊 Contenu du Snap

Le package Snap inclut principalement :

- runtime Flutter
- ressources et dépendances de l’application
- bibliothèques GTK pour l’interface desktop
- fichiers de génération du binaire Linux

---

## 🧩 Notes spécifiques

- Le Snap est orienté distribution Linux desktop.
- Le projet Flutter reste multiplateforme, mais le packaging Snap est uniquement Linux.
- Si vous ne pouvez pas construire sur Linux, vous pouvez au moins préparer le projet Flutter sur macOS/Windows et transférer la source sur Linux pour le packaging.
