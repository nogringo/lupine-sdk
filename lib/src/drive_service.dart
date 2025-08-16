import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:lupine_sdk/src/models/drive_change_event.dart';
import 'package:lupine_sdk/src/models/drive_item.dart';
import 'package:lupine_sdk/src/models/drive_item_factory.dart';
import 'package:lupine_sdk/src/models/file_metadata.dart';
import 'package:lupine_sdk/src/utils/nevent.dart';
import 'package:lupine_sdk/src/sync_manager.dart';
import 'package:lupine_sdk/src/utils/aes_gcm.dart';
import 'package:cryptography/cryptography.dart' hide KeyPair;
import 'package:ndk/ndk.dart';
import 'package:nip01/nip01.dart';
import 'package:nip19/nip19.dart';
import 'package:nip49/nip49.dart';
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

    // Start syncing automatically
    _syncManager.startSync();
  }

  // Call this when the account changes (login/logout)
  Future<void> onAccountChanged() async {
    // Let sync manager handle the account change
    await _syncManager.onAccountChanged();
  }

  // Dispose everything and clean up all resources
  void dispose() {
    _syncManager.dispose();
    _changeController.close();
  }

  // Get sync status
  bool get isSyncing => _syncManager.isSyncing;
  DateTime? get lastSync => _syncManager.lastSync;

  // Force a manual sync
  Future<void> sync() async {
    // await _syncManager.syncNow();
    // await _syncManager.syncDeletions();
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

  /// Uploads a file to the drive service.
  ///
  /// This method uploads a file to the decentralized storage system. The file
  /// can optionally be encrypted before upload for security.
  ///
  /// **Note:** Due to NDK limitations, this method loads the entire file into memory.
  /// Not suitable for files larger than available RAM.
  ///
  /// [fileData] - The raw file data as a byte array.
  /// [path] - The absolute path where the file should be stored (must start with '/').
  /// [fileType] - Optional MIME type of the file (e.g., 'image/jpeg', 'text/plain').
  /// [encrypt] - Whether to encrypt the file before uploading. Defaults to `true`.
  ///
  /// Returns a [FileMetadata] object containing information about the uploaded file.
  ///
  /// Throws:
  /// - [ArgumentError] if the path is not absolute.
  /// - [Exception] if the user is not logged in.
  ///
  /// Example:
  /// ```dart
  /// final metadata = await driveService.uploadFile(
  ///   fileData: imageBytes,
  ///   path: '/photos/vacation.jpg',
  ///   fileType: 'image/jpeg',
  ///   encrypt: true,
  /// );
  /// ```
  Future<FileMetadata> uploadFile({
    required Uint8List fileData,
    required String path,
    String? fileType,
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
      // Encrypt using AESGCMEncryption
      final aes = AESGCMEncryption();
      final result = await aes.encryptFile(fileData);

      processedData = result['encryptedData'] as Uint8List;
      final key = result['key'] as SecretKey;
      final nonce = result['nonce'] as List<int>;

      // Extract key bytes for storage
      final keyBytes = await key.extractBytes();

      encryptionAlgorithm = 'aes-gcm';
      decryptionKey = base64Encode(keyBytes);
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
      if (fileType != null) 'file-type': fileType,
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

    // Notify listeners about the new file
    _changeController.add(DriveChangeEvent(type: 'added', path: path));

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

  /// Lists files and folders in a directory with optional MIME type filtering.
  ///
  /// [path] - The absolute path of the directory to list (must start with '/').
  /// [mimeTypes] - Optional list of MIME types to filter by. If provided, only
  ///               files matching these MIME types will be returned.
  ///               Common examples:
  ///               - Images: ['image/jpeg', 'image/png', 'image/gif']
  ///               - Videos: ['video/mp4', 'video/webm', 'video/mpeg']
  ///               - Documents: ['application/pdf', 'text/plain']
  /// [recursive] - If true, includes items from all subdirectories. Defaults to false.
  ///
  /// Returns a list of [DriveItem] objects (files and folders).
  /// When mimeTypes filter is provided, folders are excluded from results.
  ///
  /// Throws:
  /// - [ArgumentError] if the path is not absolute.
  /// - [Exception] if the user is not logged in.
  Future<List<DriveItem>> list(
    String path, {
    List<String>? mimeTypes,
    bool recursive = false,
  }) async {
    // Normalize path using path package
    path = p.normalize(path);

    // Validate path is absolute
    if (!p.isAbsolute(path)) {
      throw ArgumentError('Path must be absolute (start with /)');
    }

    // Build filters
    final filters = <sembast.Filter>[
      _createAccessibleFilesFilter(), // Include both owned and shared files
      sembast.Filter.custom((record) {
        final decryptedContent =
            record['decryptedContent'] as Map<String, dynamic>?;
        if (decryptedContent == null) return false;

        final itemPath = decryptedContent['path'] as String?;
        if (itemPath == null) return false;

        if (recursive) {
          // Include items in the directory and all subdirectories
          if (path == '/') {
            // For root, include everything
            return true;
          } else {
            // Use path.isWithin to properly check if itemPath is within the directory
            // This handles edge cases like /documents vs /documents2
            return itemPath == path || p.isWithin(path, itemPath);
          }
        } else {
          // Check if item is in the requested directory (not subdirectories)
          final itemDir = p.dirname(itemPath);

          // For root directory
          if (path == '/') {
            // Item should be in root (dirname should be '/')
            if (itemDir != '/') return false;
          } else {
            // For other directories, check if item's parent is the requested path
            if (itemDir != path) return false;
          }
        }

        // Apply MIME type filter if provided
        if (mimeTypes != null && mimeTypes.isNotEmpty) {
          final type = decryptedContent['type'] as String?;
          // Only filter files when MIME types are specified
          if (type != 'file') return false;

          final fileType = decryptedContent['file-type'] as String?;
          if (fileType == null) return false;

          // Check if file type matches any of the requested MIME types
          return mimeTypes.any(
            (mimeType) => fileType.toLowerCase() == mimeType.toLowerCase(),
          );
        }

        return true;
      }),
    ];

    // Find all items in the directory from local database
    final records = await _store.find(
      db,
      finder: sembast.Finder(filter: sembast.Filter.and(filters)),
    );

    // Group records by path and keep only the latest version
    final latestByPath = <String, MapEntry<String, Map<String, dynamic>>>{};

    for (final record in records) {
      final decryptedContent =
          record.value['decryptedContent'] as Map<String, dynamic>?;
      if (decryptedContent == null) continue;

      final path = decryptedContent['path'] as String?;
      if (path == null) continue;

      final nostrEvent = record.value['nostrEvent'] as Map<String, dynamic>?;
      if (nostrEvent == null) continue;

      final createdAt = nostrEvent['created_at'] as int? ?? 0;

      // Check if we already have this path
      if (latestByPath.containsKey(path)) {
        final existingCreatedAt =
            (latestByPath[path]!.value['nostrEvent'] as Map)['created_at']
                as int? ??
            0;
        // Keep the newer version
        if (createdAt > existingCreatedAt) {
          latestByPath[path] = MapEntry(record.key, record.value);
        }
      } else {
        latestByPath[path] = MapEntry(record.key, record.value);
      }
    }

    // Convert to list of DriveItem objects
    final items = <DriveItem>[];
    for (final entry in latestByPath.values) {
      try {
        final item = DriveItemFactory.fromJson(entry.value);
        items.add(item);
      } catch (e) {
        // Skip items that can't be parsed
        print(e);
        continue;
      }
    }

    return items;
  }

  // Share a file with another Nostr user
  Future<Nip01Event> shareWithNostrUser({
    required String eventId,
    required String recipientPubkey,
  }) async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Get the file from database using event ID
    final record = await _store.record(eventId).get(db);
    if (record == null) {
      throw Exception('File not found with ID: $eventId');
    }

    // Verify user owns this file
    final nostrEvent = record['nostrEvent'] as Map<String, dynamic>?;
    if (nostrEvent == null || nostrEvent['pubkey'] != account.pubkey) {
      throw Exception('You can only share your own files');
    }

    final decryptedContent =
        record['decryptedContent'] as Map<String, dynamic>?;
    if (decryptedContent == null) {
      throw Exception('Invalid file data');
    }

    // Encrypt the file metadata for the recipient using NIP-44
    final content = jsonEncode(decryptedContent);
    final encryptedContent = await account.signer.encryptNip44(
      plaintext: content,
      recipientPubKey: recipientPubkey,
    );

    if (encryptedContent == null) {
      throw Exception('Failed to encrypt content for recipient');
    }

    // Create a new event with the recipient tagged
    final shareEvent = Nip01Event(
      pubKey: account.pubkey,
      kind: 9500,
      content: encryptedContent,
      tags: [
        [
          'p',
          recipientPubkey,
        ], // Tag the recipient so they can discover the share
      ],
    );

    // Store the share event locally
    await _store.record(shareEvent.id).put(db, {
      'nostrEvent': shareEvent.toJson(),
      'decryptedContent': decryptedContent,
      'sharedWith': recipientPubkey,
      'originalEventId': eventId,
    });

    // Broadcast the share event
    ndk.broadcast.broadcast(nostrEvent: shareEvent);

    // Notify about the share
    final path = decryptedContent['path'] as String;
    _changeController.add(DriveChangeEvent(type: 'shared', path: path));

    return shareEvent;
  }

  // Generate a shareable link for a file with optional password protection
  Future<String> generateShareLink({
    required String eventId,
    String? password,
    String baseUrl = 'https://example.com/share',
    List<String>? relays,
  }) async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Get the file from database using event ID
    final record = await _store.record(eventId).get(db);
    if (record == null) {
      throw Exception('File not found with ID: $eventId');
    }

    // Verify user owns this file
    final nostrEvent = record['nostrEvent'] as Map<String, dynamic>?;
    if (nostrEvent == null || nostrEvent['pubkey'] != account.pubkey) {
      throw Exception('You can only share your own files');
    }

    // Generate a new keypair for this share link
    final keyPair = KeyPair.generate();
    final sharePrivateKey = keyPair.privateKey;
    final sharePublicKey = keyPair.publicKey;

    // Use provided relays or default ones
    final shareRelays =
        relays ??
        ['wss://relay.damus.io', 'wss://relay.nostr.band', 'wss://nos.lol'];

    // Share the file with the new pubkey
    final shareEvent = await shareWithNostrUser(
      eventId: eventId,
      recipientPubkey: sharePublicKey,
    );

    // Create nevent using the NeventCodec
    final neventObj = Nevent(
      eventId: shareEvent.id,
      relays: shareRelays,
      author: shareEvent.pubKey,
      kind: shareEvent.kind,
    );
    final nevent = NeventCodec.encode(neventObj);

    // Create the share link with format: baseUrl/nevent/nsecORncryptsec
    String encodedKey;
    if (password != null && password.isNotEmpty) {
      // Use NIP-49 to create an encrypted private key
      encodedKey = await Nip49.encrypt(sharePrivateKey, password);
    } else {
      // Use regular nsec encoding for non-password protected links
      encodedKey = Nip19.nsecFromHex(sharePrivateKey);
    }

    final shareLink = '$baseUrl/$nevent/$encodedKey';

    return shareLink;
  }

  // Revoke a share link
  Future<void> revokeShareLink(String publicKeyOrEventId) async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Find the share record
    final shareId = publicKeyOrEventId.startsWith('share_')
        ? publicKeyOrEventId
        : 'share_$publicKeyOrEventId';

    final record = await _store.record(shareId).get(db);
    if (record == null) {
      throw Exception('Share link not found');
    }

    // Verify ownership
    if (record['createdBy'] != account.pubkey) {
      throw Exception('You can only revoke your own share links');
    }

    final sharePublicKey = record['sharePublicKey'] as String;

    // Find all share events for this public key and broadcast deletions
    final shareEvents = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          sembast.Filter.equals('sharedWith', sharePublicKey),
          sembast.Filter.equals('nostrEvent.pubkey', account.pubkey),
        ]),
      ),
    );

    for (final event in shareEvents) {
      final eventId = event.key;
      // Broadcast deletion for each share event
      ndk.broadcast.broadcastDeletion(eventId: eventId);
      // Remove from local storage
      await _store.record(eventId).delete(db);
    }

    // Remove the share link record
    await _store.record(shareId).delete(db);
  }

  // Get files shared with me by other Nostr users
  Future<List<DriveItem>> getSharedWithMe() async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Find all items shared with us (where we're tagged with 'p')
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        filter: sembast.Filter.and([
          // Files where we're tagged but not the author
          sembast.Filter.custom((record) {
            final nostrEvent = record['nostrEvent'] as Map<String, dynamic>?;
            if (nostrEvent == null) return false;

            final pubkey = nostrEvent['pubkey'] as String?;
            if (pubkey == null || pubkey == account.pubkey) {
              return false; // Skip our own files
            }

            // Check if we're tagged
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
          }),
        ]),
      ),
    );

    // Convert to DriveItem objects
    final items = <DriveItem>[];
    for (final record in records) {
      try {
        final item = DriveItemFactory.fromJson(record.value);
        items.add(item);
      } catch (e) {
        print('Error parsing shared item: $e');
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

    // Get path for change notification
    final decryptedContent =
        record['decryptedContent'] as Map<String, dynamic>?;
    final path = decryptedContent?['path'] as String?;

    // Broadcast deletion event
    ndk.broadcast.broadcastDeletion(eventId: eventId);

    // Notify listeners about the deletion
    if (path != null) {
      _changeController.add(DriveChangeEvent(type: 'deleted', path: path));
    }
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

    // Notify listeners about the deletion
    _changeController.add(DriveChangeEvent(type: 'deleted', path: path));
  }

  // Download a file from Blossom servers
  Future<Uint8List> downloadFile({
    required String hash,
    String? decryptionKey,
    String? decryptionNonce,
  }) async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Download from Blossom servers
    final response = await ndk.blossom.getBlob(
      sha256: hash,
      pubkeyToFetchUserServerList: account.pubkey,
    );

    final encryptedData = response.data;

    // Decrypt if keys provided (file was encrypted)
    if (decryptionKey != null && decryptionNonce != null) {
      try {
        final keyBytes = base64Decode(decryptionKey);
        final nonce = base64Decode(decryptionNonce);

        // Validate key and nonce lengths
        if (keyBytes.length != 32) {
          throw Exception(
            'Invalid key length: ${keyBytes.length} bytes (expected 32)',
          );
        }
        if (nonce.length != 12) {
          throw Exception(
            'Invalid nonce length: ${nonce.length} bytes (expected 12)',
          );
        }

        // Decrypt using AESGCMEncryption
        final aes = AESGCMEncryption();
        final key = SecretKey(keyBytes);
        return await aes.decryptFile(encryptedData, key, nonce);
      } catch (e) {
        throw Exception(
          'Decryption failed: $e\n'
          'Data size: ${encryptedData.length} bytes\n'
          'Hash: $hash',
        );
      }
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

  /// Moves or renames a file or folder to a new path.
  ///
  /// This method allows you to move items to a different location in the drive
  /// or rename them by changing their path. The operation creates a new event
  /// with the updated path while preserving all other metadata.
  ///
  /// [oldPath] - The current absolute path of the file or folder to move.
  /// [newPath] - The new absolute path where the item should be moved.
  ///
  /// Both paths must be absolute (starting with '/').
  ///
  /// Throws:
  /// - [ArgumentError] if either path is not absolute.
  /// - [Exception] if the user is not logged in.
  /// - [Exception] if the item at [oldPath] is not found.
  /// - [Exception] if the item doesn't belong to the current user.
  ///
  /// Example:
  /// ```dart
  /// // Rename a file
  /// await driveService.move(
  ///   oldPath: '/documents/draft.txt',
  ///   newPath: '/documents/final.txt',
  /// );
  ///
  /// // Move a file to a different folder
  /// await driveService.move(
  ///   oldPath: '/temp/image.jpg',
  ///   newPath: '/photos/vacation/image.jpg',
  /// );
  /// ```
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

    // Find ALL versions of the file at the old path (only allow moving our own files)
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

    // Move ALL versions of the file/folder
    for (final record in records) {
      final decryptedContent = Map<String, dynamic>.from(
        record.value['decryptedContent'] as Map<String, dynamic>,
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

      // Broadcast the new event
      ndk.broadcast.broadcast(nostrEvent: event);

      // Delete the old entry
      await deleteById(record.key);
    }

    // Get the type from the first record to determine if we need to move children
    final firstRecord = records.first;
    final decryptedContent =
        firstRecord.value['decryptedContent'] as Map<String, dynamic>;

    // If it's a folder, also move all children
    if (decryptedContent['type'] == 'folder') {
      await _moveChildren(oldPath, newPath, account);
    }

    // Notify listeners about the move
    _changeController.add(DriveChangeEvent(type: 'deleted', path: oldPath));
    _changeController.add(DriveChangeEvent(type: 'added', path: newPath));
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

    // Find ALL versions of the file at the source path
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

    // Copy ALL versions of the file/folder
    for (final record in records) {
      final sourceContent = Map<String, dynamic>.from(
        record.value['decryptedContent'] as Map<String, dynamic>,
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

      // Broadcast the new event
      ndk.broadcast.broadcast(nostrEvent: event);
    }

    // Get the type from the first record to determine if we need to copy children
    final firstRecord = records.first;
    final copiedContent =
        firstRecord.value['decryptedContent'] as Map<String, dynamic>;

    // If it's a folder, also copy all children
    if (copiedContent['type'] == 'folder') {
      await _copyChildren(sourcePath, destinationPath, account);
    }

    // Notify listeners about the copy
    _changeController.add(
      DriveChangeEvent(type: 'added', path: destinationPath),
    );
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
