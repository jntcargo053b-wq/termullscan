// lib/services/database/job_database.dart
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../../models/video_job.dart';

class JobDatabase {
  static final JobDatabase _instance = JobDatabase._internal();
  factory JobDatabase() => _instance;
  JobDatabase._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'termullscan_jobs.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) {
        return db.execute(
          '''CREATE TABLE jobs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            inputPath TEXT,
            outputPath TEXT,
            originalFilename TEXT,
            status INTEGER,
            progress REAL,
            errorMessage TEXT,
            createdAt TEXT,
            updatedAt TEXT,
            settings TEXT
          )''',
        );
      },
    );
  }

  Future<int> insertJob(VideoJob job) async {
    final db = await database;
    return await db.insert('jobs', job.toMap());
  }

  Future<List<VideoJob>> getJobs({JobStatus? status}) async {
    final db = await database;
    final List<Map<String, dynamic>> maps;
    if (status != null) {
      maps = await db.query('jobs', where: 'status = ?', whereArgs: [status.index]);
    } else {
      maps = await db.query('jobs', orderBy: 'id ASC');
    }
    return List.generate(maps.length, (i) => VideoJob.fromMap(maps[i]));
  }

  Future<void> updateJob(VideoJob job) async {
    final db = await database;
    await db.update(
      'jobs',
      job.toMap(),
      where: 'id = ?',
      whereArgs: [job.id],
    );
  }

  Future<void> deleteJob(int id) async {
    final db = await database;
    await db.delete('jobs', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearCompleted() async {
    final db = await database;
    await db.delete(
      'jobs',
      where: 'status IN (?, ?)',
      whereArgs: [JobStatus.completed.index, JobStatus.cancelled.index],
    );
  }
}
