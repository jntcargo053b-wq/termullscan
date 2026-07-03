import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

enum TaskStatus { pending, running, completed, failed, cancelled }

class Task<T> {
  final String id;
  final String label;
  final Future<T> Function() work;
  final void Function(T result)? onSuccess;
  final void Function(Object error)? onError;
  TaskStatus status;
  Object? error;
  T? result;

  Task({
    required this.id,
    required this.label,
    required this.work,
    this.onSuccess,
    this.onError,
  }) : status = TaskStatus.pending;
}

class TaskQueue {
  final Queue<Task> _queue = Queue();
  int _running = 0;
  final int maxWorkers;

  final _statusController = StreamController<Task>.broadcast();
  Stream<Task> get statusStream => _statusController.stream;

  final _doneController = StreamController<void>.broadcast();
  Stream<void> get doneStream => _doneController.stream;

  TaskQueue({this.maxWorkers = 2});

  String add<T>({
    required String label,
    required Future<T> Function() work,
    void Function(T result)? onSuccess,
    void Function(Object error)? onError,
  }) {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final task = Task<T>(
      id: id,
      label: label,
      work: work,
      onSuccess: onSuccess,
      onError: onError,
    );
    _queue.add(task);
    _statusController.add(task);
    _processQueue();
    return id;
  }

  bool cancel(String id) {
    final task = _queue.firstWhereOrNull((t) => t.id == id && t.status == TaskStatus.pending);
    if (task != null) {
      task.status = TaskStatus.cancelled;
      _queue.remove(task);
      _statusController.add(task);
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
  }

  int get pendingCount => _queue.length;
  int get runningCount => _running;

  void clearCompleted() {
    _queue.removeWhere((t) =>
        t.status == TaskStatus.completed ||
        t.status == TaskStatus.failed ||
        t.status == TaskStatus.cancelled);
  }

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

    try {
      final result = await task.work();
      task.status = TaskStatus.completed;
      task.result = result;
      if (task.onSuccess != null) {
        task.onSuccess!(result);
      }
    } catch (e) {
      task.status = TaskStatus.failed;
      task.error = e;
      if (task.onError != null) {
        task.onError!(e);
      }
      debugPrint('❌ Task "${task.label}" gagal: $e');
    } finally {
      _running--;
      _statusController.add(task);

      if (_queue.isEmpty && _running == 0) {
        _doneController.add(null);
      }

      _processQueue();
    }
  }

  void dispose() {
    _statusController.close();
    _doneController.close();
  }
}

extension _QueueExtension<T> on Queue<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}
