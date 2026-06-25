// ============================================================
// lib/screens/watermark_settings_sheet.dart (FINAL)
// ============================================================
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/models/watermark_data.dart';
import '../watermark/watermark_style.dart';
import '../watermark/watermark_factory.dart';
import 'dart:io';

class WatermarkSettingsSheet extends StatefulWidget {
  const WatermarkSettingsSheet({super.key});

  @override
  State<WatermarkSettingsSheet> createState() => _WatermarkSettingsSheetState();
}

class _WatermarkSettingsSheetState extends State<WatermarkSettingsSheet> {
  late WatermarkSettings _settings;
  final ImagePicker _picker = ImagePicker();
  bool _isLoading = true;
  final TextEditingController _operatorController = TextEditingController();

  final List<WatermarkStyle> _supportedStyles = [
    WatermarkStyle.minimal,
    WatermarkStyle.professional,
    WatermarkStyle.polaroid,
    WatermarkStyle.stamp,
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _settings = WatermarkSettings();
    await _settings.load();
    _operatorController.text = _settings.operatorName;
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _saveAndClose() async {
    _settings.operatorName = _operatorController.text;
    await _settings.save();
    debugPrint('💾 SAVED: style=${_settings.style.name}, position=${_settings.position.name}, fontSize=${_settings.fontSize}, fontFamily=${_settings.fontFamily}');
    Navigator.pop(context);
  }

  Future<void> _pickLogo() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 200,
      maxHeight: 200,
      imageQuality: 80,
    );
    if (file != null) {
      await _settings.setLogoPath(file.path);
      if (mounted) setState(() {});
    }
  }

  void _resetDefaults() {
    setState(() {
      _settings.fontSize = 14.0;
      _settings.backgroundOpacity = 0.85;
      _settings.position = WatermarkPosition.bottomRight;
      _settings.style = WatermarkStyle.professional;
    });
    _settings.save();
  }

  @override
  void dispose() {
    _operatorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Preview data dengan nilai realtime
    final previewData = WatermarkData(
      timestamp: DateTime.now(),
      operatorName: _operatorController.text.isNotEmpty 
          ? _operatorController.text 
          : _settings.operatorName,
      barcodeValue: '8991234567890',
      barcodeFormat: 'EAN-13',
      locationName: 'Jl. Sudirman No. 123, Jakarta',
      position: _settings.position,
      fontSize: _settings.fontSize,
      backgroundOpacity: _settings.backgroundOpacity,
      fontFamily: _settings.fontFamily,
    );

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.all(20),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Gap(16),
              const Text(
                'Pengaturan Watermark',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Gap(8),
              const Text(
                'Pilih gaya, posisi, ukuran font, dan opacity',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const Gap(20),

              // ─── Operator ──────────────────────────────────
              const Text(
                'Nama Operator',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const Gap(6),
              TextField(
                controller: _operatorController,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Contoh: PT Maju Jaya',
                  hintStyle: const TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const Gap(16),

              // ─── Pilihan Layout ───────────────────────────
              const Text(
                'Gaya Layout',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const Gap(8),
              SizedBox(
                height: 160,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _supportedStyles.length,
                  separatorBuilder: (_, __) => const Gap(12),
                  itemBuilder: (context, index) {
                    final style = _supportedStyles[index];
                    final isSelected = _settings.style == style;
                    final layout = WatermarkFactory.create(style);
                    return GestureDetector(
                      onTap: () async {
                        await _settings.setStyle(style);
                        setState(() {});
                      },
                      child: Container(
                        width: 140,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.amber.withOpacity(0.15) : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? Colors.amber : Colors.grey.withOpacity(0.3),
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  color: Colors.grey[900],
                                  padding: const EdgeInsets.all(4),
                                  child: layout.buildPreview(
                                    previewData: previewData,
                                    hasLogo: _settings.hasLogo,
                                    logoPath: _settings.logoPath,
                                    previewWidth: 140,
                                    previewHeight: 100,
                                  ),
                                ),
                              ),
                            ),
                            const Gap(4),
                            Text(
                              layout.displayName,
                              style: TextStyle(
                                color: isSelected ? Colors.amber : Colors.white70,
                                fontSize: 11,
                                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Gap(16),

              // ─── Posisi ──────────────────────────────────
              const Text(
                'Posisi Watermark',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const Gap(6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: WatermarkPosition.values.map((pos) {
                  final isSelected = _settings.position == pos;
                  return ChoiceChip(
                    label: Text(
                      pos.name
                          .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(1)}')
                          .trim(),
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    selected: isSelected,
                    onSelected: (_) async {
                      await _settings.setPosition(pos);
                      setState(() {});
                    },
                    backgroundColor: const Color(0xFF2A2A2A),
                    selectedColor: Colors.amber,
                  );
                }).toList(),
              ),
              const Gap(16),

              // ─── Ukuran Font ─────────────────────────────
              Row(
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(
                      'Ukuran Font: ${(_settings.fontSize / 14 * 100).round()}%',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                  const Gap(8),
                  Expanded(
                    child: Slider(
                      value: _settings.fontSize,
                      min: 8.0,
                      max: 48.0,
                      divisions: 40,
                      onChanged: (val) async {
                        await _settings.setFontSize(val);
                        setState(() {});
                      },
                      activeColor: Colors.amber,
                      inactiveColor: Colors.grey[700],
                    ),
                  ),
                  Container(
                    width: 36,
                    alignment: Alignment.center,
                    child: Text(
                      _settings.fontSize.round().toString(),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ],
              ),
              const Gap(8),

              // ─── Opacity ──────────────────────────────────
              Row(
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(
                      'Opacity: ${(_settings.backgroundOpacity * 100).round()}%',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                  const Gap(8),
                  Expanded(
                    child: Slider(
                      value: _settings.backgroundOpacity,
                      min: 0.1,
                      max: 1.0,
                      divisions: 18,
                      onChanged: (val) async {
                        await _settings.setBackgroundOpacity(val);
                        setState(() {});
                      },
                      activeColor: Colors.amber,
                      inactiveColor: Colors.grey[700],
                    ),
                  ),
                  Container(
                    width: 36,
                    alignment: Alignment.center,
                    child: Text(
                      (_settings.backgroundOpacity * 100).round().toString(),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ],
              ),
              const Gap(16),

              // ─── Pilihan Font ──────────────────────────────
              const Text(
                'Font',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const Gap(6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                ),
                child: DropdownButton<String>(
                  value: _settings.fontFamily,
                  isExpanded: true,
                  underline: const SizedBox(),
                  dropdownColor: const Color(0xFF2A2A2A),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  items: const [
                    DropdownMenuItem(value: 'Roboto', child: Text('Roboto')),
                    DropdownMenuItem(value: 'Inter', child: Text('Inter')),
                    DropdownMenuItem(value: 'Montserrat', child: Text('Montserrat')),
                    DropdownMenuItem(value: 'Poppins', child: Text('Poppins')),
                  ],
                  onChanged: (String? newFont) async {
                    if (newFont != null) {
                      await _settings.setFontFamily(newFont);
                      setState(() {});
                    }
                  },
                ),
              ),
              const Gap(16),

              // ─── Logo ─────────────────────────────────────
              Row(
                children: [
                  const Text(
                    'Logo',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const Gap(12),
                  ElevatedButton.icon(
                    onPressed: _pickLogo,
                    icon: const Icon(Icons.upload_file, size: 16),
                    label: const Text('Pilih Logo'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                  if (_settings.hasLogo) ...[
                    const Gap(8),
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey[700]!),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.file(
                          File(_settings.logoPath!),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 20),
                        ),
                      ),
                    ),
                    const Gap(4),
                    IconButton(
                      onPressed: () {
                        _settings.clearLogo();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close, size: 16, color: Colors.grey),
                    ),
                  ],
                ],
              ),
              const Gap(24),

              // ─── Reset & Tombol ──────────────────────────
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _resetDefaults,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey,
                        side: BorderSide(color: Colors.grey.withOpacity(0.3)),
                      ),
                      child: const Text('Reset Default'),
                    ),
                  ),
                  const Gap(12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saveAndClose,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black,
                      ),
                      child: const Text('Simpan'),
                    ),
                  ),
                ],
              ),
              const Gap(12),
            ],
          ),
        ),
      ),
    );
  }
}
