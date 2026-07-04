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
  bool _disposed = false;

  // Persistence (opsional, untuk nanti)
  final TaskPersister? persister;

  TaskQueue({this.maxWorkers = 2, this.persister});

  Stream<Task> get statusStream => _statusController.stream;
  Stream<void> get doneStream => _doneController.stream;

  /// Emit status secara aman — no-op jika queue sudah di-dispose atau
  /// stream sudah ditutup, supaya task yang masih berjalan di background
  /// tidak crash saat mencoba melapor setelah widget pemiliknya dispose.
  void _emitStatus(Task task) {
    if (_disposed || _statusController.isClosed) return;
    _statusController.add(task);
  }

  void _emitDone() {
    if (_disposed || _doneController.isClosed) return;
    _doneController.add(null);
  }

  String add<T>({
    required String label,
    required Future<T> Function() work,
    TaskPriority priority = TaskPriority.normal,
    int maxRetries = 3,
    void Function(T result)? onSuccess,
    void Function(Object error)? onError,
  }) {
    if (_disposed) {
      debugPrint('⚠️ TaskQueue sudah di-dispose, task "$label" diabaikan');
      return '';
    }
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
    _emitStatus(task);
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
      _emitStatus(task);
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
      _emitStatus(task);
    }
    _persistPending();
  }

  int get pendingCount => _queue.length;
  int get runningCount => _running;

  Future<void> _processQueue() async {
    if (_disposed) return;
    if (_running >= maxWorkers || _queue.isEmpty) return;

    final task = _queue.removeFirst();
    if (task.status == TaskStatus.cancelled) {
      _processQueue();
      return;
    }

    _running++;
    task.status = TaskStatus.running;
    _emitStatus(task);
    _persistPending();

    try {
      final result = await task.work();
      task.status = TaskStatus.completed;
      task.result = result;
      if (task.onSuccess != null) task.onSuccess!(result);
    } catch (e) {
      if (task.retryCount < task.maxRetries && !_disposed) {
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
      _emitStatus(task);
      _persistPending();

      if (_queue.isEmpty && _running == 0) {
        _emitDone();
      }

      if (_disposed) {
        // dispose() dipanggil selagi task ini masih berjalan di background
        // (mis. widget-nya sudah ditutup user sebelum FFmpeg selesai).
        // Tutup stream sekarang, setelah task terakhir yang berjalan
        // benar-benar selesai, supaya tidak ada event yang coba dikirim
        // ke controller yang sudah closed.
        if (_running == 0 &&
            !_statusController.isClosed &&
            !_doneController.isClosed) {
          _statusController.close();
          _doneController.close();
        }
      } else {
        _processQueue();
      }
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
    _disposed = true;

    // Batalkan task yang masih menunggu di antrian (belum sempat berjalan)
    // dan panggil onError-nya, supaya pemanggil (mis. PhotoScanScreen)
    // tetap sempat membersihkan file pending miliknya alih-alih
    // meninggalkannya menggantung selamanya.
    final stillPending = _queue.toList();
    _queue.clear();
    for (final task in stillPending) {
      task.status = TaskStatus.cancelled;
      if (task.onError != null) {
        try {
          task.onError!(Exception('Dibatalkan: layar ditutup'));
        } catch (_) {}
      }
    }

    if (_running == 0) {
      // Tidak ada task yang sedang berjalan → aman ditutup sekarang.
      if (!_statusController.isClosed) _statusController.close();
      if (!_doneController.isClosed) _doneController.close();
    }
    // Jika masih ada task yang berjalan, penutupan stream ditunda dan
    // dilakukan otomatis oleh _processQueue() begitu task itu selesai
    // (lihat blok `finally` di atas).
  }
}

// ─── Persistence Interface (untuk pengembangan nanti) ──────

abstract class TaskPersister {
  Future<void> save(List<Task> tasks);
  Future<List<Task>> load();
}
