import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

enum TaskPriority { high, normal, low }
enum TaskStatus { pending, running, completed, failed, cancelled }

class Task<T> {
  final String id;
  final String label;
  final TaskPriority priority;
  final int maxRetries;
  int retryCount = 0;
  final Future<T> Function() work;
  final void Function(T result)? onSuccess;
  final void Function(Object error)? onError;
  TaskStatus status = TaskStatus.pending;
  Object? error;
  T? result;

  Task({
    required this.id,
    required this.label,
    this.priority = TaskPriority.normal,
    this.maxRetries = 3,
    required this.work,
    this.onSuccess,
    this.onError,
  });
}

class TaskQueue {
  final Queue<Task> _queue = Queue();
  int _running = 0;
  final int maxWorkers;
  final _statusController = StreamController<Task>.broadcast();
  final _doneController = StreamController<void>.broadcast();

  // Persistence (opsional, untuk nanti)
  final TaskPersister? persister;

  TaskQueue({this.maxWorkers = 2, this.persister});

  Stream<Task> get statusStream => _statusController.stream;
  Stream<void> get doneStream => _doneController.stream;

  String add<T>({
    required String label,
    required Future<T> Function() work,
    TaskPriority priority = TaskPriority.normal,
    int maxRetries = 3,
    void Function(T result)? onSuccess,
    void Function(Object error)? onError,
  }) {
    final id = const Uuid().v4();
    final task = Task<T>(
      id: id,
      label: label,
      priority: priority,
      maxRetries: maxRetries,
      work: work,
      onSuccess: onSuccess,
      onError: onError,
    );
    _queue.add(task);
    _sortQueue();
    _statusController.add(task);
    _persistPending();
    _processQueue();
    return id;
  }

  void _sortQueue() {
    final list = _queue.toList();
    list.sort((a, b) => a.priority.index.compareTo(b.priority.index));
    _queue.clear();
    _queue.addAll(list);
  }

  /// Cari tugas berdasarkan ID (hanya untuk pending)
  Task? _findPendingTask(String id) {
    for (final task in _queue) {
      if (task.id == id && task.status == TaskStatus.pending) {
        return task;
      }
    }
    return null;
  }

  bool cancel(String id) {
    final task = _findPendingTask(id);
    if (task != null) {
      task.status = TaskStatus.cancelled;
      _queue.remove(task);
      _statusController.add(task);
      _persistPending();
      return true;
    }
    return false;
  }

  void cancelAllPending() {
    final toRemove = _queue.where((t) => t.status == TaskStatus.pending).toList();
    for (final task in toRemove) {
      task.status = TaskStatus.cancelled;
      _queue.remove(task);
      _statusController.add(task);
    }
    _persistPending();
  }

  int get pendingCount => _queue.length;
  int get runningCount => _running;

  Future<void> _processQueue() async {
    if (_running >= maxWorkers || _queue.isEmpty) return;

    final task = _queue.removeFirst();
    if (task.status == TaskStatus.cancelled) {
      _processQueue();
      return;
    }

    _running++;
    task.status = TaskStatus.running;
    _statusController.add(task);
    _persistPending();

    try {
      final result = await task.work();
      task.status = TaskStatus.completed;
      task.result = result;
      if (task.onSuccess != null) task.onSuccess!(result);
    } catch (e) {
      if (task.retryCount < task.maxRetries) {
        task.retryCount++;
        task.status = TaskStatus.pending;
        _queue.addFirst(task);
        _sortQueue();
        debugPrint('🔄 Retry ${task.retryCount}/${task.maxRetries} for "${task.label}"');
      } else {
        task.status = TaskStatus.failed;
        task.error = e;
        if (task.onError != null) task.onError!(e);
        debugPrint('❌ Task "${task.label}" gagal permanen: $e');
      }
    } finally {
      _running--;
      _statusController.add(task);
      _persistPending();

      if (_queue.isEmpty && _running == 0) {
        _doneController.add(null);
      }
      _processQueue();
    }
  }

  // ─── Persistence (placeholder) ──────────────────────────

  Future<void> _persistPending() async {
    if (persister == null) return;
    final pending = _queue.where((t) => t.status == TaskStatus.pending).toList();
    await persister!.save(pending);
  }

  Future<void> loadPending() async {
    if (persister == null) return;
    final tasks = await persister!.load();
    for (final task in tasks) {
      _queue.add(task);
    }
    _sortQueue();
    _processQueue();
  }

  void dispose() {
    _statusController.close();
    _doneController.close();
  }
}

// ─── Persistence Interface (untuk pengembangan nanti) ──────

abstract class TaskPersister {
  Future<void> save(List<Task> tasks);
  Future<List<Task>> load();
}
