// lib/ui/screens/queue_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/queue/job_queue_manager.dart';

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Queue'), actions: [
        IconButton(onPressed: () => context.read<JobQueueManager>().clearCompleted(), icon: Icon(Icons.delete_sweep))
      ]),
      body: Consumer<JobQueueManager>(
        builder: (context, manager, child) {
          if (manager.jobs.isEmpty) {
            return Center(child: Text('Tidak ada video dalam antrian.'));
          }
          return ListView.builder(
            itemCount: manager.jobs.length,
            itemBuilder: (ctx, index) {
              final job = manager.jobs[index];
              return ListTile(
                leading: _buildStatusIcon(job.status),
                title: Text(job.originalFilename, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: _buildSubtitle(job),
                trailing: _buildActionButton(job, manager),
              );
            },
          );
        },
      ),
      floatingActionButton: (context.watch<JobQueueManager>().pendingJobs.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: () => context.read<JobQueueManager>()._processNext(),
              label: Text('Process Now'),
              icon: Icon(Icons.play_arrow),
            )
          : null,
    );
  }

  Widget _buildStatusIcon(JobStatus status) {
    switch (status) {
      case JobStatus.pending: return Icon(Icons.pending, color: Colors.orange);
      case JobStatus.processing: return Icon(Icons.hourglass_top, color: Colors.blue);
      case JobStatus.paused: return Icon(Icons.pause, color: Colors.grey);
      case JobStatus.completed: return Icon(Icons.check_circle, color: Colors.green);
      case JobStatus.failed: return Icon(Icons.error, color: Colors.red);
      case JobStatus.cancelled: return Icon(Icons.cancel, color: Colors.grey);
    }
  }

  Widget _buildSubtitle(VideoJob job) {
    if (job.status == JobStatus.processing) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Memproses... ${(job.progress * 100).toStringAsFixed(0)}%'),
        LinearProgressIndicator(value: job.progress),
      ]);
    } else if (job.status == JobStatus.failed) {
      return Text('Gagal: ${job.errorMessage}', style: TextStyle(color: Colors.red));
    } else if (job.status == JobStatus.completed) {
      return Text('Selesai', style: TextStyle(color: Colors.green));
    }
    return Text(job.status.toString().split('.').last);
  }

  Widget _buildActionButton(VideoJob job, JobQueueManager manager) {
    if (job.status == JobStatus.processing) {
      return IconButton(onPressed: () => manager.pauseJob(job.id!), icon: Icon(Icons.pause));
    }
    if (job.status == JobStatus.paused) {
      return IconButton(onPressed: () => manager.resumeJob(job.id!), icon: Icon(Icons.play_arrow));
    }
    if (job.status == JobStatus.failed) {
      return IconButton(onPressed: () => manager.retryJob(job.id!), icon: Icon(Icons.refresh));
    }
    if (job.status == JobStatus.pending) {
      return IconButton(onPressed: () => manager.cancelJob(job.id!), icon: Icon(Icons.close));
    }
    return SizedBox.shrink();
  }
}
