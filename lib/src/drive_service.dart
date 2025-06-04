import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lupine_sdk/src/constants.dart';
import 'package:lupine_sdk/src/privkey_to_pubkey.dart';
import 'package:lupine_sdk/src/config.dart';
import 'package:lupine_sdk/src/get_available_file_path.dart';
import 'package:lupine_sdk/src/models/drive_event.dart';
import 'package:lupine_sdk/src/no_event_verifier.dart';
import 'package:lupine_sdk/src/nsec_encryptor.dart';
import 'package:ndk/ndk.dart';
import 'package:path/path.dart' as p;
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';

class DriveService {
  static final DriveService _instance = DriveService._internal();
  DriveService._internal();
  factory DriveService() => _instance;

  late String privkey;

  final _updaterController = StreamController<dynamic>.broadcast();
  Stream<dynamic> get updateEvents => _updaterController.stream;

  final ndk = Ndk(
    NdkConfig(
      eventVerifier: NoEventVerifier(),
      cache: MemCacheManager(),
      bootstrapRelays: [
        "wss://proxy.nostr-relay.app/cf045ae94b02d503351d4b0a2fe888df46ce416df9a70ee79206241d1f815b84",
        "ws://umbrel:4848",
      ],
    ),
  );

  List<DriveEvent> driveEvents = [];

  String get pubkey => ndk.accounts.getLoggedAccount()!.pubkey;

  void login({required privkey}) async {
    if (ndk.accounts.isLoggedIn) return;

    this.privkey = privkey;
    final pubkey = privkeyToPubkey(privkey);

    ndk.accounts.loginPrivateKey(privkey: privkey, pubkey: pubkey);

    final response = ndk.requests.subscription(
      filters: [
        Filter(authors: [pubkey], kinds: [driveKind, 5]),
      ],
    );

    await for (final event in response.stream) {
      if (event.kind == 5) {
        for (var tag in event.tags) {
          final tagKind = tag[0];
          if (tagKind != "e") continue;

          final deletedEventId = tag[1];
          driveEvents.removeWhere((e) => e.event.id == deletedEventId);
          update();
        }
        continue;
      }

      final entityData = await NsecEncryptor.decryptString(
        event.content,
        privkey,
      );
      final entity = DriveEvent(
        event: event,
        tags: List<String>.from(jsonDecode(entityData)),
      );

      driveEvents.add(entity);
      driveEvents.sort((a, b) => a.path.compareTo(b.path));

      update();
    }
  }

  void logout() async {
    privkey = "";
    driveEvents = [];
    ndk.accounts.logout();
  }

  void update() {
    _updaterController.add(true);
  }

  void dispose() {
    _updaterController.close();
  }

  Future<void> addFolder(String path, String destPath) async {
    if (isWeb) return;

    final dir = Directory(path);
    final List<FileSystemEntity> entities = await dir.list().toList();

    for (final entity in entities) {
      final stat = await entity.stat();

      final newFolderPath = p.join(destPath, p.basename(path));
      if (stat.type == FileSystemEntityType.directory) {
        print(newFolderPath);
        await addFolder(entity.path, newFolderPath);
      } else if (stat.type == FileSystemEntityType.file) {
        await addFileFromPath(entity.path, destPath: newFolderPath);
      }
    }

    createFolder(p.basename(path), destPath: destPath);
  }

  Future<void> addFileFromPath(String path, {String destPath = "/"}) async {
    if (isWeb) return;

    final file = File(path);
    final bytes = await file.readAsBytes();

    final fileMimeType = lookupMimeType(path);
    final fileName = path.split("/").last;

    await addFile(
      bytes: bytes,
      name: fileName,
      mimeType: fileMimeType,
      destPath: destPath,
    );
  }

  Future<void> addFile({
    required Uint8List bytes,
    String name = "Untitled",
    String? mimeType,
    String destPath = "/",
  }) async {
    final fileSize = bytes.length;

    final encryptedBytes = await NsecEncryptor.encryptFile(
      bytes: bytes,
      privkey: privkey,
      deterministic: true,
    );

    final responses = await ndk.blossom.uploadBlob(
      data: encryptedBytes,
      serverUrls: blossomServers,
    );

    if (responses.isEmpty) return;

    final fileId = responses.first.descriptor!.sha256;

    List<String> fileData = [
      "x",
      fileId,
      "$destPath/$name",
      fileSize.toString(),
    ];
    if (mimeType != null) fileData.add(mimeType);

    final fileEvent = Nip01Event(
      pubKey: pubkey,
      kind: driveKind,
      tags: [],
      content: await NsecEncryptor.encryptString(jsonEncode(fileData), privkey),
    );

    ndk.broadcast.broadcast(nostrEvent: fileEvent);
  }

