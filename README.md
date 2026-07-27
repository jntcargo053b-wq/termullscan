# WH Scanner — Scanner Gudang & Ekspedisi

Aplikasi Flutter profesional untuk kebutuhan gudang dan ekspedisi.

## Fitur
- **Scan Barcode / QR Code** — realtime, support QR, EAN-13, Code-128, dll
- **Ambil Foto** — kamera langsung atau dari galeri
- **Timestamp Otomatis** — setiap scan dicatat waktu lengkap (dd-MM-yyyy HH:mm:ss)
- **GPS Otomatis** — koordinat + nama lokasi (reverse geocoding)
- **Log Scan** — riwayat semua scan, bisa cari & filter
- **Export TXT** — laporan teks profesional siap dibagikan

## Cara Build

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# APK: build/app/outputs/flutter-apk/app-release.apk
```

Untuk APK production, salin `android/key.properties.example` menjadi
`android/key.properties`, isi kredensial keystore release, lalu tempatkan file
keystore di folder `android/`. Tanpa konfigurasi tersebut build release tidak
akan memakai debug key dan dapat dihasilkan sebagai APK unsigned.

Pada GitHub Actions, konfigurasi signing dibaca dari secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, dan
`ANDROID_KEY_PASSWORD`.

## Dependencies
- `mobile_scanner` — kamera barcode/QR
- `image_picker` — ambil foto
- `geolocator` + `geocoding` — GPS & nama lokasi
- `path_provider` + `share_plus` — simpan & bagikan file
- `permission_handler` — manajemen izin

## Struktur
```
lib/
  main.dart
  models/scan_entry.dart
  screens/
    home_screen.dart
    barcode_scan_screen.dart
    photo_scan_screen.dart
    log_screen.dart
  services/
    location_service.dart
    storage_service.dart
  theme/app_theme.dart
```
