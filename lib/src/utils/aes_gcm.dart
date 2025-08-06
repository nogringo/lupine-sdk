import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

/// AES-GCM encryption/decryption for NIP-XX encrypted file storage
class AESGCMEncryption {
  final AesGcm _aesGcm;
  
  AESGCMEncryption() : _aesGcm = AesGcm.with256bits();
  
  /// Generate a random 256-bit AES key
  Future<SecretKey> generateKey() async {
    return await _aesGcm.newSecretKey();
  }
  
  /// Generate a random 96-bit nonce for AES-GCM
  List<int> generateNonce() {
    return _aesGcm.newNonce();
  }
  
  /// Encrypt file data using AES-GCM
  /// 
  /// Returns a map containing:
  /// - encryptedData: The encrypted bytes with authentication tag
  /// - key: The secret key used
  /// - nonce: The nonce used
  Future<Map<String, dynamic>> encryptFile(
    Uint8List fileData, {
    SecretKey? key,
    List<int>? nonce,
  }) async {
    key ??= await generateKey();
    nonce ??= generateNonce();
    
    final secretBox = await _aesGcm.encrypt(
      fileData,
      secretKey: key,
      nonce: nonce,
    );
    
    // Combine ciphertext and mac into single bytes array
    final encryptedData = Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    
    return {
      'encryptedData': encryptedData,
      'key': key,
      'nonce': nonce,
    };
  }
  
  /// Decrypt file data using AES-GCM
  Future<Uint8List> decryptFile(
    Uint8List encryptedData,
    SecretKey key,
    List<int> nonce,
  ) async {
    // Split authentication tag from encrypted data
    final tagLength = 16;
    final cipherText = encryptedData.sublist(0, encryptedData.length - tagLength);
    final tag = encryptedData.sublist(encryptedData.length - tagLength);
    
    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(tag),
    );
    
    final decryptedData = await _aesGcm.decrypt(
      secretBox,
      secretKey: key,
    );
    
    return Uint8List.fromList(decryptedData);
  }
  
  /// Encrypt a file and prepare metadata for a Nostr event
  Future<Map<String, dynamic>> encryptFileForEvent(String filePath) async {
    final file = File(filePath);
    final fileData = await file.readAsBytes();
    
    // Encrypt the file
    final result = await encryptFile(fileData);
    final encryptedData = result['encryptedData'] as Uint8List;
    final key = result['key'] as SecretKey;
    final nonce = result['nonce'] as List<int>;
    
    // Calculate hash of encrypted data
    final fileHash = crypto.sha256.convert(encryptedData).toString();
    
    // Get file name for path
    final fileName = filePath.split('/').last;
    
    // Extract key bytes
    final keyBytes = await key.extractBytes();
    
    // Prepare event content
    final eventContent = {
      'type': 'file',
      'hash': fileHash,
      'path': '/$fileName',
      'size': encryptedData.length,
      'encryption-algorithm': 'aes-gcm',
      'decryption-key': base64Encode(keyBytes),
      'decryption-nonce': base64Encode(nonce),
    };
    
    // Add file type if detectable
    final mimeType = _getMimeType(filePath);
    if (mimeType != null) {
      eventContent['file-type'] = mimeType;
    }
    
    return {
      'encryptedData': encryptedData,
      'eventContent': eventContent,
    };
  }
  
  /// Decrypt a file using metadata from a Nostr event
  Future<Uint8List> decryptFileFromEvent(
    Uint8List encryptedData,
    Map<String, dynamic> eventContent,
  ) async {
    if (eventContent['encryption-algorithm'] != 'aes-gcm') {
      throw ArgumentError(
        'Unsupported encryption algorithm: ${eventContent['encryption-algorithm']}'
      );
    }
    
    final keyBytes = base64Decode(eventContent['decryption-key']);
    final nonce = base64Decode(eventContent['decryption-nonce']);
    
    final key = SecretKey(keyBytes);
    
    return await decryptFile(encryptedData, key, nonce);
  }
  
  /// Simple MIME type detection based on file extension
  String? _getMimeType(String filePath) {
    final extension = filePath.split('.').last.toLowerCase();
    
    const mimeTypes = {
      'txt': 'text/plain',
      'html': 'text/html',
      'css': 'text/css',
      'js': 'application/javascript',
      'json': 'application/json',
      'pdf': 'application/pdf',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
      'zip': 'application/zip',
    };
    
    return mimeTypes[extension];
  }
}

/// Example usage
void main() async {
  final aes = AESGCMEncryption();
  
  print('Example 1: Basic encryption/decryption');
  print('-' * 40);
  
  // Example 1: Encrypt and decrypt raw data
  final originalData = utf8.encode('This is a secret document that needs encryption.');
  final originalBytes = Uint8List.fromList(originalData);
  
  final encrypted = await aes.encryptFile(originalBytes);
  final encryptedData = encrypted['encryptedData'] as Uint8List;
  final key = encrypted['key'] as SecretKey;
  final nonce = encrypted['nonce'] as List<int>;
  
  print('Original size: ${originalBytes.length} bytes');
  print('Encrypted size: ${encryptedData.length} bytes');
  
  final keyBytes = await key.extractBytes();
  print('Key (base64): ${base64Encode(keyBytes)}');
  print('Nonce (base64): ${base64Encode(nonce)}');
  
  final decrypted = await aes.decryptFile(encryptedData, key, nonce);
  print('Decryption successful: ${listEquals(decrypted, originalBytes)}');
  print('');
  
  // Example 2: Simulate file encryption for Nostr event
  print('Example 2: File encryption for Nostr event');
  print('-' * 40);
  
  // Create a test file
  final testFile = File('test_document.txt');
  await testFile.writeAsString('This is a test document for Nostr encrypted storage.');
  
  try {
    // Encrypt the file
    final result = await aes.encryptFileForEvent('test_document.txt');
    
    print('Event content (would be NIP-44 encrypted):');
    final encoder = JsonEncoder.withIndent('  ');
    print(encoder.convert(result['eventContent']));
    print('');
    
    // Simulate retrieval and decryption
    final decryptedFile = await aes.decryptFileFromEvent(
      result['encryptedData'],
      result['eventContent'],
    );
    
    print('Decrypted content: ${utf8.decode(decryptedFile)}');
  } finally {
    // Clean up test file
    if (await testFile.exists()) {
      await testFile.delete();
    }
  }
}

bool listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}