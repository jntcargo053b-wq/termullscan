import 'package:flutter/material.dart';
import '../models/scan_entry.dart';
import '../models/history_state.dart';
import '../services/database_helper.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({Key? key}) : super(key: key);

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final DatabaseHelper _db = DatabaseHelper();
  final ScrollController _scrollController = ScrollController();
  final int _pageSize = 50;

  HistoryState _state = HistoryState();

  @override
  void initState() {
    super.initState();
    _loadFirstPage();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ─── Lazy Load Logic ────────────────────────────────────

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_state.isLoading && _state.hasMore) {
        _loadMore();
      }
    }
  }

  Future<void> _loadFirstPage() async {
    setState(() => _state = _state.copyWith(isLoading: true, items: []));
    try {
      final total = await _db.getCount(
        searchQuery: _state.searchQuery,
        period: _state.period,
      );
      final items = await _db.getEntries(
        limit: _pageSize,
        offset: 0,
        searchQuery: _state.searchQuery,
        period: _state.period,
        sortField: _state.sortField,
        sortDir: _state.sortDir,
      );
      setState(() {
        _state = _state.copyWith(
          items: items,
          totalItems: total,
          currentPage: 0,
          hasMore: items.length < total,
          isLoading: false,
        );
      });
    } catch (e) {
      setState(() => _state = _state.copyWith(isLoading: false));
      _showError('Gagal memuat data: $e');
    }
  }

  Future<void> _loadMore() async {
    if (_state.isLoading || !_state.hasMore) return;
    setState(() => _state = _state.copyWith(isLoading: true));
    try {
      final offset = (_state.currentPage + 1) * _pageSize;
      final moreItems = await _db.getEntries(
        limit: _pageSize,
        offset: offset,
        searchQuery: _state.searchQuery,
        period: _state.period,
        sortField: _state.sortField,
        sortDir: _state.sortDir,
      );
      final newItems = List<ScanEntry>.from(_state.items)..addAll(moreItems);
      final hasMore = newItems.length < _state.totalItems;
      setState(() {
        _state = _state.copyWith(
          items: newItems,
          currentPage: _state.currentPage + 1,
          hasMore: hasMore,
          isLoading: false,
        );
      });
    } catch (e) {
      setState(() => _state = _state.copyWith(isLoading: false));
      _showError('Gagal memuat lebih banyak: $e');
    }
  }

  Future<void> _refresh() async {
    await _loadFirstPage();
  }

  void _applyFilter({
    String? searchQuery,
    String? period,
    String? sortField,
    String? sortDir,
  }) {
    setState(() {
      _state = _state.copyWith(
        searchQuery: searchQuery ?? _state.searchQuery,
        period: period ?? _state.period,
        sortField: sortField ?? _state.sortField,
        sortDir: sortDir ?? _state.sortDir,
      );
    });
    _loadFirstPage();
  }

  // ─── UI ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: () => _showFilterDialog(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_state.isLoading && _state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_state.items.isEmpty) {
      return const Center(child: Text('Belum ada data scan'));
    }
    return ListView.builder(
      controller: _scrollController,
      itemCount: _state.items.length + (_state.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _state.items.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16.0),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final entry = _state.items[index];
        return _buildEntryTile(entry);
      },
    );
  }

  Widget _buildEntryTile(ScanEntry entry) {
    return ListTile(
      leading: CircleAvatar(
        child: Text(entry.type?.substring(0, 1) ?? '?'),
      ),
      title: Text(
        entry.value,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.locationName ?? 'Tidak ada lokasi'),
          Text(
            _formatDate(entry.timestamp),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(entry.id),
      ),
    );
  }

  // ─── Filter Dialog ──────────────────────────────────────

  void _showFilterDialog() {
    final searchController = TextEditingController(text: _state.searchQuery);
    String? selectedPeriod = _state.period;
    String selectedSort = _state.sortField;
    String selectedDir = _state.sortDir;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Filter & Urutkan'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: searchController,
              decoration: const InputDecoration(
                labelText: 'Cari (value, lokasi, catatan)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: selectedPeriod,
              decoration: const InputDecoration(labelText: 'Periode'),
              items: const [
                DropdownMenuItem(value: null, child: Text('Semua')),
                DropdownMenuItem(value: 'Hari ini', child: Text('Hari ini')),
                DropdownMenuItem(value: 'Minggu ini', child: Text('Minggu ini')),
                DropdownMenuItem(value: 'Bulan ini', child: Text('Bulan ini')),
              ],
              onChanged: (val) => selectedPeriod = val,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: selectedSort,
                    decoration: const InputDecoration(labelText: 'Urutkan'),
                    items: const [
                      DropdownMenuItem(value: 'timestamp', child: Text('Waktu')),
                      DropdownMenuItem(value: 'value', child: Text('Nilai')),
                    ],
                    onChanged: (val) => selectedSort = val!,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: selectedDir,
                    decoration: const InputDecoration(labelText: 'Arah'),
                    items: const [
                      DropdownMenuItem(value: 'DESC', child: Text('Terbaru')),
                      DropdownMenuItem(value: 'ASC', child: Text('Terlama')),
                    ],
                    onChanged: (val) => selectedDir = val!,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _applyFilter(
                searchQuery: searchController.text.trim().isEmpty
                    ? null
                    : searchController.text.trim(),
                period: selectedPeriod,
                sortField: selectedSort,
                sortDir: selectedDir,
              );
            },
            child: const Text('Terapkan'),
          ),
        ],
      ),
    );
  }

  // ─── Delete ──────────────────────────────────────────────

  Future<void> _confirmDelete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus data?'),
        content: const Text('Data ini akan dihapus permanen.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await _db.delete(id);
        // Hapus dari list lokal
        setState(() {
          _state = _state.copyWith(
            items: _state.items.where((e) => e.id != id).toList(),
            totalItems: _state.totalItems - 1,
          );
        });
      } catch (e) {
        _showError('Gagal menghapus: $e');
      }
    }
  }

  // ─── Helpers ─────────────────────────────────────────────

  String _formatDate(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }
}
