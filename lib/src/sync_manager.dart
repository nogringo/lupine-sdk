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

  // Start syncing events from Nostr relays
  Future<void> startSync() async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Get the timestamp of the most recent event in our database
    final mostRecentEvent = await _getMostRecentEventTime();

    // Create filters for:
    // 1. Our own drive events
    final ownEventsFilter = Filter(
      kinds: const [9500],
      authors: [account.pubkey],
      since: mostRecentEvent,
    );

    // 2. Events shared with us (where we're tagged)
    final sharedEventsFilter = Filter(
      kinds: const [9500],
      pTags: [account.pubkey],
      since: mostRecentEvent,
    );

    // 3. Deletion events
    final deletionFilter = Filter(
      kinds: const [5],
      authors: [account.pubkey],
      since: mostRecentEvent,
    );

    // Subscribe to all event types
    _subscription = ndk.requests
        .subscription(
          filters: [ownEventsFilter, sharedEventsFilter, deletionFilter],
        )
        .stream
        .listen(_handleIncomingEvent);

    // Also fetch historical events
    await fetchHistoricalEvents();
  }

  // Fetch all historical events
  Future<void> fetchHistoricalEvents() async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) {
      throw Exception('User not logged in');
    }

    // Fetch both our own events and events shared with us
    final ownEventsFilter = Filter(
      kinds: const [9500],
      authors: [account.pubkey],
    );

    final sharedEventsFilter = Filter(
      kinds: const [9500],
      pTags: [account.pubkey],
    );

    final response = ndk.requests.query(
      filters: [ownEventsFilter, sharedEventsFilter],
    );

    await for (final event in response.stream) {
      await _handleDriveEvent(event);
    }

    _lastSync = DateTime.now();
  }

  // Handle incoming events (drive events and deletions)
  Future<void> _handleIncomingEvent(Nip01Event event) async {
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

  // Force a manual sync
  Future<void> syncNow() async {
    await fetchHistoricalEvents();
  }

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

  // Manually sync deletion events (for initial sync)
  Future<void> syncDeletions() async {
    final account = ndk.accounts.getLoggedAccount();
    if (account == null) return;

    final filter = Filter(
      kinds: const [5], // NIP-09 deletion events
      authors: [account.pubkey],
    );

    final response = ndk.requests.query(filters: [filter]);

    await for (final event in response.stream) {
      // Process e tags (events to delete)
      for (final tag in event.tags) {
        if (tag.length >= 2 && tag[0] == 'e') {
          final eventIdToDelete = tag[1];
          await _store.record(eventIdToDelete).delete(db);
        }
      }
    }
  }

  void dispose() {
    stopSync();
  }
}
