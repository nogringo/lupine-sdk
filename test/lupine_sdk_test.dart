import 'dart:typed_data';

import 'package:lupine_sdk/lupine_sdk.dart';
import 'package:nip01/nip01.dart';
import 'package:test/test.dart';
import 'package:sembast/sembast_memory.dart' as sembast;
import 'package:ndk/ndk.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DriveService', () {
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
          bootstrapRelays: ["ws://localhost:7777"],
        ),
      );

      // Login with private key
      final keyPair = KeyPair.fromPrivateKey(
        privateKey:
            "72cd679baf0fc9fc9b7e033322966a508c4fbc2afadd57891144ee62998743ec",
      );
      ndk.accounts.loginPrivateKey(
        pubkey: keyPair.publicKey,
        privkey: keyPair.privateKey,
      );

      ndk.blossomUserServerList.publishUserServerList(
        serverUrlsOrdered: ["http://localhost:3001"],
      );

      // Initialize drive service
      driveService = DriveService(ndk: ndk, db: db);
    });

    tearDown(() async {
      driveService.dispose();
      await db.close();
      ndk.destroy();
    });

    test('Create a folder', () async {
      final folderPath = "/home/test1";
      await driveService.createFolder(folderPath);
      final items = await driveService.list(p.dirname(folderPath));
      final match = items.where((e) => e.path == folderPath && e.isFolder);
      expect(1, match.length);
    });

    test('Share a file', () async {
      // Create a test file first
      final filePath = '/test/document.txt';
      final fileContent = 'This is a test document';
      final fileData = Uint8List.fromList(fileContent.codeUnits);

      // Create parent folder
      await driveService.createFolder('/test');

      // Upload the file
      final metadata = await driveService.uploadFile(
        fileData: fileData,
        path: filePath,
        fileType: 'text/plain',
      );

      // Generate a share link without password
      final shareLink = await driveService.generateShareLink(
        eventId: metadata.eventId!,
        baseUrl: 'https://example.com/share',
      );

      // Parse the share link to extract components
      // Format: baseUrl/nevent/nsec
      final linkParts = shareLink.split('/');
      final neventStr = linkParts[linkParts.length - 2];
      final nsecStr = linkParts[linkParts.length - 1];

      // Decode the private key
      final privateKey = await decodeShareKey(nsecStr);

      // Access the shared file using the nevent and private key
      final sharedItem = await accessSharedFile(
        nevent: neventStr,
        privateKey: privateKey,
      );

      // Download the file content
      if (sharedItem is FileMetadata) {
        final downloadedData = await driveService.downloadFile(
          hash: sharedItem.hash,
          decryptionKey: sharedItem.decryptionKey,
          decryptionNonce: sharedItem.decryptionNonce,
        );

        // Verify the downloaded content matches original
        final downloadedContent = String.fromCharCodes(downloadedData);
        expect(downloadedContent, equals(fileContent));
      }
    });
  });
}
