import 'dart:convert';
import 'dart:typed_data';
import 'package:bech32/bech32.dart';

enum TLVType {
  special(0), // 32 bytes of the event id
  relay(1), // relay URL where event is likely to be found
  author(2), // 32 bytes of the pubkey of the event
  kind(3); // 32-bit unsigned integer of the kind, big-endian

  final int value;
  const TLVType(this.value);
}

class Nevent {
  final String eventId;
  final List<String>? relays;
  final String? author;
  final int? kind;

  Nevent({required this.eventId, this.relays, this.author, this.kind});

  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    if (relays != null && relays!.isNotEmpty) 'relays': relays,
    if (author != null) 'author': author,
    if (kind != null) 'kind': kind,
  };
}

class NeventCodec {
  static Uint8List _encodeTLV(int type, Uint8List value) {
    if (value.length > 255) {
      throw ArgumentError(
        'TLV value too long: ${value.length} bytes (max 255)',
      );
    }
    final result = Uint8List(2 + value.length);
    result[0] = type;
    result[1] = value.length;
    result.setRange(2, 2 + value.length, value);
    return result;
  }

  static List<(int, Uint8List)> _decodeTLV(Uint8List data) {
    final tlvList = <(int, Uint8List)>[];
    int i = 0;

    while (i < data.length) {
      if (i + 1 >= data.length) break;

      final type = data[i];
      final length = data[i + 1];

      if (i + 2 + length > data.length) break;

      final value = Uint8List.sublistView(data, i + 2, i + 2 + length);
      tlvList.add((type, value));
      i += 2 + length;
    }

    return tlvList;
  }

  static Uint8List _hexToBytes(String hex) {
    if (hex.length % 2 != 0) {
      throw ArgumentError('Invalid hex string');
    }

    final bytes = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return bytes;
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _intToBytes(int value) {
    final bytes = Uint8List(4);
    bytes[0] = (value >> 24) & 0xFF;
    bytes[1] = (value >> 16) & 0xFF;
    bytes[2] = (value >> 8) & 0xFF;
    bytes[3] = value & 0xFF;
    return bytes;
  }

  static int _bytesToInt(Uint8List bytes) {
    if (bytes.length != 4) {
      throw ArgumentError('Expected 4 bytes for int');
    }
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  static List<int>? _convertBits(
    List<int> data,
    int fromBits,
    int toBits,
    bool pad,
  ) {
    int acc = 0;
    int bits = 0;
    final ret = <int>[];
    final maxv = (1 << toBits) - 1;
    final maxAcc = (1 << (fromBits + toBits - 1)) - 1;

    for (final value in data) {
      if (value < 0 || (value >> fromBits) != 0) {
        return null;
      }
      acc = ((acc << fromBits) | value) & maxAcc;
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        ret.add((acc >> bits) & maxv);
      }
    }

    if (pad) {
      if (bits > 0) {
        ret.add((acc << (toBits - bits)) & maxv);
      }
    } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0) {
      return null;
    }

    return ret;
  }

  static const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

  static List<int> _expandHrp(String hrp) {
    final expanded = <int>[];
    for (int i = 0; i < hrp.length; i++) {
      expanded.add(hrp.codeUnitAt(i) >> 5);
    }
    expanded.add(0);
    for (int i = 0; i < hrp.length; i++) {
      expanded.add(hrp.codeUnitAt(i) & 31);
    }
    return expanded;
  }

  static int _polymod(List<int> values) {
    const generator = [
      0x3b6a57b2,
      0x26508e6d,
      0x1ea119fa,
      0x3d4233dd,
      0x2a1462b3,
    ];
    int chk = 1;
    for (final value in values) {
      final top = chk >> 25;
      chk = (chk & 0x1ffffff) << 5 ^ value;
      for (int i = 0; i < 5; i++) {
        chk ^= ((top >> i) & 1) != 0 ? generator[i] : 0;
      }
    }
    return chk;
  }

