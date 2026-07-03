import 'scan_entry.dart';

class HistoryState {
  final List<ScanEntry> items;
  final int currentPage;
  final int totalItems;
  final bool isLoading;
  final bool hasMore;
  final String? searchQuery;
  final String? period;
  final String sortField;
  final String sortDir;

  HistoryState({
    this.items = const [],
    this.currentPage = 0,
    this.totalItems = 0,
    this.isLoading = false,
    this.hasMore = true,
    this.searchQuery,
    this.period,
    this.sortField = 'timestamp',
    this.sortDir = 'DESC',
  });

  HistoryState copyWith({
    List<ScanEntry>? items,
    int? currentPage,
    int? totalItems,
    bool? isLoading,
    bool? hasMore,
    String? searchQuery,
    String? period,
    String? sortField,
    String? sortDir,
  }) {
    return HistoryState(
      items: items ?? this.items,
      currentPage: currentPage ?? this.currentPage,
      totalItems: totalItems ?? this.totalItems,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      searchQuery: searchQuery ?? this.searchQuery,
      period: period ?? this.period,
      sortField: sortField ?? this.sortField,
      sortDir: sortDir ?? this.sortDir,
    );
  }
}
