// ============================================================
// lib/screens/log_screen.dart (FULL - dengan Selection & Share Foto)
// ============================================================
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final StorageService _storage = StorageService();
  List<ScanEntry> _entries = [];
  List<ScanEntry> _filteredEntries = [];
  bool _isLoading = true;

  // Selection state
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  // Filter state
  String _searchQuery = '';
  String _filterPeriod = 'Semua'; // 'Semua', 'Hari ini', 'Minggu ini', 'Bulan ini'

  final TextEditingController _searchController = TextEditingController();
  final DateFormat _dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEntries() async {
    setState(() => _isLoading = true);
    try {
      _entries = await _storage.loadAll();
      _applyFilters();
    } catch (e) {
      debugPrint('Error loading entries: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applyFilters() {
    List<ScanEntry> result = List.from(_entries);

    // Filter periode
    if (_filterPeriod != 'Semua') {
      final now = DateTime.now();
      DateTime start;
      switch (_filterPeriod) {
        case 'Hari ini':
          start = DateTime(now.year, now.month, now.day);
          break;
        case 'Minggu ini':
          start = now.subtract(Duration(days: now.weekday - 1));
          start = DateTime(start.year, start.month, start.day);
          break;
        case 'Bulan ini':
          start = DateTime(now.year, now.month, 1);
          break;
        default:
          start = DateTime(0);
      }
      result = result.where((e) => e.timestamp.isAfter(start)).toList();
    }

    // Search
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      result = result.where((e) {
        final matchesBarcode = e.value.toLowerCase().contains(query);
        final matchesFileName = e.value.toLowerCase().contains(query);
        final matchesDate = _dateFormat.format(e.timestamp).contains(query);
        return matchesBarcode || matchesFileName || matchesDate;
      }).toList();
    }

    result.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    setState(() {
      _filteredEntries = result;
    });
  }

  void _onSearchChanged(String value) {
    _searchQuery = value.trim();
    _applyFilters();
    // Jika keluar dari mode seleksi saat mencari
    if (_isSelectionMode) _toggleSelectionMode();
  }

  void _setFilterPeriod(String period) {
    setState(() {
      _filterPeriod = period;
    });
    _applyFilters();
    if (_isSelectionMode) _toggleSelectionMode();
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedIds.clear();
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      final allIds = _filteredEntries.map((e) => e.id).toSet();
      if (_selectedIds.length == allIds.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(allIds);
      }
    });
  }

  bool _isAllSelected() {
    if (_filteredEntries.isEmpty) return false;
    return _selectedIds.length == _filteredEntries.length;
  }

  // ── SHARE FOTO ──────────────────────────────────────────────────
  Future<void> _shareSelectedPhotos() async {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih minimal satu foto untuk dibagikan')),
      );
      return;
    }

    // Ambil entry yang dipilih dan hanya yang bertipe photo
    final selectedEntries = _filteredEntries
        .where((e) => _selectedIds.contains(e.id) && e.type == ScanType.photo)
        .toList();

    if (selectedEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tidak ada foto yang dipilih')),
      );
      return;
    }

    // Kumpulkan file foto
    final List<XFile> files = [];
    for (final entry in selectedEntries) {
      final file = File(entry.value);
      if (await file.exists()) {
        files.add(XFile(file.path));
      }
    }

    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File foto tidak ditemukan')),
      );
      return;
    }

    try {
      // Tampilkan loading
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Menyiapkan foto untuk dibagikan...')),
      );

      // Share menggunakan share_plus
      if (files.length == 1) {
        // Share satu foto dengan caption
        await Share.shareXFiles(
          files,
          text: '📸 Hasil scan dari WH Scanner\n'
              'Total: ${files.length} foto\n'
              'Waktu: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
        );
      } else {
        // Share multiple foto
        await Share.shareXFiles(
          files,
          text: '📸 ${files.length} foto hasil scan dari WH Scanner\n'
              'Waktu: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
        );
      }

      // Reset selection setelah share
      _toggleSelectionMode();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal share: $e')),
      );
    }
  }

  // ── EXPORT TEXT ──────────────────────────────────────────────────
  Future<void> _exportAndShare() async {
    if (_filteredEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tidak ada data untuk diexport')),
      );
      return;
    }
    try {
      final path = await _storage.exportTxt(_filteredEntries);
      await _storage.shareTxt(path);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal export: $e')),
      );
    }
  }

  Future<void> _deleteEntry(ScanEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus Data'),
        content: Text('Hapus scan barcode "${entry.value}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _storage.delete(entry.id);
      if (entry.type == ScanType.photo && entry.value.isNotEmpty) {
        try {
          final file = File(entry.value);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      // Hapus dari selection jika ada
      _selectedIds.remove(entry.id);
      await _loadEntries();
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus Terpilih'),
        content: Text('Hapus ${_selectedIds.length} item yang dipilih?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Hapus Semua'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      for (final id in _selectedIds) {
        final entry = _filteredEntries.firstWhere((e) => e.id == id);
        if (entry.type == ScanType.photo && entry.value.isNotEmpty) {
          try {
            final file = File(entry.value);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
        await _storage.delete(id);
      }
      _selectedIds.clear();
      await _loadEntries();
      _toggleSelectionMode();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: _isSelectionMode
            ? Text('Pilih ${_selectedIds.length} item')
            : const Text('Riwayat Scan'),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _toggleSelectionMode,
              )
            : null,
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              icon: Icon(
                _isAllSelected() ? Icons.deselect : Icons.select_all,
                color: Colors.white,
              ),
              onPressed: _toggleSelectAll,
              tooltip: 'Pilih semua',
            ),
            IconButton(
              icon: const Icon(Icons.share, color: Colors.green),
              onPressed: _shareSelectedPhotos,
              tooltip: 'Share foto terpilih',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: _deleteSelected,
              tooltip: 'Hapus terpilih',
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _exportAndShare,
              tooltip: 'Export & Share (Teks)',
            ),
            IconButton(
              icon: const Icon(Icons.select_all),
              onPressed: () {
                if (_filteredEntries.isNotEmpty) {
                  _toggleSelectionMode();
                }
              },
              tooltip: 'Pilih foto untuk dibagikan',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadEntries,
              tooltip: 'Refresh',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // Search & Filter bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                // Search field
                TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Cari barcode, tanggal, atau nama file...',
                    hintStyle: const TextStyle(color: Colors.grey),
                    prefixIcon: const Icon(Icons.search, color: Colors.grey),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, color: Colors.grey),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const Gap(8),
                // Filter chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterChip(
                        label: 'Semua',
                        selected: _filterPeriod == 'Semua',
                        onSelected: () => _setFilterPeriod('Semua'),
                      ),
                      _FilterChip(
                        label: '📅 Hari ini',
                        selected: _filterPeriod == 'Hari ini',
                        onSelected: () => _setFilterPeriod('Hari ini'),
                      ),
                      _FilterChip(
                        label: '📅 Minggu ini',
                        selected: _filterPeriod == 'Minggu ini',
                        onSelected: () => _setFilterPeriod('Minggu ini'),
                      ),
                      _FilterChip(
                        label: '📅 Bulan ini',
                        selected: _filterPeriod == 'Bulan ini',
                        onSelected: () => _setFilterPeriod('Bulan ini'),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_filteredEntries.length} item',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredEntries.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.history, size: 48, color: Colors.grey.shade600),
                            const Gap(12),
                            Text(
                              _searchQuery.isNotEmpty || _filterPeriod != 'Semua'
                                  ? 'Tidak ada hasil untuk filter ini'
                                  : 'Belum ada scan',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filteredEntries.length,
                        itemBuilder: (context, index) {
                          final entry = _filteredEntries[index];
                          return _LogItem(
                            entry: entry,
                            isSelected: _isSelectionMode && _selectedIds.contains(entry.id),
                            onTap: _isSelectionMode
                                ? () {
                                    setState(() {
                                      if (_selectedIds.contains(entry.id)) {
                                        _selectedIds.remove(entry.id);
                                      } else {
                                        _selectedIds.add(entry.id);
                                      }
                                    });
                                  }
                                : null,
                            onDelete: () => _deleteEntry(entry),
                            dateFormat: _dateFormat,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Filter Chip widget ──────────────────────────────────────
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onPressed: onSelected,
        selectedColor: AppTheme.accentOrange,
        backgroundColor: Colors.grey.shade800,
        labelStyle: TextStyle(
          color: selected ? Colors.black : Colors.white70,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
    );
  }
}

// ── Log Item ────────────────────────────────────────────────
class _LogItem extends StatelessWidget {
  final ScanEntry entry;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback onDelete;
  final DateFormat dateFormat;

  const _LogItem({
    required this.entry,
    required this.isSelected,
    this.onTap,
    required this.onDelete,
    required this.dateFormat,
  });

  @override
  Widget build(BuildContext context) {
    final isPhoto = entry.type == ScanType.photo;
    final icon = isPhoto ? Icons.photo_camera : Icons.qr_code;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isSelected ? Colors.amber.withOpacity(0.1) : const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? Colors.amber : Colors.grey.shade800,
          width: isSelected ? 2 : 1,
        ),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onTap != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  color: isSelected ? Colors.amber : Colors.grey,
                  size: 22,
                ),
              ),
            CircleAvatar(
              backgroundColor: isPhoto ? Colors.blue.shade900 : Colors.amber.shade900,
              child: Icon(icon, color: Colors.white),
            ),
          ],
        ),
        title: Text(
          entry.value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dateFormat.format(entry.timestamp),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            if (entry.locationName != null && entry.locationName!.isNotEmpty)
              Text(
                entry.locationName!,
                style: const TextStyle(color: Colors.grey, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: onTap == null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (entry.barcodeFormat == 'MANUAL')
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.amber.withOpacity(0.4)),
                      ),
                      child: const Text(
                        'Manual',
                        style: TextStyle(
                          color: Colors.amber,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 18),
                    onPressed: onDelete,
                    tooltip: 'Hapus',
                  ),
                ],
              )
            : null,
      ),
    );
  }
}
