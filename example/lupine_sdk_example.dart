import 'package:lupine_sdk/lupine_sdk.dart';
import 'package:lupine_sdk/src/drive_service.dart';
import 'package:ndk/ndk.dart';
import 'package:nip01/nip01.dart';
import 'package:nip19/nip19.dart';
import 'package:sembast/sembast_memory.dart';

void main() async {
  // Initialize NDK
  final ndk = Ndk.defaultConfig();

  // Login with private key
  final privkey = Nip19.nsecToHex(
    "nsec1ulevffshaykkq46yyedc5c78svemvk2qcc48azpmdlszc3rf233sz9vd53",
  );
  final keyPair = KeyPair.fromPrivateKey(privateKey: privkey);
  ndk.accounts.loginPrivateKey(pubkey: keyPair.publicKey, privkey: privkey);

  // Create an in-memory database for the example
  final factory = newDatabaseFactoryMemory();
  final db = await factory.openDatabase('example_drive.db');

  // Initialize DriveService with NDK and database
  final drive = DriveService(ndk: ndk, db: db);

  // Create a folder
  await drive.createFolder("/home/moi");
  print('Folder created successfully');
}
