Secure, encrypted cloud drive service built on Nostr protocol with real-time sync.

## Examples

```dart
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
```

## TODO

 - [ ] Sync

## My Nostr for contact and donation

https://njump.me/npub1kg4sdvz3l4fr99n2jdz2vdxe2mpacva87hkdetv76ywacsfq5leqquw5te