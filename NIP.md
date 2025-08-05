# NIP-XX

## Encrypted File Tree Storage

`draft` `optional`

This NIP defines encrypted file tree storage on Nostr using Blossom servers for files and Nostr events for folder structure.

### Event Structure

Uses kind `9500` for both files and folders.

#### File Event
```json
{
    "kind": 9500,
    "content": nip44Encrypt({
        "type": "file",
        "hash": "<sha256>",
        "path": "<absolute-path>",
        "size": "<size-in-bytes>",
        "file-type": "<file-mime-type>",
        "encryption-algorithm": "<encryption-algorithm>",
        "decryption-key": "<decryption-key>",
        "decryption-nonce": "<decryption-nonce>"
    })
}
```

- `file-type`: Specifies the MIME type of the attached file (e.g., `image/jpeg`, `audio/mpeg`, `application/pdf`, etc.) before encryption.
- `encryption-algorithm`: Indicates the encryption algorithm used for encrypting the file. Supported algorithms: `aes-gcm`.
- `decryption-key`: The decryption key that will be used by the recipient to decrypt the file.
- `decryption-nonce`: The decryption nonce that will be used by the recipient to decrypt the file.

#### Folder Event
```json
{
    "kind": 9500,
    "content": nip44Encrypt({
        "type": "folder",
        "path": "<absolute-path>"
    })
}
```

### Rules

- All paths MUST be absolute (start with "/")
- Content objects MUST be encrypted using NIP-44
- Files are stored on Blossom servers, addressable by SHA-256
- Delete using NIP-09 deletion events

### File Sharing

To share files with other users, create a shared file event with the recipient's public key as a `P` tag:

#### Shared File Event
```jsonc
{
    "kind": 9500,
    "content": nip44Encrypt(<file-object>),
    "tags": [["p", "<recipient-pubkey>"]]
}
```

- The `shared-with` field contains an array of public keys that have access
- The `p` tag allows recipients to discover shared files
- Recipients decrypt the content using NIP-44 with the sender's public key

### File Versioning

File versions are handled by creating new events with the same path but different hashes. The most recent event is the most recent version of the file.

#### Version Event
```jsonc
{
    "kind": 9500,
    "content": nip44Encrypt({
        "type": "file",
        "hash": "c886c67942...", // new version hash
        "path": "/docs/report.pdf", // same path as original
        "size": 1148576,
        "file-type": "application/pdf",
    }),
}
```

- Multiple events with the same path represent different versions
- The `previous-hash` field optionally links to the previous file version
- The `e` tag can reference the previous event for version history
- Clients MUST use the most recent event (highest `created_at`) as the current version

### Examples

#### Folder Event
```jsonc
{
    "kind": 9500,
    "content": nip44Encrypt({
        "type": "folder",
        "path": "/docs"
    }),
}
```

#### File Event (Encrypted)
```jsonc
{
    "kind": 9500,
    "content": nip44Encrypt({
        "type": "file",
        "hash": "b775b56931...", // hash of encrypted blob
        "path": "/docs/secret.pdf",
        "size": 1048592, // size of encrypted blob
        "file-type": "application/pdf",
        "encryption-algorithm": "aes-gcm",
        "decryption-key": "base64encodedkey...",
        "decryption-nonce": "base64encodednonce..."
    }),
}
```
