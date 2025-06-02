import 'dart:typed_data';

import 'package:lupine_sdk/lupine_sdk.dart';
import 'package:lupine_sdk/src/config.dart';
import 'package:lupine_sdk/src/nsec_encryptor.dart';
import 'package:ndk/ndk.dart';
import 'package:path/path.dart' as p;

class DriveEvent {
  Nip01Event event;
  List<String> tags;

  String get kind => tags[0];
  bool get isFile => kind == "x";
  bool get isFolder => kind == "folder";

  String get path {
    if (kind == "x") return tags[2];
    if (kind == "folder") return tags[1];
    throw Exception("Unknow kind");
  }

  String get name => p.basename(path);
  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000);

  int get size {
    if (kind == "x") return int.parse(tags[3]);
    if (kind == "folder") {
      return DriveService().driveEvents
          .where((e) => e.kind == "x" && e.path.startsWith("$path/"))
          .fold(0, (acc, e) => acc + e.size);
    }
    throw Exception("Unknow kind");
  }

  DriveEvent({required this.event, required this.tags});

  Future<Uint8List> download() async {
    if (kind != "x") throw Exception("Must be a file");

    final fileId = tags[1];

    final blobResponse = await DriveService().ndk.blossom.getBlob(
      sha256: fileId,
      serverUrls: blossomServers,
    );

    final decryptedBytes = await NsecEncryptor.decryptFile(
      encryptedBytes: blobResponse.data,
      privkey: DriveService().privkey,
    );

    return decryptedBytes;
  }
}
