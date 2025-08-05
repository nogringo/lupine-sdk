import 'drive_item.dart';

class FileMetadata extends DriveItem {
  @override
  final String path;
  @override
  final DateTime createdAt;
  @override
  final String? eventId;

  final String hash;
  final int size;
  final String fileType;
  final String? encryptionAlgorithm;
  final String? decryptionKey;
  final String? decryptionNonce;

  @override
  String get type => 'file';

  bool get isEncrypted => encryptionAlgorithm != null;

  String get fileName => name;

  String get fileExtension => path.contains('.') ? path.split('.').last : '';

  FileMetadata({
    required this.hash,
    required this.path,
    required this.size,
    required this.fileType,
    this.encryptionAlgorithm,
    this.decryptionKey,
    this.decryptionNonce,
    DateTime? createdAt,
    this.eventId,
  }) : createdAt = createdAt ?? DateTime.now();

  @override
  Map<String, dynamic> toJson() => {
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

  factory FileMetadata.fromJson(Map<String, dynamic> json) => FileMetadata(
    hash: json['hash'] as String,
    path: json['path'] as String,
    size: json['size'] as int,
    fileType: json['file-type'] as String,
    encryptionAlgorithm: json['encryption-algorithm'] as String?,
    decryptionKey: json['decryption-key'] as String?,
    decryptionNonce: json['decryption-nonce'] as String?,
    createdAt: json['created-at'] != null
        ? DateTime.parse(json['created-at'] as String)
        : DateTime.now(),
    eventId: json['eventId'] as String?,
  );
}
