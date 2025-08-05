import 'dart:typed_data';
import 'dart:math';
import 'package:pointycastle/export.dart';

/// Generate cryptographically secure random bytes
Uint8List generateRandomBytes(int length) {
  final secureRandom = Random.secure();
  final bytes = Uint8List(length);
  for (int i = 0; i < length; i++) {
    bytes[i] = secureRandom.nextInt(256);
  }
  return bytes;
}

/// Encrypt data using AES-GCM
Uint8List encryptAesGcm(Uint8List data, Uint8List key, Uint8List nonce) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true, // true for encryption
      AEADParameters(
        KeyParameter(key),
        128, // MAC tag length in bits (16 bytes)
        nonce,
        Uint8List(0), // Additional authenticated data (empty)
      ),
    );

  final encrypted = Uint8List(cipher.getOutputSize(data.length));
  final len = cipher.processBytes(data, 0, data.length, encrypted, 0);
  cipher.doFinal(encrypted, len);

  return encrypted;
}

/// Decrypt data using AES-GCM
Uint8List decryptAesGcm(
  Uint8List encryptedData,
  Uint8List key,
  Uint8List nonce,
) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false, // false for decryption
      AEADParameters(
        KeyParameter(key),
        128, // MAC tag length in bits (16 bytes)
        nonce,
        Uint8List(0), // Additional authenticated data (empty)
      ),
    );

  final decrypted = Uint8List(cipher.getOutputSize(encryptedData.length));
  final len = cipher.processBytes(
    encryptedData,
    0,
    encryptedData.length,
    decrypted,
    0,
  );
  final finalLen = cipher.doFinal(decrypted, len);

  // Return only the actual decrypted data (remove padding)
  return Uint8List.sublistView(decrypted, 0, len + finalLen);
}
