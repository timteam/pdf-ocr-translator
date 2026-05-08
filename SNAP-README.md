# PDF OCR Translator - Snap Package

## 🏗️ Building the Snap

### Prerequisites

1. **Install Snapcraft**:
   ```bash
   sudo snap install snapcraft --classic
   ```

2. **Install Flutter** (if not already installed):
   ```bash
   # Download Flutter SDK
   wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.16.9-stable.tar.xz
   tar xf flutter_linux_3.16.9-stable.tar.xz
   export PATH="$PWD/flutter/bin:$PATH"

   # Configure Flutter
   flutter config --enable-linux-desktop
   flutter doctor
   ```

### Build Process

1. **Run the build script**:
   ```bash
   ./build-snap.sh
   ```

   This will:
   - Check for snapcraft installation
   - Build the Flutter app for Linux
   - Create the snap package
   - Move the snap to `snap-builds/` directory

2. **Manual build** (alternative):
   ```bash
   snapcraft
   ```

## 📦 Installing the Snap

### Local Installation (for testing)

```bash
sudo snap install ./snap-builds/pdf-ocr-translator_0.1.0_amd64.snap --dangerous
```

### Run the App

```bash
pdf-ocr-translator
```

## 🚀 Publishing to Snap Store

1. **Login to Snapcraft**:
   ```bash
   snapcraft login
   ```

2. **Upload the snap**:
   ```bash
   snapcraft upload ./snap-builds/pdf-ocr-translator_0.1.0_amd64.snap
   ```

3. **Release to channels**:
   ```bash
   snapcraft release pdf-ocr-translator 1 stable
   snapcraft release pdf-ocr-translator 1 candidate
   ```

## 🔧 Snap Configuration

The snap is configured in `snapcraft.yaml` with:

- **Base**: Ubuntu 22.04 (core22)
- **Confinement**: Strict (secure)
- **Extensions**: GNOME integration
- **Plugs**: Home, network, removable-media, camera access

## 🐛 Troubleshooting

### Build Issues

**Flutter not found**:
```bash
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
```

**Missing dependencies**:
```bash
sudo apt update
sudo apt install libgtk-3-dev libxss1 libgconf-2-4 libxrandr2 libasound2 libpangocairo-1.0-0
```

**Snapcraft errors**:
```bash
snapcraft clean
snapcraft --verbose
```

### Runtime Issues

**App won't start**:
```bash
snap run pdf-ocr-translator
```

**Permission issues**:
```bash
snap connect pdf-ocr-translator:home
snap connect pdf-ocr-translator:removable-media
```

## 📋 Snap Store Metadata

When publishing, you'll need to provide:

- **Name**: pdf-ocr-translator
- **Summary**: Fully offline PDF OCR and translation app
- **Description**: See the main README.md
- **License**: Apache-2.0
- **Website**: https://github.com/timteam/pdf-ocr-translator
- **Screenshots**: Add screenshots of the app in action

## 🔄 Updating the Snap

1. **Update version in snapcraft.yaml**
2. **Rebuild**: `./build-snap.sh`
3. **Upload**: `snapcraft upload <new-snap-file>`
4. **Release**: `snapcraft release pdf-ocr-translator <revision> stable`

## 📊 Snap Size Optimization

The current snap includes:
- Flutter runtime (~500MB)
- ML Kit models for OCR (~100MB)
- GTK libraries for desktop integration

To reduce size, consider:
- Using flutter build linux --release --split-debug-info
- Removing unused assets
- Using snapcraft's compression options