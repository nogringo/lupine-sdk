A dart package to store files on nostr using blossom.

> [!IMPORTANT]
> This project is in developpement, event kind can change.

## How it work

All files are stored on every user blossom servers. The file tree is stored on nostr relays. Files and path are encrypted but metadata are public !

This package is inspired by https://github.com/hzrd149/blossom-drive but with some changes. Each objects has it's own nostr events.

Use nip 09 to delete an object.

### Files evenet

```json
{
    "kind": 40000,
    "content": encrypted(
        ["x", "<sha256>", "<absolute file path>", "<size in bytes>", "<optional MIME type>"]
    )
}
```

### Folders event

```json
{
    "kind": 40000,
    "content": encrypted(
        ["folder", "<path>"]
    )
}
```

## Examples

```dart
// Init drive
DriveService().login(privkey: "nostr_private_key_in_hex");

// Listen for updates
DriveService().updateEvents.listen((_) => update());

// List objects in a path
DriveService().list("/path/on/drive")

// Store a file
DriveService().addFile("/path/on/my/computer", "/path/on/drive");

// Store a folder
DriveService().addFolder("/path/on/my/computer", "/path/on/drive");
```

## Todo

- [ ] Use nip 44 for encryption
- [ ] Sync folders

## Contributing

Contributions are welcome! Please open issues or submit pull requests.
