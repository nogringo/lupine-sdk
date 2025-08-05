import 'drive_item.dart';
import 'file_metadata.dart';
import 'folder_metadata.dart';

class DriveItemFactory {
  static DriveItem fromJson(Map<String, dynamic> json) {
    // Check if this is a wrapped structure from the database
    final decryptedContent = json['decryptedContent'] as Map<String, dynamic>?;
    final eventId = json['nostrEvent']?['id'] as String?;

    // Use decryptedContent if available, otherwise assume direct content
    final content = decryptedContent ?? json;
    final type = content['type'] as String?;

    // Add eventId if available
    if (eventId != null && decryptedContent != null) {
      content['eventId'] = eventId;
    }

    switch (type) {
      case 'file':
        return FileMetadata.fromJson(content);
      case 'folder':
        return FolderMetadata.fromJson(content);
      default:
        throw ArgumentError('Unknown drive item type: $type');
    }
  }
}
