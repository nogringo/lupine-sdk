import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:hex/hex.dart';
import 'package:lupine_sdk/src/privkey_to_pubkey.dart';
import 'package:ndk/shared/nips/nip44/nip44.dart';

class NsecEncryptor {
  static const ivLength = 16;

  static Future<String> encryptString(String plaintext, String privkey) {
    return Nip44.encryptMessage(plaintext, privkey, privkeyToPubkey(privkey));
  }

  static Future<String> decryptString(String payload, String privkey) async {
    return Nip44.decryptMessage(payload, privkey, privkeyToPubkey(privkey));
  }

  static Future<Uint8List> encryptFileFromPath({
    required String inputPath,
    required String privkey,
    bool deterministic = false,
  }) async {
    final file = File(inputPath);
    final bytes = await file.readAsBytes();

    return encryptFile(
      bytes: bytes,
      privkey: privkey,
      deterministic: deterministic,
    );
  }

  static Future<Uint8List> encryptFile({
    required Uint8List bytes,
    required String privkey,
    bool deterministic = false,
  }) async {
    final keyBytes = _parseNsecKey(privkey);
    final key = Key(keyBytes);

    final iv =
        deterministic
            ? _generateDeterministicIV(key, bytes)
            : IV.fromSecureRandom(ivLength);

    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));

    final encrypted = encrypter.encryptBytes(bytes, iv: iv);

    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  static Future<Uint8List> decryptFile({
    required Uint8List encryptedBytes,
    required String privkey,
  }) async {
    final keyBytes = _parseNsecKey(privkey);
    final key = Key(keyBytes);

    if (encryptedBytes.length < ivLength) {
      throw Exception('Fichier chiffré invalide');
    }

    final iv = IV(encryptedBytes.sublist(0, ivLength));
    final data = encryptedBytes.sublist(ivLength);

    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));

    final decrypted = encrypter.decryptBytes(Encrypted(data), iv: iv);

    return Uint8List.fromList(decrypted);
  }

  static Uint8List _parseNsecKey(String privkey) {
    try {
      final bytes = HEX.decode(privkey);

      if (bytes.length < 32) {
        throw Exception(
          'La clé nsec doit fournir au moins 32 bytes de données',
        );
      }

      return Uint8List.fromList(bytes.sublist(0, 32));
    } catch (e) {
      throw Exception('Format de clé nsec invalide: ${e.toString()}');
    }
  }

  static IV _generateDeterministicIV(Key key, Uint8List plaintext) {
    final sha256s = sha256.convert([...key.bytes, ...plaintext]);
    return IV(Uint8List.fromList(sha256s.bytes.sublist(0, ivLength)));
  }
}
