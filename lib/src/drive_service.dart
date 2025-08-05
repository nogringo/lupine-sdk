import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:lupine_sdk/src/models/drive_change_event.dart';
import 'package:lupine_sdk/src/models/drive_item.dart';
import 'package:lupine_sdk/src/models/drive_item_factory.dart';
import 'package:lupine_sdk/src/models/file_metadata.dart';
import 'package:lupine_sdk/src/sync_manager.dart';
import 'package:lupine_sdk/src/utils/crypto_utils.dart';
import 'package:ndk/ndk.dart';
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart' as sembast;

class DriveService {
  final Ndk ndk;
  final sembast.Database db;
  final sembast.StoreRef<String, Map<String, dynamic>> _store = sembast
      .stringMapStoreFactory
      .store('drive_events');
  late final SyncManager _syncManager;

  // Stream controller for drive changes
  final _changeController = StreamController<DriveChangeEvent>.broadcast();

  // Public stream for UI updates
  Stream<DriveChangeEvent> get changes => _changeController.stream;

  DriveService({required this.ndk, required this.db}) {
    _syncManager = SyncManager(
      ndk: ndk,
      db: db,
      onDriveChange: (type, path) {
        _changeController.add(DriveChangeEvent(type: type, path: path));
      },
    );
  }

  // Initialize the drive service and start syncing
  Future<void> initialize() async {
    await _syncManager.startSync();
  }

  // Stop syncing and clean up resources
  void dispose() {
    _syncManager.dispose();
    _changeController.close();
  }

  // Get sync status
  bool get isSyncing => _syncManager.isSyncing;
  DateTime? get lastSync => _syncManager.lastSync;

  // Force a manual sync
  Future<void> sync() async {
    await _syncManager.syncNow();
    await _syncManager.syncDeletions();
  }

  // Helper to create filter that includes both our files and shared files
  sembast.Filter _createAccessibleFilesFilter() {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      return sembast.Filter.equals(
        'nostrEvent.pubkey',
        '',
      ); // Will match nothing
    }

