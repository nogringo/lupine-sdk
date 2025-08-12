import 'dart:async';
import 'dart:convert';

import 'package:ndk/ndk.dart';
import 'package:sembast/sembast.dart' as sembast;

class SyncManager {
  final Ndk ndk;
  final sembast.Database db;
  final sembast.StoreRef<String, Map<String, dynamic>> _store = sembast
      .stringMapStoreFactory
      .store('drive_events');
  final void Function(String type, String? path)? onDriveChange;

  StreamSubscription? _subscription;
  DateTime? _lastSync;

  SyncManager({required this.ndk, required this.db, this.onDriveChange});

  // Handle account changes (login/logout/switch)
  Future<void> onAccountChanged() async {
    // Stop any existing sync
    stopSync();

    // Clear the last sync time as we have a new account
    _lastSync = null;

    // Start syncing with new account (if logged in)
    await startSync();
  }

  // Start syncing events from Nostr relays
  Future<void> startSync() async {
    print("startSync");
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      // No user logged in, nothing to sync
      return;
    }

    // Get the timestamp of the most recent event in our database
    final mostRecentEvent = await _getMostRecentEventTime();
    print(mostRecentEvent);

    // Create filters:
    // 1. All events we authored (drive events + deletions)
    final ownEventsFilter = Filter(
      kinds: const [9500, 5], // Both drive and deletion events
      authors: [account.pubkey],
      since: mostRecentEvent, // null if no events, which fetches all
    );

    // 2. Drive events shared with us (we're tagged)
    final sharedEventsFilter = Filter(
      kinds: const [9500],
      pTags: [account.pubkey],
      since: mostRecentEvent, // null if no events, which fetches all
    );

    // Subscribe to both filters (OR between them)
    _subscription = ndk.requests
        .subscription(filters: [ownEventsFilter, sharedEventsFilter])
        .stream
        .listen(_handleIncomingEvent);
    print("startSync : sub");

    _lastSync = DateTime.now();
  }

  // Handle incoming events (drive events and deletions)
  Future<void> _handleIncomingEvent(Nip01Event event) async {
    print("event");
    if (event.kind == 5) {
      // Handle deletion event
      await _handleDeletionEvent(event);
    } else if (event.kind == 9500) {
      // Handle drive event
      await _handleDriveEvent(event);
    }
  }

  // Handle drive events (our own or shared with us)
  Future<void> _handleDriveEvent(Nip01Event event) async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) return;

    // Check if we already have this event
    final existing = await _store.record(event.id).get(db);
    if (existing != null) return;

    try {
      // Decrypt the content
      // For our own events: encrypted to ourselves
      // For shared events: encrypted by the sender to us
      final senderPubkey = event.pubKey == account.pubkey
          ? account
                .pubkey // Our own event
          : event.pubKey; // Shared event from another user

      final decryptedContent = await account.signer.decryptNip44(
        ciphertext: event.content,
        senderPubKey: senderPubkey,
      );

      if (decryptedContent == null) return;

      // Parse the JSON content
      final metadata = jsonDecode(decryptedContent) as Map<String, dynamic>;

      // Store in local database
      await _store.record(event.id).put(db, {
        'nostrEvent': event.toJson(),
        'decryptedContent': metadata,
      });

      // Notify about the change
      final path = metadata['path'] as String?;
      onDriveChange?.call('added', path);
    } catch (e) {
      // Silently ignore errors in individual events to keep sync running
      // Could be improved by adding error callback or logging mechanism
    }
  }

  // Get the timestamp of the most recent event
  Future<int?> _getMostRecentEventTime() async {
    final records = await _store.find(
      db,
      finder: sembast.Finder(
        sortOrders: [sembast.SortOrder('nostrEvent.created_at', false)],
        limit: 1,
      ),
    );

    if (records.isEmpty) return null;

    final nostrEvent =
        records.first.value['nostrEvent'] as Map<String, dynamic>;
    return nostrEvent['created_at'] as int?;
  }

  // Stop syncing
  void stopSync() {
    _subscription?.cancel();
    _subscription = null;
  }

  // Get sync status
  bool get isSyncing => _subscription != null;
  DateTime? get lastSync => _lastSync;

  // Handle a single deletion event
  Future<void> _handleDeletionEvent(Nip01Event event) async {
    // Process e tags (events to delete)
    for (final tag in event.tags) {
      if (tag.length >= 2 && tag[0] == 'e') {
        final eventIdToDelete = tag[1];

        // Get the path before deleting (if possible)
        final record = await _store.record(eventIdToDelete).get(db);
        final path = record?['decryptedContent']?['path'] as String?;

        await _store.record(eventIdToDelete).delete(db);

        // Notify about the deletion
        onDriveChange?.call('deleted', path);
      }
    }
  }

  void dispose() {
    stopSync();
  }
}
