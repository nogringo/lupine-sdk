import 'dart:convert';
import 'dart:typed_data';

import 'package:lupine_sdk/src/models/decryption_info.dart';
import 'package:lupine_sdk/src/utils/aes_gcm.dart';
import 'package:cryptography/cryptography.dart';
import 'package:ndk/ndk.dart';

/// Downloads a file from Blossom servers
/// 
/// [hash] - The SHA256 hash of the file to download
/// [blossomServers] - List of Blossom server URLs to try downloading from
/// [decryptionInfo] - Optional decryption information containing key and nonce
/// [ndk] - Optional NDK instance for communication. If null, a new instance will be created
/// 
/// Returns the decrypted file data as Uint8List
Future<Uint8List> downloadFileFromBlossom({
  required String hash,
  required List<String> blossomServers,
  DecryptionInfo? decryptionInfo,
  Ndk? ndk,
}) async {
  // Create NDK instance if not provided
  final ndkInstance = ndk ?? Ndk.emptyBootstrapRelaysConfig();
  bool shouldDestroy = false;
  
  if (ndk == null) {
    // Mark that we should destroy the instance when done
    shouldDestroy = true;
  }

  try {
    // Download from Blossom servers using explicit relay list
    final response = await ndkInstance.blossom.getBlob(
      sha256: hash,
      serverUrls: blossomServers,
    );

    final encryptedData = response.data;

    // Return raw data if no decryption needed
    if (decryptionInfo == null) {
      return encryptedData;
    }

    // Decrypt the data
    try {
      final keyBytes = base64Decode(decryptionInfo.key);
      final nonce = base64Decode(decryptionInfo.nonce);

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
      throw Exception('Failed to decrypt file: $e');
    }
  } finally {
    // Destroy NDK instance if we created it
    if (shouldDestroy) {
      ndkInstance.destroy();
    }
  }
}