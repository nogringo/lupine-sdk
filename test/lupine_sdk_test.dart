import 'dart:convert';
import 'package:lupine_sdk/lupine_sdk.dart';
import 'package:nip01/nip01.dart';
import 'package:nip19/nip19.dart';
import 'package:test/test.dart';
import 'package:sembast/sembast_memory.dart' as sembast;
import 'package:ndk/ndk.dart';

void main() {
  group('DriveService', () {
    // const blossomServerUrl = "http://localhost:3001";

    late DriveService driveService;
    late sembast.Database db;
    late Ndk ndk;

    setUp(() async {
      // Create in-memory database for testing
      db = await sembast.databaseFactoryMemory.openDatabase('test.db');

      // Create mock NDK instance
      ndk = Ndk(
        NdkConfig(
          eventVerifier: Bip340EventVerifier(),
          cache: MemCacheManager(),
          bootstrapRelays: ["wss://relay.primal.net"],
        ),
      );

      // Login with private key
      final privkey = Nip19.nsecToHex(
        "nsec1ulevffshaykkq46yyedc5c78svemvk2qcc48azpmdlszc3rf233sz9vd53",
      );
      final keyPair = KeyPair.fromPrivateKey(privateKey: privkey);
      ndk.accounts.loginPrivateKey(pubkey: keyPair.publicKey, privkey: privkey);

      // Initialize drive service
      driveService = DriveService(ndk: ndk, db: db);
    });

    tearDown(() async {
      driveService.dispose();
      await db.close();
    });

    test('should create and list folders', () async {
      // Create a folder
      await driveService.createFolder('/Documents');

      // List root directory
      final items = await driveService.list('/');

      // Verify folder was created
      expect(items.length, equals(1));
      expect(items.first.name, equals('Documents'));
      expect(items.first.isFolder, isTrue);
      expect(items.first.path, equals('/Documents'));
    });

    test('should handle nested folders', () async {
      // Create nested folders
      await driveService.createFolder('/Documents');
      await driveService.createFolder('/Documents/Projects');
      await driveService.createFolder('/Documents/Projects/2024');

      // List Documents directory
      final documentsItems = await driveService.list('/Documents');
      expect(documentsItems.length, equals(1));
      expect(documentsItems.first.name, equals('Projects'));

      // List Projects directory
      final projectsItems = await driveService.list('/Documents/Projects');
      expect(projectsItems.length, equals(1));
      expect(projectsItems.first.name, equals('2024'));
    });

    test('should search for items', () async {
      // Create some folders
      await driveService.createFolder('/Documents');
      await driveService.createFolder('/Photos');
      await driveService.createFolder('/Documents/Reports');

      // Search for items containing "doc"
      final results = await driveService.search('doc');
      expect(results.length, greaterThan(0));

      // Search for items containing "o"
      final resultsWithO = await driveService.search('o');
      expect(resultsWithO.length, greaterThan(0));
    });

    test('should move folders', () async {
      // Create folders
      await driveService.createFolder('/OldFolder');
      await driveService.createFolder('/OldFolder/SubFolder');

      // Move folder
      await driveService.move(oldPath: '/OldFolder', newPath: '/NewFolder');

      // Verify old path doesn't exist
      final oldItems = await driveService.list('/');
      expect(oldItems.any((item) => item.name == 'OldFolder'), isFalse);

      // Verify new path exists
      expect(oldItems.any((item) => item.name == 'NewFolder'), isTrue);

      // Verify subfolder was also moved
      final newSubItems = await driveService.list('/NewFolder');
      expect(newSubItems.length, equals(1));
      expect(newSubItems.first.name, equals('SubFolder'));
    });

    test('should emit change events', () async {
      // Listen for changes
      final changes = <DriveChangeEvent>[];
      final subscription = driveService.changes.listen(changes.add);

      // Create a folder
      await driveService.createFolder('/TestFolder');

      // Wait a bit for the event to be emitted
      await Future.delayed(Duration(milliseconds: 100));

      // Verify event was emitted
      expect(changes.length, equals(1));
      expect(changes.first.type, equals('added'));
      expect(changes.first.path, equals('/TestFolder'));

      // Clean up
      await subscription.cancel();
    });

    test('should handle paths correctly', () async {
      // Create folder with trailing slash (should be normalized)
      await driveService.createFolder('/TestDocuments/');

      // List root directory and check our folder exists
      final items1 = await driveService.list('/');
      final testDoc = items1.firstWhere((item) => item.name == 'TestDocuments');
      expect(testDoc.path, equals('/TestDocuments')); // No trailing slash

      // List the created directory - should be empty
      final items2 = await driveService.list('/TestDocuments');
      expect(items2.length, equals(0)); // Empty directory
    });

    test('should validate absolute paths', () {
      // These should throw
      expect(
        () => driveService.createFolder('relative/path'),
        throwsA(isA<ArgumentError>()),
      );

      expect(
        () => driveService.list('Documents'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('should store events on relays', () async {
      // Create a unique test folder
      final testPath = '/RelayTest_${DateTime.now().millisecondsSinceEpoch}';
      await driveService.createFolder(testPath);

      // Wait a bit for the event to be broadcast
      await Future.delayed(Duration(milliseconds: 500));

      // Query the relay directly for our event
      final account = ndk.accounts.getLoggedAccount()!;
      final filter = Filter(
        kinds: const [9500],
        authors: [account.pubkey],
        limit: 10,
      );

      final events = ndk.requests.query(filters: [filter]);

      // Find our test event
      bool foundTestEvent = false;
      await for (final event in events.stream) {
        try {
          // Try to decrypt the content
          final decrypted = await account.signer.decryptNip44(
            ciphertext: event.content,
            senderPubKey: account.pubkey,
          );

          if (decrypted != null) {
            final content = jsonDecode(decrypted);
            if (content['path'] == testPath) {
              foundTestEvent = true;

              // Verify event structure
              expect(event.kind, equals(9500));
              expect(event.pubKey, equals(account.pubkey));
              expect(content['type'], equals('folder'));
              break;
            }
          }
        } catch (e) {
          // Skip events we can't decrypt
          continue;
        }
      }

      expect(foundTestEvent, isTrue, reason: 'Event should be stored on relay');
    });
  });

  group('SyncManager', () {
    late DriveService driveService1;
    late DriveService driveService2;
    late sembast.Database db1;
    late sembast.Database db2;
    late Ndk ndk1;
    late Ndk ndk2;

    setUp(() async {
      // Create two separate instances to simulate different devices
      db1 = await sembast.databaseFactoryMemory.openDatabase('test1.db');
      db2 = await sembast.databaseFactoryMemory.openDatabase('test2.db');

      // Create NDK instances with same account
      final privkey = Nip19.nsecToHex(
        "nsec1ulevffshaykkq46yyedc5c78svemvk2qcc48azpmdlszc3rf233sz9vd53",
      );
      final keyPair = KeyPair.fromPrivateKey(privateKey: privkey);

      ndk1 = Ndk(
        NdkConfig(
          eventVerifier: Bip340EventVerifier(),
          cache: MemCacheManager(),
          bootstrapRelays: ["wss://relay.primal.net"],
        ),
      );
      ndk1.accounts.loginPrivateKey(
        pubkey: keyPair.publicKey,
        privkey: privkey,
      );

      ndk2 = Ndk(
        NdkConfig(
          eventVerifier: Bip340EventVerifier(),
          cache: MemCacheManager(),
          bootstrapRelays: ["wss://relay.primal.net"],
        ),
      );
      ndk2.accounts.loginPrivateKey(
        pubkey: keyPair.publicKey,
        privkey: privkey,
      );

      driveService1 = DriveService(ndk: ndk1, db: db1);
      driveService2 = DriveService(ndk: ndk2, db: db2);
    });

    tearDown(() async {
      driveService1.dispose();
      driveService2.dispose();
      await db1.close();
      await db2.close();
    });

    test('should sync folders between devices', () async {
      // Create folder on device 1
      final testFolder = '/SyncTest_${DateTime.now().millisecondsSinceEpoch}';
      await driveService1.createFolder(testFolder);

      // Wait for broadcast
      await Future.delayed(Duration(seconds: 1));

      // Sync device 2 (already initialized on creation)
      await driveService2.sync();

      // Wait for sync to complete
      await Future.delayed(Duration(seconds: 1));

      // Check if folder appears on device 2
      final items = await driveService2.list('/');
      final syncedFolder = items.where((item) => item.path == testFolder);

      expect(syncedFolder.length, equals(1));
      expect(syncedFolder.first.isFolder, isTrue);
    });

    test('should sync deletions between devices', () async {
      // Create folder on both devices first
      final testFolder =
          '/DeleteSyncTest_${DateTime.now().millisecondsSinceEpoch}';

      // Create on device 1
      await driveService1.createFolder(testFolder);
      await Future.delayed(Duration(seconds: 1));

      // Sync to device 2 (already initialized on creation)
      await driveService2.sync();
      await Future.delayed(Duration(seconds: 1));

      // Verify it exists on device 2
      var items = await driveService2.list('/');
      expect(items.any((item) => item.path == testFolder), isTrue);

      // Delete on device 1
      await driveService1.deleteByPath(testFolder);
      await Future.delayed(Duration(seconds: 1));

      // Sync device 2 again
      await driveService2.sync();
      await Future.delayed(Duration(seconds: 1));

      // Verify it's deleted on device 2
      items = await driveService2.list('/');
      expect(items.any((item) => item.path == testFolder), isFalse);
    });

    test('should emit change events during sync', () async {
      // Listen for changes on device 2 (already initialized on creation)
      final changes = <DriveChangeEvent>[];
      final subscription = driveService2.changes.listen(changes.add);

      // Create multiple items on device 1
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await driveService1.createFolder('/ChangeTest1_$timestamp');
      await driveService1.createFolder('/ChangeTest2_$timestamp');

      await Future.delayed(Duration(seconds: 1));

      // Sync device 2 to receive the new items
      await driveService2.sync();

      await Future.delayed(Duration(seconds: 1));

      // Should have received change events
      expect(changes.length, greaterThanOrEqualTo(2));
      expect(changes.every((e) => e.type == 'added'), isTrue);

      await subscription.cancel();
    });

    test('should handle concurrent modifications', () async {
      // Create same folder path on both devices
      final testFolder =
          '/ConcurrentTest_${DateTime.now().millisecondsSinceEpoch}';

      // Create on both devices without syncing
      await driveService1.createFolder(testFolder);
      await driveService2.createFolder(testFolder);

      await Future.delayed(Duration(seconds: 1));

      // Both should sync without errors
      await driveService1.sync();
      await driveService2.sync();

      await Future.delayed(Duration(seconds: 1));

      // Both should see the folder
      final items1 = await driveService1.list('/');
      final items2 = await driveService2.list('/');

      expect(items1.any((item) => item.path == testFolder), isTrue);
      expect(items2.any((item) => item.path == testFolder), isTrue);
    });

    test('should track last sync time', () async {
      // Force a manual sync to update lastSync
      await driveService2.sync();

      // Should have a last sync time
      expect(driveService2.lastSync, isNotNull);
      expect(driveService2.lastSync!.isBefore(DateTime.now()), isTrue);
    });
  });

  group('Models', () {
    test('FileMetadata should have correct properties', () {
      final file = FileMetadata(
        hash: 'abc123',
        path: '/test.txt',
        size: 1024,
        fileType: 'text/plain',
        encryptionAlgorithm: 'aes-gcm',
        decryptionKey: 'key123',
        decryptionNonce: 'nonce123',
      );

      expect(file.hash, equals('abc123'));
      expect(file.path, equals('/test.txt'));
      expect(file.size, equals(1024));
      expect(file.fileType, equals('text/plain'));
      expect(file.isEncrypted, isTrue);
      expect(file.fileName, equals('test.txt'));
      expect(file.fileExtension, equals('txt'));
      expect(file.type, equals('file'));
      expect(file.isFile, isTrue);
      expect(file.isFolder, isFalse);
    });

    test('FolderMetadata should have correct properties', () {
      final folder = FolderMetadata(path: '/Documents');

      expect(folder.path, equals('/Documents'));
      expect(folder.name, equals('Documents'));
      expect(folder.type, equals('folder'));
      expect(folder.isFile, isFalse);
      expect(folder.isFolder, isTrue);
    });

    test('Root folder should have special name', () {
      final rootFolder = FolderMetadata(path: '/');
      expect(rootFolder.name, equals('Root'));
    });
  });
}
