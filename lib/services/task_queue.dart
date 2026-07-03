// lib/services/task_queue.dart
import 'dart:async';
import 'package:flutter/foundation.dart';

class TaskQueue {
  static final TaskQueue _instance = TaskQueue._internal();
  factory TaskQueue() => _instance;
  TaskQueue._internal();

  final List<Future<void>> _tasks = [];
  bool _isRunning = false;

  Future<void> add(Future<void> Function() task) async {
    final completer = Completer<void>();
    _tasks.add(completer.future);
    _processQueue();
    try {
      await task();
      completer.complete();
    } catch (e) {
      completer.completeError(e);
    }
  }

  Future<void> _processQueue() async {
    if (_isRunning || _tasks.isEmpty) return;
    _isRunning = true;
    while (_tasks.isNotEmpty) {
      final future = _tasks.removeAt(0);
      try {
        await future;
      } catch (_) {}
    }
    _isRunning = false;
  }
}
