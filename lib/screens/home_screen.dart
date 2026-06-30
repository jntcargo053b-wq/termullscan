import 'dart:async';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:file_picker/file_picker.dart'; // ← tambahkan dependency
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'barcode_scan_screen.dart';
import 'photo_scan_screen.dart';
import 'log_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final StorageService _storage = StorageService();

  int _scanCount = 0;
  int _storageUsedBytes = 0;
  bool _isBackupLoading = false;
  bool _isRestoreLoading = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final count = await _storage.getCount();
    final used = await _storage.getTotalStorageUsed();
    if (mounted) {
      setState(() {
        _scanCount = count;
        _storageUsedBytes = used;
      });
    }
  }

  String _formatStorage(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _backup() async {
    setState(() => _isBackupLoading = true);
    try {
      final zipPath = await _storage.backup();
      if (zipPath.isNotEmpty) {
        await _storage.shareBackup(zipPath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal backup: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBackupLoading = false);
    }
  }

  Future<void> _restore() async {
    // Pilih file ZIP
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.isEmpty) return;

    setState(() => _isRestoreLoading = true);
    try {
      final filePath = result.files.single.path!;
      final success = await _storage.restore(filePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? 'Restore berhasil' : 'Restore gagal'),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
      if (success) await _loadData(); // refresh data
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isRestoreLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Gap(16),
              Text(
                'WH Scanner',
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ).animate().fadeIn(duration: 400.ms),
              const Gap(4),
              Text(
                'Scan barcode & foto dengan watermark',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[400],
                    ),
              ).animate().fadeIn(delay: 100.ms),
              const Gap(8),
              // ─── STORAGE INDICATOR ────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade800,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sd_storage, size: 14, color: Colors.grey),
                    const Gap(6),
                    Text(
                      'Penyimpanan: ${_formatStorage(_storageUsedBytes)}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ).animate().fadeIn(delay: 200.ms),
              const Gap(32),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildMenuCard(
                      icon: Icons.qr_code_scanner,
                      title: 'Scan Barcode',
                      subtitle: 'Ambil foto dengan watermark',
                      onTap: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const BarcodeScanScreen(),
                          ),
                        );
                        if (result != null) await _loadData();
                      },
                    ),
                    const Gap(16),
                    _buildMenuCard(
                      icon: Icons.camera_alt,
                      title: 'Ambil Foto',
                      subtitle: 'Foto langsung dengan watermark',
                      onTap: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PhotoScanScreen(),
                          ),
                        );
                        if (result != null) await _loadData();
                      },
                    ),
                    const Gap(16),
                    _buildMenuCard(
                      icon: Icons.history,
                      title: 'Riwayat',
                      subtitle: '$_scanCount scan tersimpan',
                      onTap: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LogScreen(),
                          ),
                        );
                        if (result != null) await _loadData();
                      },
                    ),
                    const Gap(24),
                    // ─── BACKUP & RESTORE BUTTONS ─────────────
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isBackupLoading ? null : _backup,
                            icon: _isBackupLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.backup, size: 18),
                            label: Text(_isBackupLoading ? 'Backup...' : 'Backup'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade700,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const Gap(12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isRestoreLoading ? null : _restore,
                            icon: _isRestoreLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.restore, size: 18),
                            label: Text(_isRestoreLoading ? 'Restore...' : 'Restore'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.grey),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                    ).animate().fadeIn(delay: 400.ms),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.accentOrange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppTheme.accentOrange, size: 28),
              ),
              const Gap(16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Gap(2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[600]),
            ],
          ),
        ),
      ),
    );
  }
}
