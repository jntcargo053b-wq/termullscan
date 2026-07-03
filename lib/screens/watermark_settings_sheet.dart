import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
import '../theme/app_theme.dart';

class WatermarkSettingsSheet extends StatefulWidget {
  const WatermarkSettingsSheet({super.key});

  @override
  State<WatermarkSettingsSheet> createState() => _WatermarkSettingsSheetState();
}

class _WatermarkSettingsSheetState extends State<WatermarkSettingsSheet> {
  late final WatermarkSettings _settings;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _settings = WatermarkSettings();
  }

  // ─── Logo picker ──────────────────────────────────────────
  Future<void> _pickLogo() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 500,
      maxHeight: 500,
      imageQuality: 85,
    );
    if (file != null) {
      await _settings.setLogoPath(file.path);
    }
  }

  Future<void> _clearLogo() async {
    await _settings.clearLogo();
  }

  // ─── Build ──────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: ListenableBuilder(
        listenable: _settings,
        builder: (context, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── Header ──────────────────────────────────
              Row(
                children: [
                  const Text(
                    'Pengaturan Watermark',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.grey),
                  ),
                ],
              ),
              const Divider(color: Colors.grey, thickness: 0.5),

              // ─── Operator Name ──────────────────────────
              _buildTextField(
                label: 'Nama Operator',
                value: _settings.operatorName,
                onChanged: (val) => _settings.setOperatorName(val),
                hint: 'Contoh: Ahmad',
              ),
              const Gap(12),

              // ─── Company Name ───────────────────────────
              _buildTextField(
                label: 'Nama Perusahaan',
                value: _settings.companyName,
                onChanged: (val) => _settings.setCompanyName(val),
                hint: 'Contoh: PT. Maju Jaya',
              ),
              const Gap(16),

              // ─── Style Dropdown ─────────────────────────
              Row(
                children: [
                  const Text(
                    'Gaya',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const Spacer(),
                  DropdownButton<WatermarkStyle>(
                    value: _settings.style,
                    items: WatermarkStyle.values.map((style) {
                      String label;
                      switch (style) {
                        case WatermarkStyle.minimal:
                          label = 'Minimal';
                          break;
                        case WatermarkStyle.professional:
                          label = 'Professional';
                          break;
                        case WatermarkStyle.polaroid:
                          label = 'Polaroid';
                          break;
                        case WatermarkStyle.stamp:
                          label = 'Stamp';
                          break;
                        case WatermarkStyle.timestamp:
                          label = 'Timestamp';
                          break;
                        case WatermarkStyle.fullInfo:
                          label = 'Full Info (Lengkap)';
                          break;
                      }
                      return DropdownMenuItem(
                        value: style,
                        child: Text(label),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) _settings.setStyle(val);
                    },
                    underline: Container(),
                    icon: const Icon(Icons.arrow_drop_down,
                        color: AppTheme.accentOrange),
                    dropdownColor: Colors.grey[900],
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
              const Gap(16),

              // ─── Position Dropdown ──────────────────────
              Row(
                children: [
                  const Text(
                    'Posisi',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const Spacer(),
                  DropdownButton<WatermarkPosition>(
                    value: _settings.position,
                    items: WatermarkPosition.values.map((pos) {
                      String label;
                      switch (pos) {
                        case WatermarkPosition.bottomRight:
                          label = 'Bawah Kanan';
                          break;
                        case WatermarkPosition.bottomLeft:
                          label = 'Bawah Kiri';
                          break;
                        case WatermarkPosition.topRight:
                          label = 'Atas Kanan';
                          break;
                        case WatermarkPosition.topLeft:
                          label = 'Atas Kiri';
                          break;
                      }
                      return DropdownMenuItem(
                        value: pos,
                        child: Text(label),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) _settings.setPosition(val);
                    },
                    underline: Container(),
                    icon: const Icon(Icons.arrow_drop_down,
                        color: AppTheme.accentOrange),
                    dropdownColor: Colors.grey[900],
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
              const Gap(16),

              // ─── Font Size Slider ──────────────────────
              Row(
                children: [
                  const Text(
                    'Ukuran Font',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const Spacer(),
                  Text(
                    '${_settings.fontSize.toInt()}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
              Slider(
                value: _settings.fontSize,
                min: 8,
                max: 48,
                divisions: 40,
                activeColor: AppTheme.accentOrange,
                inactiveColor: Colors.grey[700],
                onChanged: (val) => _settings.setFontSize(val),
              ),
              const Gap(8),

              // ─── Font Family Dropdown ──────────────────
              Row(
                children: [
                  const Text(
                    'Font Family',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const Spacer(),
                  DropdownButton<String>(
                    value: _settings.fontFamily,
                    items: const [
                      DropdownMenuItem(value: 'Roboto', child: Text('Roboto')),
                      DropdownMenuItem(value: 'Inter', child: Text('Inter')),
                      DropdownMenuItem(value: 'Montserrat',
                          child: Text('Montserrat')),
                      DropdownMenuItem(value: 'Poppins', child: Text('Poppins')),
                    ],
                    onChanged: (val) {
                      if (val != null) _settings.setFontFamily(val);
                    },
                    underline: Container(),
                    icon: const Icon(Icons.arrow_drop_down,
                        color: AppTheme.accentOrange),
                    dropdownColor: Colors.grey[900],
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
              const Gap(16),

              // ─── Background Opacity Slider ─────────────
              Row(
                children: [
                  const Text(
                    'Opacity Latar',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const Spacer(),
                  Text(
                    '${(_settings.backgroundOpacity * 100).toInt()}%',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
              Slider(
                value: _settings.backgroundOpacity,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                activeColor: AppTheme.accentOrange,
                inactiveColor: Colors.grey[700],
                onChanged: (val) => _settings.setBackgroundOpacity(val),
              ),
              const Gap(16),

              // ─── Logo ─────────────────────────────────────
              Row(
                children: [
                  const Text(
                    'Logo',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const Spacer(),
                  if (_settings.hasLogo)
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.file(
                            File(_settings.logoPath!),
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image,
                                color: Colors.grey),
                          ),
                        ),
                        const Gap(8),
                        IconButton(
                          onPressed: _clearLogo,
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red, size: 20),
                        ),
                      ],
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: _pickLogo,
                      icon: const Icon(Icons.add_photo_alternate_outlined,
                          size: 18),
                      label: const Text('Pilih Logo'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentOrange,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
              ),
              const Gap(16),

              // ─── Full Info Toggles (hanya jika style fullInfo) ─
              if (_settings.style == WatermarkStyle.fullInfo) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Tampilkan GPS',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Latitude & Longitude',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  value: _settings.showGps,
                  onChanged: (val) => _settings.setShowGps(val),
                  activeColor: AppTheme.accentOrange,
                  tileColor: Colors.transparent,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Tampilkan Lokasi',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Nama lokasi dari GPS',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  value: _settings.showLocation,
                  onChanged: (val) => _settings.setShowLocation(val),
                  activeColor: AppTheme.accentOrange,
                  tileColor: Colors.transparent,
                ),
                const Gap(8),
              ],

              // ─── Video Quality (hanya untuk video) ──────
              Row(
                children: [
                  const Text(
                    'Kualitas Video',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const Spacer(),
                  DropdownButton<VideoQuality>(
                    value: _settings.videoQuality,
                    items: VideoQuality.values.map((quality) {
                      String label;
                      switch (quality) {
                        case VideoQuality.low:
                          label = 'Hemat (2500 kbps)';
                          break;
                        case VideoQuality.medium:
                          label = 'Standar (3500 kbps)';
                          break;
                        case VideoQuality.high:
                          label = 'Tinggi (4000 kbps)';
                          break;
                      }
                      return DropdownMenuItem(
                        value: quality,
                        child: Text(label),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) _settings.setVideoQuality(val);
                    },
                    underline: Container(),
                    icon: const Icon(Icons.arrow_drop_down,
                        color: AppTheme.accentOrange),
                    dropdownColor: Colors.grey[900],
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
              const Gap(24),

              // ─── Tombol Tutup ─────────────────────────────
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentOrange,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  child: const Text('Tutup'),
                ),
              ),
              const Gap(8),
            ],
          );
        },
      ),
    );
  }

  // ─── Helper: TextField ─────────────────────────────────────
  Widget _buildTextField({
    required String label,
    required String value,
    required void Function(String) onChanged,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        const Gap(4),
        TextFormField(
          initialValue: value,
          onChanged: onChanged,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.grey),
            filled: true,
            fillColor: Colors.grey[900],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
          ),
        ),
      ],
    );
  }
}
