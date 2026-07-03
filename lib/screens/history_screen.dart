// lib/screens/history_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/history_provider.dart';
import '../models/scan_entry.dart';

class HistoryScreen extends StatefulWidget {
  @override
  _HistoryScreenState createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Load data pertama kali
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<HistoryProvider>().refreshEntries();
    });
    // Listener scroll untuk lazy load
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      context.read<HistoryProvider>().loadNextPage();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('History')),
      body: Consumer<HistoryProvider>(
        builder: (context, provider, child) {
          if (provider.entries.isEmpty && provider.isLoading) {
            return Center(child: CircularProgressIndicator());
          }
          if (provider.entries.isEmpty && !provider.hasMore) {
            return Center(child: Text('Tidak ada data'));
          }
          return ListView.builder(
            controller: _scrollController,
            itemCount: provider.entries.length + (provider.hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == provider.entries.length) {
                // Indikator loading di akhir
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final entry = provider.entries[index];
              return ListTile(
                title: Text(entry.value),
                subtitle: Text(entry.locationName ?? ''),
                trailing: Text(entry.createdAt.toString()),
              );
            },
          );
        },
      ),
    );
  }
}