    // Include files where:
    // 1. We are the author (our own files)
    // 2. OR we can decrypt them (shared with us)
    // Since we store decrypted content, if it's in our DB, we have access
    return sembast.Filter.custom((record) {
      final nostrEvent = record['nostrEvent'] as Map<String, dynamic>?;
      if (nostrEvent == null) return false;

      final pubkey = nostrEvent['pubkey'] as String?;
      if (pubkey == null) return false;

      // Our own files
      if (pubkey == account.pubkey) return true;

      // Shared files - check if we're tagged
      final tags = nostrEvent['tags'] as List<dynamic>?;
      if (tags != null) {
        for (final tag in tags) {
          if (tag is List &&
              tag.length >= 2 &&
              tag[0] == 'p' &&
              tag[1] == account.pubkey) {
            return true;
          }
        }
      }

      return false;
    });
  }

  // Create a new folder
  Future<void> createFolder(String path) async {
    // Normalize path using path package
    path = p.normalize(path);

    // Validate path is absolute
    if (!p.isAbsolute(path)) {
      throw ArgumentError('Path must be absolute (start with /)');
    }

    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    final pubkey = account.pubkey;

    // Check if folder already exists
    final existingRecords = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.equals('decryptedContent.type', 'folder'),
          sembast.Filter.equals('decryptedContent.path', path),
        ]),
      ),
    );

    if (existingRecords.isNotEmpty) return;

    final folderData = {'type': 'folder', 'path': path};

    final content = jsonEncode(folderData);
    final encryptedContent = await account.signer.encryptNip44(
      plaintext: content,
      recipientPubKey: pubkey,
    );

    if (encryptedContent == null) {
      throw Exception('Failed to encrypt content');
    }

    final event = Nip01Event(
      pubKey: pubkey,
      kind: 9500,
      content: encryptedContent,
      tags: [],
    );

    // Store the unencrypted folder data in local database
    await _store.record(event.id).put(db, {
      'nostrEvent': event.toJson(),
      'decryptedContent': folderData,
    });

    ndk.broadcast.broadcast(nostrEvent: event);

    // Notify listeners about the new folder
    _changeController.add(DriveChangeEvent(type: 'added', path: path));
  }

  // Upload a file
  // NOTE: Due to NDK limitations, this method loads the entire file into memory
  // Not suitable for files larger than available RAM
  Future<FileMetadata> uploadFile({
    required Uint8List fileData,
    required String path,
    required String fileType,
    bool encrypt = true,
  }) async {
    // Normalize path
    path = p.normalize(path);

    // Validate path is absolute
    if (!p.isAbsolute(path)) {
      throw ArgumentError('Path must be absolute (start with /)');
    }

    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    String? encryptionAlgorithm;
    String? decryptionKey;
    String? decryptionNonce;

    Uint8List processedData = fileData;

    if (encrypt) {
      // Generate random key and nonce for AES-GCM
      final key = generateRandomBytes(32); // 256-bit key
      final nonce = generateRandomBytes(12); // 96-bit nonce

      // Encrypt the file data
      processedData = encryptAesGcm(fileData, key, nonce);

      encryptionAlgorithm = 'aes-gcm';
      decryptionKey = base64Encode(key);
      decryptionNonce = base64Encode(nonce);
    }

    // Calculate hash of processed (potentially encrypted) data
    final hash = sha256.convert(processedData).toString();
    final size = processedData.length;

    // Upload to Blossom servers via NDK
    await ndk.blossom.uploadBlob(data: processedData);

    // Create file metadata
    final fileMetadata = {
      'type': 'file',
      'hash': hash,
      'path': path,
      'size': size,
      'file-type': fileType,
      if (encryptionAlgorithm != null)
        'encryption-algorithm': encryptionAlgorithm,
      if (decryptionKey != null) 'decryption-key': decryptionKey,
      if (decryptionNonce != null) 'decryption-nonce': decryptionNonce,
    };

    // Encrypt the metadata
    final content = jsonEncode(fileMetadata);
    final encryptedContent = await account.signer.encryptNip44(
      plaintext: content,
      recipientPubKey: account.pubkey,
    );

    if (encryptedContent == null) {
      throw Exception('Failed to encrypt content');
    }

    // Create the event
    final event = Nip01Event(
      pubKey: account.pubkey,
      kind: 9500,
      content: encryptedContent,
      tags: [],
    );

    // Store in local database
    await _store.record(event.id).put(db, {
      'nostrEvent': event.toJson(),
      'decryptedContent': fileMetadata,
    });

    // Broadcast the event
    ndk.broadcast.broadcast(nostrEvent: event);

    // Return the created file metadata
    return FileMetadata(
      hash: hash,
      path: path,
      size: size,
      fileType: fileType,
      encryptionAlgorithm: encryptionAlgorithm,
      decryptionKey: decryptionKey,
      decryptionNonce: decryptionNonce,
      createdAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
      eventId: event.id,
    );
  }

  // List files and folders
  Future<List<DriveItem>> list(String path) async {
    // Normalize path using path package
    path = p.normalize(path);

    // Validate path is absolute
    if (!p.isAbsolute(path)) {
      throw ArgumentError('Path must be absolute (start with /)');
    }

    // Find all items in the directory from local database
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          _createAccessibleFilesFilter(), // Include both owned and shared files
          sembast.Filter.custom((record) {
            final decryptedContent =
                record['decryptedContent'] as Map<String, dynamic>?;
            if (decryptedContent == null) return false;

            final itemPath = decryptedContent['path'] as String?;
            if (itemPath == null) return false;

            // Check if item is in the requested directory
            final itemDir = p.dirname(itemPath);

            // For root directory
            if (path == '/') {
              // Item should be in root (dirname should be '/')
              return itemDir == '/';
            }

            // For other directories, check if item's parent is the requested path
            return itemDir == path;
          }),
        ]),
      ),
    );

    // Convert records to list of DriveItem objects
    final items = <DriveItem>[];
    for (final record in records) {
      try {
        final item = DriveItemFactory.fromJson(record.value);
        items.add(item);
      } catch (e) {
        // Skip items that can't be parsed
        continue;
      }
    }

    return items;
  }

  // Delete file or folder
  Future<void> deleteById(String eventId) async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Verify the event exists and user owns it
    final record = await _store.record(eventId).get(db);
    if (record == null) return;

    final nostrEvent = record['nostrEvent'] as Map<String, dynamic>;
    final eventPubkey = nostrEvent['pubkey'] as String?;

    if (eventPubkey != account.pubkey) {
      throw Exception(
        'Unauthorized: You can only delete your own files/folders',
      );
    }

    // Remove from local database
    await _store.record(eventId).delete(db);

    // Broadcast deletion event
    ndk.broadcast.broadcastDeletion(eventId: eventId);
  }

  // Delete file or folder by path
  Future<void> deleteByPath(String path) async {
    // Normalize path
    path = p.normalize(path);

    // Validate path is absolute
    if (!p.isAbsolute(path)) {
      throw ArgumentError('Path must be absolute (start with /)');
    }

    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Find the event by path (only allow deleting our own files)
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.equals('decryptedContent.path', path),
          sembast.Filter.equals(
            'nostrEvent.pubkey',
            account.pubkey,
          ), // Only delete our own
        ]),
      ),
    );

    if (records.isEmpty) return;

    // Check if it's a folder
    final record = records.last;
    final decryptedContent =
        record.value['decryptedContent'] as Map<String, dynamic>;
    final isFolder = decryptedContent['type'] == 'folder';

    if (isFolder) {
      // Find all items that start with this folder path
      final childRecords = await _store.find(
        db,
        finder: sembast.Finder(
          filter: sembast.Filter.and([
            sembast.Filter.custom((record) {
              final content =
                  record['decryptedContent'] as Map<String, dynamic>?;
              if (content == null) return false;
              final itemPath = content['path'] as String?;
              if (itemPath == null) return false;
              // Check if item is inside the folder being deleted
              return itemPath.startsWith('$path/');
            }),
            sembast.Filter.equals('nostrEvent.pubkey', account.pubkey),
          ]),
        ),
      );

      // Delete all children first (files and subfolders)
      for (final childRecord in childRecords) {
        await deleteById(childRecord.key);
      }
    }

    // Delete the folder/file itself
    await deleteById(record.key);
  }

  // Download a file from Blossom servers
  Future<Uint8List> downloadFile({
    required String hash,
    String? decryptionKey,
    String? decryptionNonce,
  }) async {
    // Download from Blossom servers
    final response = await ndk.blossom.getBlob(sha256: hash);

    final encryptedData = response.data;

    // Decrypt if keys provided (file was encrypted)
    if (decryptionKey != null && decryptionNonce != null) {
      final key = base64Decode(decryptionKey);
      final nonce = base64Decode(decryptionNonce);
      return decryptAesGcm(encryptedData, key, nonce);
    }

    return encryptedData;
  }

  // Get file versions
  Future<List<FileMetadata>> getFileVersions(String path) async {
    // Normalize path
    path = p.normalize(path);

    // Validate path is absolute
    if (!p.isAbsolute(path)) {
      throw ArgumentError('Path must be absolute (start with /)');
    }

    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Find all file events with the same path (including shared)
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.equals('decryptedContent.path', path),
          sembast.Filter.equals('decryptedContent.type', 'file'),
          _createAccessibleFilesFilter(), // Include both owned and shared
        ]),
      ),
    );

    final versions = <FileMetadata>[];

    for (final record in records) {
      try {
        // Use the factory to parse the record
        final item = DriveItemFactory.fromJson(record.value);
        if (item is FileMetadata) {
          versions.add(item);
        }
      } catch (e) {
        // Skip items that can't be parsed
        continue;
      }
    }

    // Sort by creation time (newest first)
    versions.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return versions;
  }

  // Move/rename file or folder
  Future<void> move({required String oldPath, required String newPath}) async {
    // Normalize paths
    oldPath = p.normalize(oldPath);
    newPath = p.normalize(newPath);

    // Validate paths are absolute
    if (!p.isAbsolute(oldPath) || !p.isAbsolute(newPath)) {
      throw ArgumentError('Paths must be absolute (start with /)');
    }

    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Find the most recent event for the old path (only allow moving our own files)
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.equals('decryptedContent.path', oldPath),
          sembast.Filter.equals(
            'nostrEvent.pubkey',
            account.pubkey,
          ), // Only move our own
        ]),
      ),
    );

    if (records.isEmpty) {
      throw Exception('File or folder not found at path: $oldPath');
    }

    // Get the most recent record
    records.sort((a, b) {
      final aCreatedAt = (a.value['nostrEvent'] as Map)['created_at'] as int;
      final bCreatedAt = (b.value['nostrEvent'] as Map)['created_at'] as int;
      return bCreatedAt.compareTo(aCreatedAt);
    });

    final latestRecord = records.first;
    final decryptedContent = Map<String, dynamic>.from(
      latestRecord.value['decryptedContent'] as Map<String, dynamic>,
    );

    // Update the path
    decryptedContent['path'] = newPath;

    // Create new event with updated path
    final content = jsonEncode(decryptedContent);
    final encryptedContent = await account.signer.encryptNip44(
      plaintext: content,
      recipientPubKey: account.pubkey,
    );

    if (encryptedContent == null) {
      throw Exception('Failed to encrypt content');
    }

    final event = Nip01Event(
      pubKey: account.pubkey,
      kind: 9500,
      content: encryptedContent,
      tags: [],
    );

    // Store in local database
    await _store.record(event.id).put(db, {
      'nostrEvent': event.toJson(),
      'decryptedContent': decryptedContent,
    });

    // Delete the old entry
    await deleteById(latestRecord.key);

    // If it's a folder, also move all children
    if (decryptedContent['type'] == 'folder') {
      await _moveChildren(oldPath, newPath, account);
    }

    // Broadcast the new event
    ndk.broadcast.broadcast(nostrEvent: event);
  }

  // Helper method to move all children of a folder
  Future<void> _moveChildren(
    String oldPath,
    String newPath,
    Account account,
  ) async {
    final childRecords = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.custom((record) {
            final content = record['decryptedContent'] as Map<String, dynamic>?;
            if (content == null) return false;
            final itemPath = content['path'] as String?;
            if (itemPath == null) return false;
            return itemPath.startsWith('$oldPath/');
          }),
          sembast.Filter.equals('nostrEvent.pubkey', account.pubkey),
        ]),
      ),
    );

    for (final childRecord in childRecords) {
      final childContent =
          childRecord.value['decryptedContent'] as Map<String, dynamic>;
      final childPath = childContent['path'] as String;

      // Replace the old parent path with the new one
      final newChildPath = childPath.replaceFirst(oldPath, newPath);

      // Recursively move each child
      await move(oldPath: childPath, newPath: newChildPath);
    }
  }

  // Copy file or folder
  Future<void> copy({
    required String sourcePath,
    required String destinationPath,
  }) async {
    // Normalize paths
    sourcePath = p.normalize(sourcePath);
    destinationPath = p.normalize(destinationPath);

    // Validate paths are absolute
    if (!p.isAbsolute(sourcePath) || !p.isAbsolute(destinationPath)) {
      throw ArgumentError('Paths must be absolute (start with /)');
    }

    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Find the most recent event for the source path
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.equals('decryptedContent.path', sourcePath),
          sembast.Filter.equals('nostrEvent.pubkey', account.pubkey),
        ]),
      ),
    );

    if (records.isEmpty) {
      throw Exception('File or folder not found at path: $sourcePath');
    }

    // Get the most recent record
    records.sort((a, b) {
      final aCreatedAt = (a.value['nostrEvent'] as Map)['created_at'] as int;
      final bCreatedAt = (b.value['nostrEvent'] as Map)['created_at'] as int;
      return bCreatedAt.compareTo(aCreatedAt);
    });

    final sourceRecord = records.first;
    final sourceContent = Map<String, dynamic>.from(
      sourceRecord.value['decryptedContent'] as Map<String, dynamic>,
    );

    // Create a copy with the new path
    final copiedContent = Map<String, dynamic>.from(sourceContent);
    copiedContent['path'] = destinationPath;

    // Create new event for the copy
    final content = jsonEncode(copiedContent);
    final encryptedContent = await account.signer.encryptNip44(
      plaintext: content,
      recipientPubKey: account.pubkey,
    );

    if (encryptedContent == null) {
      throw Exception('Failed to encrypt content');
    }

    final event = Nip01Event(
      pubKey: account.pubkey,
      kind: 9500,
      content: encryptedContent,
      tags: [],
    );

    // Store in local database
    await _store.record(event.id).put(db, {
      'nostrEvent': event.toJson(),
      'decryptedContent': copiedContent,
    });

    // If it's a folder, also copy all children
    if (copiedContent['type'] == 'folder') {
      await _copyChildren(sourcePath, destinationPath, account);
    }

    // Broadcast the new event
    ndk.broadcast.broadcast(nostrEvent: event);
  }

  // Helper method to copy all children of a folder
  Future<void> _copyChildren(
    String sourcePath,
    String destinationPath,
    Account account,
  ) async {
    final childRecords = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.custom((record) {
            final content = record['decryptedContent'] as Map<String, dynamic>?;
            if (content == null) return false;
            final itemPath = content['path'] as String?;
            if (itemPath == null) return false;
            return itemPath.startsWith('$sourcePath/');
          }),
          sembast.Filter.equals('nostrEvent.pubkey', account.pubkey),
        ]),
      ),
    );

    for (final childRecord in childRecords) {
      final childContent =
          childRecord.value['decryptedContent'] as Map<String, dynamic>;
      final childPath = childContent['path'] as String;

      // Replace the source parent path with the destination
      final newChildPath = childPath.replaceFirst(sourcePath, destinationPath);

      // Recursively copy each child
      await copy(sourcePath: childPath, destinationPath: newChildPath);
    }
  }

  // Search files and folders
  Future<List<DriveItem>> search(String query) async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Convert query to lowercase for case-insensitive search
    final lowerQuery = query.toLowerCase();

    // Find all records that match the search query
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          _createAccessibleFilesFilter(), // Include both owned and shared
          sembast.Filter.custom((record) {
            final content = record['decryptedContent'] as Map<String, dynamic>?;
            if (content == null) return false;

            final path = content['path'] as String?;
            if (path == null) return false;

            // Search in path (file/folder name)
            final fileName = p.basename(path).toLowerCase();
            if (fileName.contains(lowerQuery)) return true;

            // Search in full path
            if (path.toLowerCase().contains(lowerQuery)) return true;

            // For files, also search in file type
            if (content['type'] == 'file') {
              final fileType = content['file-type'] as String?;
              if (fileType != null &&
                  fileType.toLowerCase().contains(lowerQuery)) {
                return true;
              }
            }

            return false;
          }),
        ]),
      ),
    );

    final results = <DriveItem>[];

    for (final record in records) {
      try {
        final item = DriveItemFactory.fromJson(record.value);
        results.add(item);
      } catch (e) {
        // Skip items that can't be parsed
        continue;
      }
    }

    // Sort by path for consistent results
    results.sort((a, b) => a.path.compareTo(b.path));

    return results;
  }
}