  static List<int> _createChecksum(String hrp, List<int> data) {
    final values = _expandHrp(hrp) + data + [0, 0, 0, 0, 0, 0];
    final polyMod = _polymod(values) ^ 1;
    final checksum = <int>[];
    for (int i = 0; i < 6; i++) {
      checksum.add((polyMod >> 5 * (5 - i)) & 31);
    }
    return checksum;
  }

  static String encode(Nevent nevent) {
    if (nevent.eventId.length != 64) {
      throw ArgumentError(
        'Event ID must be 64 hex chars, got ${nevent.eventId.length}',
      );
    }

    final tlvData = <int>[];

    // Add event ID (required, type 0)
    final eventBytes = _hexToBytes(nevent.eventId);
    tlvData.addAll(_encodeTLV(TLVType.special.value, eventBytes));

    // Add relays (optional, type 1)
    if (nevent.relays != null) {
      for (final relay in nevent.relays!) {
        final relayBytes = Uint8List.fromList(utf8.encode(relay));
        tlvData.addAll(_encodeTLV(TLVType.relay.value, relayBytes));
      }
    }

    // Add author pubkey (optional, type 2)
    if (nevent.author != null) {
      if (nevent.author!.length != 64) {
        throw ArgumentError(
          'Author pubkey must be 64 hex chars, got ${nevent.author!.length}',
        );
      }
      final authorBytes = _hexToBytes(nevent.author!);
      tlvData.addAll(_encodeTLV(TLVType.author.value, authorBytes));
    }

    // Add kind (optional, type 3)
    if (nevent.kind != null) {
      final kindBytes = _intToBytes(nevent.kind!);
      tlvData.addAll(_encodeTLV(TLVType.kind.value, kindBytes));
    }

    // Convert to bech32
    final tlvBytes = Uint8List.fromList(tlvData);
    final converted = _convertBits(tlvBytes, 8, 5, true);
    if (converted == null) {
      throw ArgumentError('Failed to convert to bech32 format');
    }

    // Manual bech32 encoding to support longer strings
    final hrp = 'nevent';
    final data = Uint8List.fromList(converted);
    final checksum = _createChecksum(hrp, data);
    final combined = data + checksum;

    final result = StringBuffer(hrp);
    result.write('1');
    for (final value in combined) {
      result.write(_charset[value]);
    }
    return result.toString();
  }

  static Nevent decode(String neventStr) {
    // Decode bech32
    final codec = Bech32Codec();
    final bech32 = codec.decode(neventStr, neventStr.length);

    if (bech32.hrp != 'nevent') {
      throw ArgumentError(
        "Invalid HRP: expected 'nevent', got '${bech32.hrp}'",
      );
    }

    // Convert from 5-bit to 8-bit
    final converted = _convertBits(bech32.data, 5, 8, false);
    if (converted == null) {
      throw ArgumentError('Failed to convert from bech32 format');
    }

    // Decode TLV fields
    final tlvList = _decodeTLV(Uint8List.fromList(converted));

    // Parse TLV fields
    String? eventId;
    List<String> relays = [];
    String? author;
    int? kind;

    for (final (type, value) in tlvList) {
      switch (type) {
        case 0: // TLVType.special
          if (value.length == 32) {
            eventId = _bytesToHex(value);
          }
          break;
        case 1: // TLVType.relay
          try {
            final relayUrl = utf8.decode(value);
            relays.add(relayUrl);
          } catch (_) {
            // Ignore invalid fields per spec
          }
          break;
        case 2: // TLVType.author
          if (value.length == 32) {
            author = _bytesToHex(value);
          }
          break;
        case 3: // TLVType.kind
          if (value.length == 4) {
            kind = _bytesToInt(value);
          }
          break;
        default:
          // Ignore unrecognized TLV types per spec
          break;
      }
    }

    if (eventId == null) {
      throw ArgumentError('Missing required event_id field');
    }

    return Nevent(
      eventId: eventId,
      relays: relays.isEmpty ? null : relays,
      author: author,
      kind: kind,
    );
  }
}
