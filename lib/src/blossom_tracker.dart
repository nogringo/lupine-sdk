import 'package:sembast/sembast.dart' as sembast;

class BlossomTracker {
  final sembast.Database db;
  final sembast.StoreRef<String, Map<String, dynamic>> _store = sembast
      .stringMapStoreFactory
      .store('blossom_tracking');

  BlossomTracker({required this.db});

  // Track which servers have a specific file hash
  Future<void> trackFileOnServer({
    required String hash,
    required String serverUrl,
    DateTime? lastVerified,
  }) async {
    final key = '${hash}_$serverUrl';
    await _store.record(key).put(db, {
      'hash': hash,
      'serverUrl': serverUrl,
      'lastVerified':
          lastVerified?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'available': true,
    });
  }

  // Get all servers that have a specific file
  Future<List<String>> getServersForFile(String hash) async {
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.equals('hash', hash),
          sembast.Filter.equals('available', true),
        ]),
      ),
    );

    return records.map((r) => r.value['serverUrl'] as String).toList();
  }

  // Mark a server as unavailable for a file
  Future<void> markServerUnavailable({
    required String hash,
    required String serverUrl,
  }) async {
    final key = '${hash}_$serverUrl';
    final record = await _store.record(key).get(db);
    if (record != null) {
      record['available'] = false;
      record['lastChecked'] = DateTime.now().toIso8601String();
      await _store.record(key).put(db, record);
    }
  }

  // Get file availability across all servers
  Future<Map<String, List<String>>> getFileAvailability(
    List<String> hashes,
  ) async {
    final availability = <String, List<String>>{};

    for (final hash in hashes) {
      availability[hash] = await getServersForFile(hash);
    }

    return availability;
  }

  // Clean up old tracking data
  Future<void> cleanupOldData({
    Duration maxAge = const Duration(days: 30),
  }) async {
    final cutoff = DateTime.now().subtract(maxAge);

    final records = await _store.find(db);
    for (final record in records) {
      final lastVerified = record.value['lastVerified'] as String?;
      if (lastVerified != null) {
        final verifiedDate = DateTime.parse(lastVerified);
        if (verifiedDate.isBefore(cutoff)) {
          await _store.record(record.key).delete(db);
        }
      }
    }
  }

  // Update tracking after file upload
  Future<void> trackUpload({
    required String hash,
    required List<String> serverUrls,
  }) async {
    for (final serverUrl in serverUrls) {
      await trackFileOnServer(
        hash: hash,
        serverUrl: serverUrl,
        lastVerified: DateTime.now(),
      );
    }
  }

  // Get statistics about server usage
  Future<Map<String, int>> getServerStatistics() async {
    final stats = <String, int>{};

    final records = await _store.find(
      db,
      finder: sembast.Finder(filter: sembast.Filter.equals('available', true)),
    );

    for (final record in records) {
      final serverUrl = record.value['serverUrl'] as String;
      stats[serverUrl] = (stats[serverUrl] ?? 0) + 1;
    }

    return stats;
  }
}
