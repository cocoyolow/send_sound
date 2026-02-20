# send_sound

> CLI minimaliste — envoie un son via **Bluetooth Low Energy** à tous les appareils Flutter connectés.

## Architecture

```
Terminal                    BLE (réseau local non requis)     Flutter App
────────────────────────────────────────────────────────────────────────────
$ send_sound alert  ────── scan + connect ──────────────►  advertise UUID
                    ────── chunks 512 bytes ─────────────►  buffer
                    ────── b"END" ───────────────────────►  play sound 🔊
                    ◄───── "ok" / "err" ─────────────────  notify
```

## Structure

```
app_faa/
├── send_sound            # CLI (Python 3 + bleak)
├── requirements.txt      # bleak>=0.21
├── sounds/               # Déposer ici les fichiers .mp3 / .wav
└── mobile/flutter/
    ├── pubspec.yaml
    ├── lib/main.dart
    ├── android/app/src/main/AndroidManifest.xml
    └── ios/Runner/Info.plist
```

## Installation

### CLI

```bash
pip install -r requirements.txt
chmod +x send_sound
```

### Flutter (téléphone)

```bash
cd mobile/flutter
flutter pub get
flutter run          # iOS ou Android
```

## Utilisation

```bash
# Placer un son dans sounds/
cp ~/mysound.mp3 sounds/alert.mp3

# Envoyer le son à tous les téléphones connectés
./send_sound alert
# → "success" ou "error"
```

## Comment ça marche

| Étape | CLI | App Flutter |
|---|---|---|
| 1 | Scan BLE pour le UUID `12345678-…-def0` | Advertise ce UUID |
| 2 | Connexion à tous les devices trouvés | Accepte la connexion |
| 3 | Envoie le fichier en chunks de 512 bytes | Accumule dans un buffer |
| 4 | Envoie `END` | Reconstruit le fichier, le joue |
| 5 | Reçoit `ok`/`err`, affiche `success`/`error` | Envoie la confirmation |

## Permissions requises

### Android (`AndroidManifest.xml` — déjà inclus)
- `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`

### iOS (`Info.plist` — déjà inclus)
- `NSBluetoothAlwaysUsageDescription`
- Background modes : `bluetooth-peripheral`, `audio`
