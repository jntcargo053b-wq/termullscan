import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'services/storage_service.dart';

// Di dalam main() setelah watermarkSettings.load():
final storage = StorageService();
try {
  final dir = await getApplicationDocumentsDirectory();
  final jsonFile = File('${dir.path}/scan_log.json');
  if (await jsonFile.exists()) {
    final content = await jsonFile.readAsString();
    if (content.isNotEmpty) {
      final decoded = json.decode(content);
      if (decoded is List) {
        final entries = decoded.map((e) => ScanEntry.fromJson(e)).toList();
        await storage.migrateFromJson(entries);
        await jsonFile.rename('${jsonFile.path}.migrated');
        debugPrint('✅ Migrated ${entries.length} entries from JSON to SQLite');
      }
    }
  }
} catch (e) {
  debugPrint('⚠️ Migration error: $e');
}
