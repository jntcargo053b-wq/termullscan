import 'package:flutter/material.dart';
import '../../models/video_job.dart';
import '../../services/database/job_database.dart';

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final JobDatabase _database = JobDatabase();
  List<VideoJob> _jobs = const [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadJobs();
  }

  Future<void> _loadJobs() async {
    final jobs = await _database.getJobs();
    if (!mounted) return;
    setState(() {
      _jobs = jobs;
      _isLoading = false;
    });
  }

  Future<void> _clearCompleted() async {
    await _database.clearCompleted();
    await _loadJobs();
  }

  Future<void> _setStatus(VideoJob job, JobStatus status) async {
    await _database.updateJob(
      job.copyWith(
        status: status,
        progress: status == JobStatus.pending ? 0 : job.progress,
        errorMessage: status == JobStatus.pending ? '' : job.errorMessage,
        updatedAt: DateTime.now(),
      ),
    );
    await _loadJobs();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          IconButton(
            onPressed: _clearCompleted,
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Bersihkan yang selesai',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _jobs.isEmpty
              ? const Center(child: Text('Tidak ada video dalam antrian.'))
              : RefreshIndicator(
                  onRefresh: _loadJobs,
                  child: ListView.builder(
                    itemCount: _jobs.length,
                    itemBuilder: (context, index) {
                      final job = _jobs[index];
                      return ListTile(
                        leading: _buildStatusIcon(job.status),
                        title: Text(
                          job.originalFilename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: _buildSubtitle(job),
                        trailing: _buildActionButton(job),
                      );
                    },
                  ),
                ),
    );
  }

  Widget _buildStatusIcon(JobStatus status) {
    switch (status) {
      case JobStatus.pending:
        return const Icon(Icons.pending, color: Colors.orange);
      case JobStatus.processing:
        return const Icon(Icons.hourglass_top, color: Colors.blue);
      case JobStatus.paused:
        return const Icon(Icons.pause, color: Colors.grey);
      case JobStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case JobStatus.failed:
        return const Icon(Icons.error, color: Colors.red);
      case JobStatus.cancelled:
        return const Icon(Icons.cancel, color: Colors.grey);
    }
  }

  Widget _buildSubtitle(VideoJob job) {
    if (job.status == JobStatus.processing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Memproses... ${(job.progress * 100).toStringAsFixed(0)}%'),
          LinearProgressIndicator(value: job.progress),
        ],
      );
    }
    if (job.status == JobStatus.failed) {
      return Text(
        'Gagal: ${job.errorMessage}',
        style: const TextStyle(color: Colors.red),
      );
    }
    if (job.status == JobStatus.completed) {
      return const Text('Selesai', style: TextStyle(color: Colors.green));
    }
    return Text(job.status.name);
  }

  Widget _buildActionButton(VideoJob job) {
    if (job.id == null) return const SizedBox.shrink();
    if (job.status == JobStatus.failed || job.status == JobStatus.paused) {
      return IconButton(
        onPressed: () => _setStatus(job, JobStatus.pending),
        icon: const Icon(Icons.refresh),
        tooltip: 'Masukkan kembali ke antrian',
      );
    }
    if (job.status == JobStatus.pending) {
      return IconButton(
        onPressed: () => _setStatus(job, JobStatus.cancelled),
        icon: const Icon(Icons.close),
        tooltip: 'Batalkan',
      );
    }
    return const SizedBox.shrink();
  }
}
