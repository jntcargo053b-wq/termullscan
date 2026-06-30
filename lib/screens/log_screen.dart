// ============================================================
// lib/screens/log_screen.dart (ENHANCED – SORTING & SEARCH NOTE/ADDRESS)
// ============================================================
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:collection/collection.dart';
import 'package:video_player/video_player.dart';
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
  String _sortField = 'timestamp';
  String _sortDir = 'DESC';

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
        sortField: _sortField,
        sortDir: _sortDir,
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

  void _setSorting(String field, String dir) {
    setState(() {
      _sortField = field;
      _sortDir = dir;
    });
    _currentPage = 0;
    _filteredEntries.clear();
    _hasMore = true;
    _loadEntries(refresh: true);
  }

  // ... (selection, preview, share, delete methods tetap sama) ...

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
            IconButton(icon: const Icon(Icons.share, color: Colors.green), onPressed: _shareSelectedPhotos),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: _deleteSelected),
          ] else ...[
            IconButton(icon: const Icon(Icons.share), onPressed: _exportAndShare),
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
                    hintText: '🔍 Cari barcode, catatan, atau alamat...',
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
                    : ListView.builder(
                        controller: _scrollController,
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
