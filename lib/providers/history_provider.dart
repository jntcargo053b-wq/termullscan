// lib/providers/history_provider.dart
import 'package:flutter/foundation.dart';
import '../models/scan_entry.dart';
import '../services/database_service.dart';

class HistoryProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  List<ScanEntry> _entries = [];
  bool _hasMore = true;
  bool _isLoading = false;
  int _page = 0;
  static const int _limit = 50;

  List<ScanEntry> get entries => _entries;
  bool get hasMore => _hasMore;
  bool get isLoading => _isLoading;

  /// Load halaman pertama (reset state).
  Future<void> refreshEntries() async {
    _page = 0;
    _entries.clear();
    _hasMore = true;
    await loadNextPage();
  }

  /// Load halaman berikutnya.
  Future<void> loadNextPage() async {
    if (_isLoading || !_hasMore) return;
    _isLoading = true;
    notifyListeners();

    try {
      final offset = _page * _limit;
      final newEntries = await _db.getEntries(limit: _limit, offset: offset);
      if (newEntries.length < _limit) {
        _hasMore = false;
      }
      _entries.addAll(newEntries);
      _page++;
    } catch (e) {
      debugPrint('Gagal load data: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