  void listBlobs() async {
    try {
      final responses = await ndk.blossom.listBlobs(
        pubkey:
            "0ca3f123c42ba503f7dc5962f3768ca0c9ae36806f8aa96543e28cc8f24ce9b5",
        serverUrls: blossomServers,
      );

      for (var response in responses) {
        print(response.sha256);
      }
    } catch (e) {
      print(e);
    }
  }

  void checkBlob() async {
    try {
      final response = await ndk.blossom.checkBlob(
        sha256:
            "fdce6b78e828130971bfd21c3ee87d4dd2c67af20b30c9ab90ab297c1036b8d1",
        serverUrls: blossomServers,
      );

      print(response);
    } catch (e) {
      print(e);
    }
  }

  void createFolder(String name, {String destPath = "/"}) async {
    String folderPath = p.join(destPath, name);

    List<String> folderData = ["folder", folderPath];

    final folderEvent = Nip01Event(
      pubKey: pubkey,
      kind: driveKind,
      tags: [],
      content: await NsecEncryptor.encryptString(
        jsonEncode(folderData),
        privkey,
      ),
    );

    ndk.broadcast.broadcast(nostrEvent: folderEvent);
  }

  void deleteEvents(List<String> eventsId) async {
    final deleteEvent = Nip01Event(
      pubKey: pubkey,
      kind: 5,
      tags: eventsId.map((eventId) => ["e", eventId]).toList(),
      content: "",
    );
    ndk.broadcast.broadcast(nostrEvent: deleteEvent);
  }

  void copyEntityTo(DriveEvent entity, String toPath) async {
    List<String> entityData = entity.tags;
    if (entity.kind == "x") {
      entityData[2] = p.join(toPath, entity.name);
    } else if (entity.kind == "folder") {
      List<DriveEvent> folderChildren =
          driveEvents
              .where((e) => p.equals(p.dirname(e.path), entity.path))
              .toList();

      for (var child in folderChildren) {
        copyEntityTo(child, p.join(toPath, entity.name));
      }

      entityData[1] = p.join(toPath, entity.name);
    }

    final event = Nip01Event(
      pubKey: pubkey,
      kind: driveKind,
      tags: [],
      content: await NsecEncryptor.encryptString(
        jsonEncode(entityData),
        privkey,
      ),
    );
    ndk.broadcast.broadcast(nostrEvent: event);
  }

  void moveEntityTo(DriveEvent entity, String toPath) {
    copyEntityTo(entity, toPath);

    List<String> eventsIdToDelete = [entity.event.id];
    if (entity.kind == "folder") {
      List<DriveEvent> folderChildren =
          driveEvents.where((e) => p.isWithin(entity.path, e.path)).toList();
      for (var child in folderChildren) {
        eventsIdToDelete.add(child.event.id);
      }
    }

    deleteEvents(eventsIdToDelete);
  }

  void deleteEntity(DriveEvent entity) {
    if (entity.isFile) {
      final fileRefCount =
          driveEvents.where((e) => e.tags[1] == entity.tags[1]).length;

      if (fileRefCount == 1) {
        ndk.blossom.deleteBlob(
          sha256: entity.tags[1],
          serverUrls: blossomServers,
        );
      }
    }

    if (entity.isFolder) {
      final children = list(entity.path);
      for (var child in children) {
        deleteEntity(child);
      }
    }

    deleteEvents([entity.event.id]);
  }

  renameEntity(DriveEvent driveEvent, String newName) async {
    deleteEvents([driveEvent.event.id]);

    List<String> entityData = driveEvent.tags;

    if (driveEvent.isFile) {
      entityData[2] = p.join(p.dirname(entityData[2]), newName);
    }
    if (driveEvent.isFolder) {
      entityData[1] = p.join(p.dirname(entityData[1]), newName);
    }

    final event = Nip01Event(
      pubKey: pubkey,
      kind: driveKind,
      tags: [],
      content: await NsecEncryptor.encryptString(
        jsonEncode(entityData),
        privkey,
      ),
    );
    ndk.broadcast.broadcast(nostrEvent: event);
  }

  List<DriveEvent> list(String path) {
    return driveEvents.where((e) => p.equals(p.dirname(e.path), path)).toList();
  }

  Future<void> downloadEntity(DriveEvent entity, [String? destPath]) async {
    final Directory? downloadsDir = await getDownloadsDirectory();
    destPath ??= downloadsDir?.path;

    if (destPath == null) return;

    if (entity.isFolder) {
      final entityDir = Directory(p.join(destPath, entity.name));
      await entityDir.create();
      final children = list(entity.path);
      for (var child in children) {
        await downloadEntity(child, entityDir.path);
      }
    }

    if (entity.isFile) {
      final bytes = await entity.download();
      final desiredFilePath = p.join(destPath, entity.name);
      final filePath = await getAvailableFilePath(desiredFilePath);
      final file = File(filePath);
      await file.writeAsBytes(bytes);
    }
  }
}
