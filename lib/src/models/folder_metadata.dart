import 'drive_item.dart';

class FolderMetadata extends DriveItem {
  @override
  final String path;
  @override
  final DateTime createdAt;
  @override
  final String? eventId;

  @override
  String get type => 'folder';

  String get folderName => name;

  FolderMetadata({required this.path, DateTime? createdAt, this.eventId})
    : createdAt = createdAt ?? DateTime.now();

  @override
  Map<String, dynamic> toJson() => {'type': 'folder', 'path': path};

  factory FolderMetadata.fromJson(Map<String, dynamic> json) => FolderMetadata(
    path: json['path'] as String,
    createdAt: DateTime.now(), // Will be overridden by DriveItemFactory
    eventId: json['eventId'] as String?,
  );
}
