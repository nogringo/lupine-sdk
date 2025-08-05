import 'package:lupine_sdk/lupine_sdk.dart';
import 'package:lupine_sdk/src/drive_service.dart';
import 'package:ndk/ndk.dart';
import 'package:test/test.dart';

void main() {
  // group('DriveService', () {
  //   late DriveService driveService;
  //   late Ndk mockNdk;

  //   setUp(() {
  //     // Create a mock Ndk instance
  //     // In a real test, you would use a proper mock
  //     mockNdk = Ndk.defaultConfig();
  //     driveService = DriveService(ndk: mockNdk);
  //   });

  //   test('should create a DriveService instance', () {
  //     expect(driveService, isNotNull);
  //     expect(driveService.ndk, equals(mockNdk));
  //   });

  //   test('createFolder should accept a path parameter', () async {
  //     // Test that the method exists and can be called
  //     expect(() => driveService.createFolder('/test/folder'), returnsNormally);
  //   });

  //   test('uploadFile should accept required and optional parameters', () async {
  //     // Test that the method exists and can be called with all parameters
  //     expect(
  //       () => driveService.uploadFile(
  //         hash: 'abc123',
  //         path: '/test/file.pdf',
  //         size: 1024,
  //         fileType: 'application/pdf',
  //         encryptionAlgorithm: 'aes-gcm',
  //         decryptionKey: 'key123',
  //         decryptionNonce: 'nonce123',
  //       ),
  //       returnsNormally,
  //     );
  //   });

  //   test('listDirectory should accept a path parameter', () async {
  //     // Test that the method exists and can be called
  //     expect(() => driveService.listDirectory('/'), returnsNormally);
  //   });

  //   test('getMetadata should accept a path parameter', () async {
  //     // Test that the method exists and can be called
  //     expect(() => driveService.getMetadata('/test/file.pdf'), returnsNormally);
  //   });

  //   test('delete should accept an eventId parameter', () async {
  //     // Test that the method exists and can be called
  //     expect(() => driveService.delete('event123'), returnsNormally);
  //   });

  //   test('shareFile should accept all required parameters', () async {
  //     // Test that the method exists and can be called
  //     expect(
  //       () => driveService.shareFile(
  //         hash: 'abc123',
  //         path: '/test/file.pdf',
  //         size: 1024,
  //         fileType: 'application/pdf',
  //         recipientPubkey: 'pubkey123',
  //       ),
  //       returnsNormally,
  //     );
  //   });

  //   test('getSharedFiles should be callable', () async {
  //     // Test that the method exists and can be called
  //     expect(() => driveService.getSharedFiles(), returnsNormally);
  //   });

  //   test('getFileVersions should accept a path parameter', () async {
  //     // Test that the method exists and can be called
  //     expect(() => driveService.getFileVersions('/test/file.pdf'), returnsNormally);
  //   });

  //   test('move should accept old and new path parameters', () async {
  //     // Test that the method exists and can be called
  //     expect(
  //       () => driveService.move(
  //         oldPath: '/old/path/file.pdf',
  //         newPath: '/new/path/file.pdf',
  //       ),
  //       returnsNormally,
  //     );
  //   });

  //   test('search should accept a query parameter', () async {
  //     // Test that the method exists and can be called
  //     expect(() => driveService.search('test'), returnsNormally);
  //   });
  // });
}
