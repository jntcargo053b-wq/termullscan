// ============================================================
// lib/screens/log_screen.dart (FINAL – VIDEO SUPPORT)
// ============================================================
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:collection/collection.dart';
import 'package:video_player/video_player.dart'; // ← video player
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
  List<ScanEntry> _filteredEntries = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;

  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  String _searchQuery = '';
  String _filterPeriod = 'Semua';

  int _currentPage = 0;
  final int _pageSize = 20;
  bool _hasMore = true;

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
    if (refresh) {
      _currentPage = 0;
      _filteredEntries.clear();
      _hasMore = true;
    }
    if (!_hasMore || _isLoadingMore) return;

    setState(() => _isLoadingMore = true);

    try {
      final offset = _currentPage * _pageSize;
      final newEntries = await _storage.getEntries(
        limit: _pageSize,
        offset: offset,
        searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
        period: _filterPeriod != 'Semua' ? _filterPeriod : null,
      );

      final totalCount = await _storage.getCount(
        searchQuery: _searchQuery.isNotEmpty ? _searchQuery : null,
        period: _filterPeriod != 'Semua' ? _filterPeriod : null,
      );

      if (refresh) {
        _filteredEntries = newEntries;
      } else {
        _filteredEntries.addAll(newEntries);
      }

      _hasMore = _filteredEntries.length < totalCount;
      _currentPage++;
      debugPrint('📊 Loaded ${newEntries.length} entries, total: $totalCount');
    } catch (e) {
      debugPrint('Error loading entries: $e');
      if (refresh) _filteredEntries = [];
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
        });
      }
    }
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _searchQuery = value.trim();
      _currentPage = 0;
      _filteredEntries.clear();
      _hasMore = true;
      _loadEntries(refresh: true);
      if (_isSelectionMode) _toggleSelectionMode();
    });
  }

  void _setFilterPeriod(String period) {
    setState(() => _filterPeriod = period);
    _currentPage = 0;
    _filteredEntries.clear();
    _hasMore = true;
    _loadEntries(refresh: true);
    if (_isSelectionMode) _toggleSelectionMode();
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

  // ─── PREVIEW FOTO ──────────────────────────────────────────
  void _showPhotoPreview(ScanEntry entry, {int initialIndex = 0}) {
    final List<String> paths = entry.photoPaths ?? [];
    if (paths.isEmpty && entry.type == ScanType.photo && entry.value.isNotEmpty) {
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
      final file = File(p);
      if (file.existsSync()) validPaths.add(p);
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

  // ─── PREVIEW VIDEO ─────────────────────────────────────────
  void _showVideoPreview(ScanEntry entry) {
    final path = entry.videoPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
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

  // ─── SHARE FOTO ──────────────────────────────────────────
  Future<void> _shareSelectedPhotos() async {
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
        .where((e) => _selectedIds.contains(e.id) && e.type == ScanType.photo)
        .toList();

    if (selectedEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Item yang dipilih bukan foto. Pilih item dengan ikon kamera.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final List<XFile> files = [];
    for (final entry in selectedEntries) {
      final paths = entry.photoPaths ?? [];
      if (paths.isNotEmpty) {
        for (final path in paths) {
          final file = File(path);
          if (await file.exists()) files.add(XFile(file.path));
        }
      } else if (entry.type == ScanType.photo && entry.value.isNotEmpty) {
        final file = File(entry.value);
        if (await file.exists()) files.add(XFile(file.path));
      }
    }

    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File foto tidak ditemukan atau sudah dihapus.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Menyiapkan ${files.length} foto untuk dibagikan...'),
          duration: const Duration(seconds: 1),
        ),
      );

      if (files.length == 1) {
        await Share.shareXFiles(
          files,
          text: '📸 Hasil scan dari WH Scanner\n'
              'Waktu: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
        );
      } else {
        await Share.shareXFiles(
          files,
          text: '📸 ${files.length} foto hasil scan dari WH Scanner\n'
              'Waktu: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
        );
      }

      _toggleSelectionMode();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Berhasil share ${files.length} foto'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint('❌ Share error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Gagal share: ${e.toString().split(':').last}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ─── EXPORT TEXT ──────────────────────────────────────────
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

  // ─── DELETE ──────────────────────────────────────────────
  Future<void> _deleteEntry(ScanEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus Data'),
        content: Text('Hapus scan "${entry.value}"?'),
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
      // Hapus file
      if (entry.type == ScanType.photo) {
        final paths = entry.photoPaths ?? [];
        if (paths.isNotEmpty) {
          for (final path in paths) {
            try { final f = File(path); if (await f.exists()) await f.delete(); } catch (_) {}
          }
        } else if (entry.value.isNotEmpty) {
          try { final f = File(entry.value); if (await f.exists()) await f.delete(); } catch (_) {}
        }
      } else if (entry.type == ScanType.video) {
        if (entry.videoPath != null) {
          try { final f = File(entry.videoPath!); if (await f.exists()) await f.delete(); } catch (_) {}
        }
        if (entry.videoThumbnail != null) {
          try { final f = File(entry.videoThumbnail!); if (await f.exists()) await f.delete(); } catch (_) {}
        }
      }
      _selectedIds.remove(entry.id);
      _loadEntries(refresh: true);
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
        final entry = _filteredEntries.firstWhereOrNull((e) => e.id == id);
        if (entry != null) {
          if (entry.type == ScanType.photo) {
            final paths = entry.photoPaths ?? [];
            if (paths.isNotEmpty) {
              for (final path in paths) {
                try { final f = File(path); if (await f.exists()) await f.delete(); } catch (_) {}
              }
            } else if (entry.value.isNotEmpty) {
              try { final f = File(entry.value); if (await f.exists()) await f.delete(); } catch (_) {}
            }
          } else if (entry.type == ScanType.video) {
            if (entry.videoPath != null) {
              try { final f = File(entry.videoPath!); if (await f.exists()) await f.delete(); } catch (_) {}
            }
            if (entry.videoThumbnail != null) {
              try { final f = File(entry.videoThumbnail!); if (await f.exists()) await f.delete(); } catch (_) {}
            }
          }
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
                if (_filteredEntries.isNotEmpty) _toggleSelectionMode();
              },
              tooltip: 'Pilih foto untuk dibagikan',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _loadEntries(refresh: true),
              tooltip: 'Refresh',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // ─── SEARCH & FILTER ──────────────────────────────
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '🔍 Cari barcode, nama file, atau tanggal...',
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
          // ─── LIST ──────────────────────────────────────────
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
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: _filteredEntries.length + (_hasMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _filteredEntries.length) {
                            return const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          }
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
                                : () {
                                    if (entry.type == ScanType.video) {
                                      _showVideoPreview(entry);
                                    } else {
                                      _showPhotoPreview(entry);
                                    }
                                  },
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

// ─── Filter Chip ──────────────────────────────────────────────
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
        onSelected: (_) => onSelected(),
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

// ─── Log Item (UPDATED UNTUK VIDEO) ─────────────────────────
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
    final isVideo = entry.type == ScanType.video;
    final icon = isVideo
        ? Icons.videocam
        : isPhoto
            ? Icons.photo_camera
            : Icons.qr_code;
    final avatarColor = isVideo
        ? Colors.red.shade900
        : isPhoto
            ? Colors.blue.shade900
            : Colors.amber.shade900;
    final hasPhoto = entry.photoPaths != null && entry.photoPaths!.isNotEmpty;
    final hasVideo = entry.videoPath != null && entry.videoPath!.isNotEmpty;

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
            Stack(
              children: [
                CircleAvatar(
                  backgroundColor: avatarColor,
                  child: Icon(icon, color: Colors.white),
                ),
                if (isVideo && entry.videoThumbnail != null)
                  CircleAvatar(
                    backgroundColor: Colors.transparent,
                    backgroundImage: FileImage(File(entry.videoThumbnail!)),
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
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isVideo && entry.videoDuration != null) ...[
              const Gap(6),
              Icon(Icons.timer, size: 14, color: Colors.grey),
              const Gap(2),
              Text(
                entry.videoDurationFormatted,
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ],
            if (hasPhoto) ...[
              const Gap(6),
              Icon(Icons.photo_library, size: 16, color: Colors.amber.shade400),
            ],
            if (entry.photoPaths != null && entry.photoPaths!.length > 1) ...[
              const Gap(2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${entry.photoPaths!.length}',
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
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

// ─── Photo Preview Dialog ──────────────────────────────────
class _PhotoPreviewDialog extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  final String barcode;
  final DateTime timestamp;
  const _PhotoPreviewDialog({
    required this.paths,
    required this.initialIndex,
    required this.barcode,
    required this.timestamp,
  });

  @override
  State<_PhotoPreviewDialog> createState() => _PhotoPreviewDialogState();
}

class _PhotoPreviewDialogState extends State<_PhotoPreviewDialog> {
  late PageController _pageController;
  late int _currentIndex;

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
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.8),
              border: Border(bottom: BorderSide(color: Colors.grey.shade800)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.barcode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.timestamp),
                        style: const TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
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
                  panEnabled: true,
                  scaleEnabled: true,
                  minScale: 0.5,
                  maxScale: 3.0,
                  child: Center(
                    child: Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey.shade900,
                        child: const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.broken_image, color: Colors.grey, size: 48),
                              Gap(8),
                              Text('File tidak ditemukan', style: TextStyle(color: Colors.grey)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.8),
              border: Border(top: BorderSide(color: Colors.grey.shade800)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.paths.length > 1) ...[
                  IconButton(
                    icon: const Icon(Icons.chevron_left, color: Colors.white),
                    onPressed: _currentIndex > 0
                        ? () => _pageController.previousPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          )
                        : null,
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade800,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_currentIndex + 1} / ${widget.paths.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right, color: Colors.white),
                    onPressed: _currentIndex < widget.paths.length - 1
                        ? () => _pageController.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          )
                        : null,
                  ),
                ],
                const Gap(16),
                ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      final file = File(widget.paths[_currentIndex]);
                      if (await file.exists()) {
                        await Share.shareXFiles(
                          [XFile(file.path)],
                          text: '📸 ${widget.barcode}\n${DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.timestamp)}',
                        );
                      }
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Gagal share: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Share Foto'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                ),
                const Gap(8),
                if (widget.paths.length > 1)
                  ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        final allFiles = <XFile>[];
                        for (final p in widget.paths) {
                          final f = File(p);
                          if (await f.exists()) {
                            allFiles.add(XFile(f.path));
                          }
                        }
                        if (allFiles.isNotEmpty) {
                          await Share.shareXFiles(
                            allFiles,
                            text: '📸 ${widget.barcode} - ${allFiles.length} foto',
                          );
                        }
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Gagal share semua: $e')),
                        );
                      }
                    },
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share Semua'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── VIDEO PREVIEW DIALOG ─────────────────────────────────
class _VideoPreviewDialog extends StatefulWidget {
  final String videoPath;
  final String barcode;
  final DateTime timestamp;
  const _VideoPreviewDialog({
    required this.videoPath,
    required this.barcode,
    required this.timestamp,
  });

  @override
  State<_VideoPreviewDialog> createState() => _VideoPreviewDialogState();
}

class _VideoPreviewDialogState extends State<_VideoPreviewDialog> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
      });
    _controller.addListener(() {
      if (mounted && _controller.value.isPlaying != _isPlaying) {
        setState(() => _isPlaying = _controller.value.isPlaying);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.8),
              border: Border(bottom: BorderSide(color: Colors.grey.shade800)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.barcode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.timestamp),
                        style: const TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          // Video
          Expanded(
            child: _initialized
                ? GestureDetector(
                    onTap: () {
                      setState(() {
                        if (_controller.value.isPlaying) {
                          _controller.pause();
                        } else {
                          _controller.play();
                        }
                      });
                    },
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),
                  )
                : const Center(
                    child: CircularProgressIndicator(),
                  ),
          ),
          // Controls
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.8),
              border: Border(top: BorderSide(color: Colors.grey.shade800)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    if (_controller.value.isPlaying) {
                      _controller.pause();
                    } else {
                      _controller.play();
                    }
                  },
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      final file = File(widget.videoPath);
                      if (await file.exists()) {
                        await Share.shareXFiles(
                          [XFile(file.path)],
                          text: '🎥 ${widget.barcode}\n${DateFormat('dd/MM/yyyy HH:mm:ss').format(widget.timestamp)}',
                        );
                      }
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Gagal share: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Share Video'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
