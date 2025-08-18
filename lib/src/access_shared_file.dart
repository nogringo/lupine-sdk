import 'dart:convert';

import 'package:lupine_sdk/src/models/file_metadata.dart';
import 'package:lupine_sdk/src/models/drive_item_factory.dart';
import 'package:lupine_sdk/src/models/shared_file_access.dart';
import 'package:lupine_sdk/src/utils/nevent.dart';
import 'package:ndk/ndk.dart';
import 'package:nip01/nip01.dart';
import 'package:nip19/nip19.dart';
import 'package:nip49/nip49.dart';

/// Helper function to parse a share link and extract components.
///
/// [shareLink] - The full share link in format: baseUrl/nevent/nsecORncryptsec
///
/// Returns a [SharedFileAccess] containing:
/// - eventId: The event ID from the nevent
/// - relays: The relay URLs from the nevent
/// - author: The author pubkey from the nevent (if present)
/// - kind: The event kind from the nevent (if present)
/// - encodedPrivateKey: The nsec or ncryptsec string
/// - isPasswordProtected: Whether the key is encrypted (ncryptsec)
SharedFileAccess parseShareLink(String shareLink) {
  // Format: baseUrl/nevent/nsecORncryptsec
  final parts = shareLink.split('/');
  if (parts.length < 2) {
    throw ArgumentError('Invalid share link format');
  }

  final neventStr = parts[parts.length - 2];
  final keyStr = parts[parts.length - 1];

  // Decode the nevent
  final nevent = NeventCodec.decode(neventStr);

  // Determine if key is encrypted
  final isPasswordProtected = keyStr.startsWith('ncryptsec1');

  return SharedFileAccess(
    eventId: nevent.eventId,
    relays: nevent.relays ?? [],
    author: nevent.author ?? '',
    kind: nevent.kind ?? 0,
    encodedPrivateKey: keyStr,
    isPasswordProtected: isPasswordProtected,
    nevent: neventStr,
  );
}

/// Helper function to decode private key from a share link key string.
///
/// [keyStr] - The nsec or ncryptsec string
/// [password] - Optional password for ncryptsec decryption
///
/// Returns the hex private key.
Future<String> decodeShareKey(String keyStr, {String? password}) async {
  if (keyStr.startsWith('ncryptsec1')) {
    // NIP-49 encrypted private key
    if (password == null || password.isEmpty) {
      throw Exception('Password required for encrypted share link');
    }

    try {
      return await Nip49.decrypt(keyStr, password);
    } catch (e) {
      throw Exception('Invalid password or corrupted share key');
    }
  } else if (keyStr.startsWith('nsec1')) {
    // Regular nsec private key
    try {
      return Nip19.nsecToHex(keyStr);
    } catch (e) {
      throw Exception('Invalid share key format');
    }
  } else {
    throw Exception('Unsupported share key format');
  }
}

/// Access a shared file using a nevent and private key.
///
/// This function allows anonymous access to files that have been shared
/// via share links, without requiring a logged-in DriveService instance.
///
/// [nevent] - The nevent string containing the event ID and relays
/// [privateKey] - The hex private key to decrypt the shared content
///
/// Returns a [FileMetadata] representing the shared file.
Future<FileMetadata> accessSharedFile({
  required String nevent,
  required String privateKey,
}) async {
  // Decode the nevent to get event details
  final decodedNevent = NeventCodec.decode(nevent);
  final eventId = decodedNevent.eventId;
  final relays = decodedNevent.relays;
  print(relays);

  // Generate the keypair from private key
  final shareKeyPair = KeyPair.fromPrivateKey(privateKey: privateKey);
  final publicKey = shareKeyPair.publicKey;

  // Create a temporary NDK instance with the share keypair
  final shareRelays =
      relays ??
      ['wss://relay.damus.io', 'wss://relay.nostr.band', 'wss://nos.lol'];

  print(shareRelays);

  final tempNdk = Ndk(
    NdkConfig(
      eventVerifier: Bip340EventVerifier(),
      cache: MemCacheManager(),
    ),
  );

  try {
    // Login with the share keypair
    tempNdk.accounts.loginPrivateKey(pubkey: publicKey, privkey: privateKey);

    // Query for the specific shared event by ID
    final response = tempNdk.requests.query(
      filters: [
        Filter(ids: [eventId], kinds: const [9500]),
      ],
      explicitRelays: shareRelays,
    );
    final events = await response.stream.toList();

    if (events.isEmpty) {
      throw Exception('Shared event not found');
    }

    // Get the share event
    final shareEvent = events.first;

    // Verify we have access (we should be tagged with 'p')
    bool hasAccess = false;
    for (final tag in shareEvent.tags) {
      if (tag.length >= 2 && tag[0] == 'p' && tag[1] == publicKey) {
        hasAccess = true;
        break;
      }
    }

    if (!hasAccess) {
      throw Exception('Access denied: private key does not match share');
    }

    // Decrypt the content
    final account = tempNdk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('Failed to access share account');
    }

    final decryptedContent = await account.signer.decryptNip44(
      ciphertext: shareEvent.content,
      senderPubKey: shareEvent.pubKey,
    );

    if (decryptedContent == null) {
      throw Exception('Failed to decrypt shared file');
    }

    // Parse the decrypted content
    final fileMetadata = jsonDecode(decryptedContent) as Map<String, dynamic>;

    // Create and return the FileMetadata
    final driveItem = DriveItemFactory.fromJson({
      'decryptedContent': fileMetadata,
      'nostrEvent': shareEvent.toJson(),
    });
    
    if (driveItem is! FileMetadata) {
      throw Exception('Shared item is not a file');
    }
    
    return driveItem;
  } finally {
    // Clean up temporary NDK instance
    tempNdk.destroy();
  }
}
