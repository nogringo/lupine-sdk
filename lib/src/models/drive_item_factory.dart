import 'drive_item.dart';
import 'file_metadata.dart';
import 'folder_metadata.dart';

class DriveItemFactory {
  static DriveItem fromJson(Map<String, dynamic> json) {
    // We always receive a record.value with this structure
    final decryptedContent = json['decryptedContent'] as Map<String, dynamic>;
    final nostrEvent = json['nostrEvent'] as Map<String, dynamic>;
    final eventId = nostrEvent['id'] as String;
    final createdAt = nostrEvent['created_at'] as int;

    final type = decryptedContent['type'] as String;

    switch (type) {
      case 'file':
        return FileMetadata(
          hash: decryptedContent['hash'] as String,
          path: decryptedContent['path'] as String,
          size: decryptedContent['size'] as int,
          fileType:
              decryptedContent['file-type'] as String?, // This can be null
          encryptionAlgorithm:
              decryptedContent['encryption-algorithm'] as String?,
          decryptionKey: decryptedContent['decryption-key'] as String?,
          decryptionNonce: decryptedContent['decryption-nonce'] as String?,
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt * 1000),
          eventId: eventId,
        );
      case 'folder':
        return FolderMetadata(
          path: decryptedContent['path'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt * 1000),
          eventId: eventId,
        );
      default:
        throw ArgumentError('Unknown drive item type: $type');
    }
  }
}
