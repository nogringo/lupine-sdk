import 'package:lupine_sdk/lupine_sdk.dart';
import 'package:nip01/nip01.dart';
import 'package:nip19/nip19.dart';
import 'package:test/test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ndk/ndk.dart';

void main() {
  group('DriveService', () {
    // const blossomServerUrl = "http://localhost:3001";

    late DriveService driveService;
    late Database db;
    late Ndk ndk;

    setUp(() async {
      // Create in-memory database for testing
      db = await databaseFactoryMemory.openDatabase('test.db');

      // Create mock NDK instance
      ndk = Ndk(
        NdkConfig(
          eventVerifier: Bip340EventVerifier(),
          cache: MemCacheManager(),
          bootstrapRelays: ["ws://localhost:7777"],
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
