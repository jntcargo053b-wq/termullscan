// ============================================================
// lib/screens/log_screen.dart (FULL – SORTING + SEARCH NOTE/ADDRESS)
// ============================================================
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:collection/collection.dart';
import 'package:video_player/video_player.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/thumbnail_cache_service.dart';
import '../theme/app_theme.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final StorageService _storage = StorageService();
  List<ScanEntry> _filteredEntries = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _isExporting = false;
  bool _isSharingSelection = false;

  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  String _searchQuery = '';
  String _filterPeriod = 'Semua';
  String _sortField = 'timestamp';
  String _sortDir = 'DESC';

  int _currentPage = 0;
  final int _pageSize = 20;
  bool _hasMore = true;
  int _queryGeneration = 0;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final DateFormat _dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');

  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadEntries(refresh: true);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (_hasMore && !_isLoadingMore && !_isLoading) {
        _loadEntries();
      }
    }
  }

  Future<void> _loadEntries({bool refresh = false}) async {
    if (!mounted) return;
    if (!refresh && (!_hasMore || _isLoadingMore || _isLoading)) return;

    final generation = refresh ? ++_queryGeneration : _queryGeneration;
    final page = refresh ? 0 : _currentPage;
    final searchQuery = _searchQuery.isNotEmpty ? _searchQuery : null;
    final period = _filterPeriod != 'Semua' ? _filterPeriod : null;
    final sortField = _sortField;
    final sortDir = _sortDir;

    setState(() {
      if (refresh) {
        _currentPage = 0;
        _filteredEntries = [];
        _hasMore = true;
        _isLoading = true;
      }
      _isLoadingMore = true;
    });

    try {
      final newEntries = await _storage.getEntries(
        limit: _pageSize,
        offset: page * _pageSize,
        searchQuery: searchQuery,
        period: period,
        sortField: sortField,
        sortDir: sortDir,
      );

      if (!mounted || generation != _queryGeneration) return;

      setState(() {
        if (refresh) {
          _filteredEntries = newEntries;
        } else {
          final existingIds = _filteredEntries.map((entry) => entry.id).toSet();
          _filteredEntries.addAll(
            newEntries.where((entry) => existingIds.add(entry.id)),
          );
        }
        _hasMore = newEntries.length == _pageSize;
        _currentPage = page + 1;
        _isLoading = false;
        _isLoadingMore = false;
      });

      // ✅ FIX PERFORMA: dulu ada query getCount() terpisah (full scan
      // dengan 5 klausa LIKE) di SETIAP page load hanya untuk menghitung
      // _hasMore — padahal totalCount tidak pernah ditampilkan ke user
      // (cek: tidak ada UI "X dari Y hasil"). Kalau jumlah baris yang
      // kembali lebih kecil dari pageSize yang diminta, otomatis berarti
      // sudah halaman terakhir — tidak perlu query kedua sama sekali.
      debugPrint('📊 Loaded ${newEntries.length} entries (page $_currentPage)');
    } catch (e) {
      debugPrint('Error loading entries: $e');
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        if (refresh) _filteredEntries = [];
        _isLoading = false;
        _isLoadingMore = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gagal memuat riwayat scan')),
      );
    }
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _searchQuery = value.trim();
        _isSelectionMode = false;
        _selectedIds.clear();
      });
      _loadEntries(refresh: true);
    });
  }

  void _setFilterPeriod(String period) {
    setState(() {
      _filterPeriod = period;
      _isSelectionMode = false;
      _selectedIds.clear();
    });
    _loadEntries(refresh: true);
  }

  void _setSorting(String field, String dir) {
    setState(() {
      _sortField = field;
      _sortDir = dir;
      _isSelectionMode = false;
      _selectedIds.clear();
    });
    _loadEntries(refresh: true);
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) _selectedIds.clear();
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

  bool _isUsableFileSync(String path) {
    try {
      final file = File(path);
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  void _showPhotoPreview(ScanEntry entry, {int initialIndex = 0}) {
    final paths = entry.photoPaths;
    if (paths.isEmpty && entry.type == ScanType.image && entry.value.isNotEmpty) {
      paths.add(entry.value);
    }
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tidak ada foto untuk ditampilkan')),
      );
      return;
    }

    final validPaths = <String>[];
    for (final p in paths) {
      if (_isUsableFileSync(p)) validPaths.add(p);
    }
    if (validPaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File foto tidak ditemukan')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) => _PhotoPreviewDialog(
        paths: validPaths,
        initialIndex: initialIndex.clamp(0, validPaths.length - 1),
        barcode: entry.value,
        timestamp: entry.timestamp,
      ),
    );
  }

  void _showVideoPreview(ScanEntry entry) {
    final path = entry.videoPath;
    if (path == null ||
        path.isEmpty ||
        !_isUsableFileSync(path)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File video tidak ditemukan')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) => _VideoPreviewDialog(
        videoPath: path,
        barcode: entry.value,
        timestamp: entry.timestamp,
      ),
    );
  }

  void _showEntryDetails(ScanEntry entry) {
    final details = <MapEntry<String, String>>[
      MapEntry('Kode', entry.value),
      MapEntry('Jenis', entry.type.name.toUpperCase()),
      MapEntry('Waktu', _dateFormat.format(entry.timestamp)),
      if (entry.operatorName.isNotEmpty)
        MapEntry('Operator', entry.operatorName),
      if (entry.companyName != null && entry.companyName!.isNotEmpty)
        MapEntry('Perusahaan', entry.companyName!),
      if (entry.hasLocation) MapEntry('Lokasi', entry.displayLocation),
      if (entry.latitude != null && entry.longitude != null)
        MapEntry('Koordinat', '${entry.latitude}, ${entry.longitude}'),
      MapEntry('Input manual', entry.isManual ? 'Ya' : 'Tidak'),
    ];

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Detail Scan'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: details
                .map(
                  (detail) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          detail.key,
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                        SelectableText(detail.value),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  void _previewEntry(ScanEntry entry) {
    if (entry.type == ScanType.video || entry.hasVideo) {
      _showVideoPreview(entry);
    } else if (entry.photoPaths.isNotEmpty || entry.type == ScanType.image) {
      _showPhotoPreview(entry);
    } else {
      _showEntryDetails(entry);
    }
  }

  Future<void> _shareSelectedPhotos() async {
    if (_isSharingSelection) return;
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pilih minimal satu foto untuk dibagikan'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final selectedEntries = _filteredEntries
        .where((e) => _selectedIds.contains(e.id) && e.photoPaths.isNotEmpty)
        .toList();

    if (selectedEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Item yang dipilih tidak memiliki foto.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isSharingSelection = true);
    try {
      final filePaths = <String>{};
      for (final entry in selectedEntries) {
        for (final path in entry.photoPaths) {
          final file = File(path);
          if (await file.exists() && await file.length() > 0) {
            filePaths.add(file.path);
          }
        }
      }
      final files = filePaths.map(XFile.new).toList();

      if (files.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File foto tidak ditemukan atau sudah dihapus.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Menyiapkan ${files.length} foto untuk dibagikan...'),
          duration: const Duration(seconds: 1),
        ),
      );

      late final ShareResult shareResult;
      if (files.length == 1) {
        shareResult = await Share.shareXFiles(
          files,
          text: '📸 Hasil scan dari TermulScan\n'
              'Waktu: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
        );
      } else {
        shareResult = await Share.shareXFiles(
          files,
          text: '📸 ${files.length} foto hasil scan dari TermulScan\n'
              'Waktu: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
        );
      }

      if (!mounted) return;
      if (shareResult.status == ShareResultStatus.dismissed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Berbagi foto dibatalkan')),
        );
        return;
      }
      _toggleSelectionMode();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shareResult.status == ShareResultStatus.success
                ? '✅ Berhasil membagikan ${files.length} foto'
                : 'Menu berbagi untuk ${files.length} foto telah dibuka',
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint('❌ Share error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Gagal share: ${e.toString().split(':').last}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSharingSelection = false);
    }
  }

  Future<void> _exportAndShare() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final entries = await _storage.getEntriesForExport(
        searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
        period: _filterPeriod != 'Semua' ? _filterPeriod : null,
        sortField: _sortField,
        sortDir: _sortDir,
      );
      if (!mounted) return;
      if (entries.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tidak ada data untuk diekspor')),
        );
        return;
      }
      final path = await _storage.exportTxt(entries);
      final shareResult = await _storage.shareTxt(path);
      if (!mounted) return;
      if (shareResult.status == ShareResultStatus.dismissed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Berbagi dokumen dibatalkan')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shareResult.status == ShareResultStatus.success
                ? 'Dokumen berisi ${entries.length} data berhasil dibagikan'
                : 'Menu berbagi dokumen telah dibuka',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal export: $e')),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _deleteEntry(ScanEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus Data'),
        content: Text('Data dan file media akan dihapus permanen. Tindakan ini tidak dapat dibatalkan.\n\n'
            'Hapus scan "${entry.value}"?'),
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
      await _deleteMediaFiles(entry);
      _selectedIds.remove(entry.id);
      _loadEntries(refresh: true);
    }
  }

  Future<void> _deleteMediaFiles(ScanEntry entry) async {
    final paths = <String>{...entry.photoPaths};
    if (entry.videoPath != null && entry.videoPath!.isNotEmpty) {
      paths.add(entry.videoPath!);
    }
    final thumbnail = entry.videoThumbnail;
    if (thumbnail != null && thumbnail.isNotEmpty) paths.add(thumbnail);

    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('Gagal menghapus file media $path: $e');
      }
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus Terpilih'),
        content: Text('Data dan file media akan dihapus permanen. Tindakan ini tidak dapat dibatalkan.\n\n'
            'Hapus ${_selectedIds.length} item yang dipilih?'),
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
        final entry = _filteredEntries.firstWhereOrNull((e) => e.id == id);
        if (entry != null) {
          await _deleteMediaFiles(entry);
        }
        await _storage.delete(id);
      }
      _filteredEntries.removeWhere((e) => _selectedIds.contains(e.id));
      _selectedIds.clear();
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
            ? IconButton(icon: const Icon(Icons.close), onPressed: _toggleSelectionMode)
            : null,
        actions: [
          if (_isSelectionMode) ...[
            IconButton(icon: Icon(_isAllSelected() ? Icons.deselect : Icons.select_all, color: Colors.white), onPressed: _toggleSelectAll),
            IconButton(
              icon: _isSharingSelection
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share, color: Colors.green),
              onPressed: _isSharingSelection ? null : _shareSelectedPhotos,
            ),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: _deleteSelected),
          ] else ...[
            IconButton(
              icon: _isExporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share),
              onPressed: _isExporting ? null : _exportAndShare,
              tooltip: 'Ekspor dan bagikan dokumen',
            ),
            IconButton(icon: const Icon(Icons.select_all), onPressed: () { if (_filteredEntries.isNotEmpty) _toggleSelectionMode(); }),
            IconButton(icon: const Icon(Icons.refresh), onPressed: () => _loadEntries(refresh: true)),
          ],
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '🔍 Cari kode, operator, perusahaan, atau lokasi...',
                    hintStyle: const TextStyle(color: Colors.grey),
                    prefixIcon: const Icon(Icons.search, color: Colors.grey),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(icon: const Icon(Icons.clear, color: Colors.grey), onPressed: () { _searchController.clear(); _onSearchChanged(''); })
                        : null,
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const Gap(8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterChip(label: 'Semua', selected: _filterPeriod == 'Semua', onSelected: () => _setFilterPeriod('Semua')),
                      _FilterChip(label: '📅 Hari ini', selected: _filterPeriod == 'Hari ini', onSelected: () => _setFilterPeriod('Hari ini')),
                      _FilterChip(label: '📅 Minggu ini', selected: _filterPeriod == 'Minggu ini', onSelected: () => _setFilterPeriod('Minggu ini')),
                      _FilterChip(label: '📅 Bulan ini', selected: _filterPeriod == 'Bulan ini', onSelected: () => _setFilterPeriod('Bulan ini')),
                      const Gap(8),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.sort, color: Colors.white70),
                        color: const Color(0xFF2E2E2E),
                        onSelected: (value) {
                          switch (value) {
                            case 'newest': _setSorting('timestamp', 'DESC'); break;
                            case 'oldest': _setSorting('timestamp', 'ASC'); break;
                            case 'barcode_asc': _setSorting('value', 'ASC'); break;
                            case 'barcode_desc': _setSorting('value', 'DESC'); break;
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(value: 'newest', child: Text('Terbaru', style: TextStyle(color: Colors.white))),
                          const PopupMenuItem(value: 'oldest', child: Text('Terlama', style: TextStyle(color: Colors.white))),
                          const PopupMenuItem(value: 'barcode_asc', child: Text('Barcode A-Z', style: TextStyle(color: Colors.white))),
                          const PopupMenuItem(value: 'barcode_desc', child: Text('Barcode Z-A', style: TextStyle(color: Colors.white))),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
                            if (_searchQuery.isNotEmpty) ...[
                              const Gap(8),
                              TextButton(
                                onPressed: () {
                                  _searchController.clear();
                                  _onSearchChanged('');
                                },
                                child: const Text('Clear filter'),
                              ),
                            ],
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _loadEntries(refresh: true),
                        child: ListView.builder(
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _filteredEntries.length + (_hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == _filteredEntries.length) {
                              return const Padding(
                                padding: EdgeInsets.all(8.0),
                                child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
                              );
                            }
                            final entry = _filteredEntries[index];
                            return _LogItem(
                              entry: entry,
                              selectionMode: _isSelectionMode,
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
                                  : () {
                                      _previewEntry(entry);
                                    },
                              onDelete: () => _deleteEntry(entry),
                              dateFormat: _dateFormat,
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ─── Filter Chip ──────────────────────────────────────────────────
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;
  const _FilterChip({required this.label, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
        selectedColor: AppTheme.accentOrange,
        backgroundColor: AppTheme.surfaceLight,
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

// ─── Log Item ──────────────────────────────────────────────────
class _LogItem extends StatelessWidget {
  final ScanEntry entry;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback onDelete;
  final DateFormat dateFormat;
  const _LogItem({
    required this.entry,
    required this.selectionMode,
    required this.isSelected,
    this.onTap,
    required this.onDelete,
    required this.dateFormat,
  });

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isPhoto = entry.type == ScanType.image;
    final isVideo = entry.type == ScanType.video;
    final icon = isVideo ? Icons.videocam : isPhoto ? Icons.photo_camera : Icons.qr_code;
    final avatarColor = isVideo ? AppTheme.error : isPhoto ? AppTheme.accentBlue : AppTheme.accent;
    final hasPhoto = entry.photoPaths.isNotEmpty;
    final typeLabel = isVideo ? 'Video' : isPhoto ? 'Foto' : 'Barcode';

    return Semantics(
      label: '$typeLabel, ${entry.value}${isSelected ? ", dipilih" : ""}',
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.accent.withOpacity(0.1) : AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppTheme.accent : AppTheme.surfaceLight,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: ListTile(
          selected: isSelected,
          onTap: onTap,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    isSelected ? Icons.check_circle : Icons.circle_outlined,
                    color: isSelected ? AppTheme.accent : Colors.grey,
                    size: 22,
                  ),
                ),
              Stack(
                children: [
                  CircleAvatar(backgroundColor: avatarColor, child: Icon(icon, color: Colors.white)),
                  if (isVideo)
                    FutureBuilder<Uint8List?>(
                      future: ThumbnailCacheService.instance.getThumbnail(
                        existingThumbnailPath: entry.videoThumbnail,
                        videoPath: entry.videoPath,
                      ),
                      builder: (context, snapshot) {
                        final bytes = snapshot.data;
                        if (snapshot.connectionState != ConnectionState.done ||
                            bytes == null) {
                          return const SizedBox.shrink();
                        }
                        return CircleAvatar(
                          backgroundColor: Colors.transparent,
                          backgroundImage: MemoryImage(bytes),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  entry.value,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isVideo && entry.videoDuration != null) ...[
                const Gap(6),
                Icon(Icons.timer, size: 14, color: Colors.grey),
                const Gap(2),
                Text(_formatDuration(entry.videoDuration!), style: const TextStyle(color: Colors.grey, fontSize: 11)),
              ],
              if (hasPhoto) ...[
                const Gap(6),
                Icon(Icons.photo_library, size: 16, color: AppTheme.accent),
              ],
              if (entry.photoPaths.length > 1) ...[
                const Gap(2),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(color: AppTheme.accent.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                  child: Text('${entry.photoPaths.length}', style: const TextStyle(color: AppTheme.accent, fontSize: 9, fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(dateFormat.format(entry.timestamp), style: const TextStyle(color: Colors.grey, fontSize: 12)),
              if (entry.hasLocation)
                Text(entry.displayLocation, style: const TextStyle(color: Colors.grey, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
          trailing: !selectionMode
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (entry.isProofComplete)
                      Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.green.withOpacity(0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.green.withOpacity(0.4))),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified, size: 10, color: Colors.green),
                            SizedBox(width: 3),
                            Text('Lengkap', style: TextStyle(color: Colors.green, fontSize: 9, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    if (entry.isManual)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppTheme.accent.withOpacity(0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.accent.withOpacity(0.4))),
                        child: const Text('Manual', style: TextStyle(color: AppTheme.accent, fontSize: 9, fontWeight: FontWeight.w700)),
                      ),
                    IconButton(icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 18), onPressed: onDelete, tooltip: 'Hapus'),
                  ],
                )
              : null,
        ),
      ),
    );
  }
}

// ─── Photo Preview Dialog ──────────────────────────────────
class _PhotoPreviewDialog extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  final String barcode;
  final DateTime timestamp;
  const _PhotoPreviewDialog({required this.paths, required this.initialIndex, required this.barcode, required this.timestamp});

  @override
  State<_PhotoPreviewDialog> createState() => _PhotoPreviewDialogState();
}

class _PhotoPreviewDialogState extends State<_PhotoPreviewDialog> {
  late PageController _pageController;
  late int _currentIndex;
  bool _isSharing = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _sharePhotos(Iterable<String> paths) async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final validPaths = <String>{};
      for (final path in paths) {
        final file = File(path);
        if (await file.exists() && await file.length() > 0) {
          validPaths.add(file.path);
        }
      }
      if (!mounted) return;
      if (validPaths.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File foto tidak ditemukan atau kosong')),
        );
        return;
      }
      final files = validPaths.map(XFile.new).toList();
      await Share.shareXFiles(
        files,
        text: files.length == 1
            ? '${widget.barcode}\n${DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.timestamp)}'
            : '${widget.barcode} - ${files.length} foto',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal membagikan foto: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), border: Border(bottom: BorderSide(color: AppTheme.surfaceLight))),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.barcode, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.timestamp), style: const TextStyle(color: Colors.grey, fontSize: 11)),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemCount: widget.paths.length,
              itemBuilder: (context, index) {
                final path = widget.paths[index];
                return InteractiveViewer(
                  panEnabled: true, scaleEnabled: true, minScale: 0.5, maxScale: 3.0,
                  child: Center(
                    child: Image.file(File(path), fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey.shade900,
                        child: const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.broken_image, color: Colors.grey, size: 48), Gap(8), Text('File tidak ditemukan', style: TextStyle(color: Colors.grey))])),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), border: Border(top: BorderSide(color: AppTheme.surfaceLight))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.paths.length > 1) ...[
                  IconButton(icon: const Icon(Icons.chevron_left, color: Colors.white), onPressed: _currentIndex > 0 ? () => _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut) : null),
                  Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), decoration: BoxDecoration(color: AppTheme.surfaceLight, borderRadius: BorderRadius.circular(12)), child: Text('${_currentIndex + 1} / ${widget.paths.length}', style: const TextStyle(color: Colors.white, fontSize: 12))),
                  IconButton(icon: const Icon(Icons.chevron_right, color: Colors.white), onPressed: _currentIndex < widget.paths.length - 1 ? () => _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut) : null),
                ],
                const Gap(16),
                ElevatedButton.icon(
                  onPressed: _isSharing
                      ? null
                      : () => _sharePhotos([widget.paths[_currentIndex]]),
                  icon: const Icon(Icons.share, size: 18), label: const Text('Bagikan Foto'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
                ),
                const Gap(8),
                if (widget.paths.length > 1)
                  ElevatedButton.icon(
                    onPressed: _isSharing ? null : () => _sharePhotos(widget.paths),
                    icon: const Icon(Icons.share, size: 18), label: const Text('Bagikan Semua'),
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentBlue, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Video Preview Dialog ─────────────────────────────────
class _VideoPreviewDialog extends StatefulWidget {
  final String videoPath;
  final String barcode;
  final DateTime timestamp;
  const _VideoPreviewDialog({required this.videoPath, required this.barcode, required this.timestamp});

  @override
  State<_VideoPreviewDialog> createState() => _VideoPreviewDialogState();
}

class _VideoPreviewDialogState extends State<_VideoPreviewDialog> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _isPlaying = false;
  bool _isLoading = true;
  bool _isSharing = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    final generation = ++_loadGeneration;
    final previous = _controller;
    _controller = null;
    if (previous != null) {
      previous.removeListener(_onVideoChanged);
      await previous.dispose();
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _initialized = false;
      _isPlaying = false;
      _isLoading = true;
      _error = null;
    });

    VideoPlayerController? controller;
    try {
      final file = File(widget.videoPath);
      if (!await file.exists() || await file.length() <= 0) {
        throw FileSystemException('File video tidak ditemukan atau kosong');
      }
      controller = VideoPlayerController.file(file);
      await controller.initialize();
      if (!mounted || generation != _loadGeneration) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      controller.addListener(_onVideoChanged);
      setState(() {
        _initialized = true;
        _isLoading = false;
      });
    } catch (e) {
      if (controller != null) await controller.dispose();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _initialized = false;
        _isLoading = false;
        _error = 'Video rusak atau tidak dapat diputar';
      });
    }
  }

  void _onVideoChanged() {
    final isPlaying = _controller?.value.isPlaying ?? false;
    if (mounted && isPlaying != _isPlaying) {
      setState(() => _isPlaying = isPlaying);
    }
  }

  void _toggleVideo() {
    final controller = _controller;
    if (!_initialized || controller == null) return;
    controller.value.isPlaying ? controller.pause() : controller.play();
  }

  Future<void> _shareVideo() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final file = File(widget.videoPath);
      if (!await file.exists() || await file.length() <= 0) {
        throw FileSystemException('File video tidak ditemukan atau kosong');
      }
      await Share.shareXFiles(
        [XFile(file.path)],
        text: '${widget.barcode}\n${DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.timestamp)}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal membagikan video: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _controller?.removeListener(_onVideoChanged);
    _controller?.dispose();
    super.dispose();
  }

  Widget _buildVideoBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const Gap(12),
            Text(_error!, style: const TextStyle(color: Colors.grey)),
            const Gap(12),
            ElevatedButton(
              onPressed: _initializeVideo,
              child: const Text('Coba Lagi'),
            ),
          ],
        ),
      );
    }
    final controller = _controller;
    if (!_initialized || controller == null) {
      return const Center(
        child: Text('Video tidak tersedia', style: TextStyle(color: Colors.grey)),
      );
    }
    final aspectRatio = controller.value.aspectRatio;
    return GestureDetector(
      onTap: _toggleVideo,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspectRatio > 0 ? aspectRatio : 16 / 9,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), border: Border(bottom: BorderSide(color: AppTheme.surfaceLight))),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.barcode, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.timestamp), style: const TextStyle(color: Colors.grey, fontSize: 11)),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          Expanded(
            child: _buildVideoBody(),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), border: Border(top: BorderSide(color: AppTheme.surfaceLight))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                  onPressed: _initialized ? _toggleVideo : null,
                ),
                ElevatedButton.icon(
                  onPressed: _isSharing ? null : _shareVideo,
                  icon: const Icon(Icons.share, size: 18), label: const Text('Bagikan Video'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accentBlue, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
